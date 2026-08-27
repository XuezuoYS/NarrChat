import 'dart:convert';
import 'dart:typed_data';

import '../webdav_service.dart';
import 'img_tombstones.dart';
import 'sync_models.dart';

/// 云端同步存储抽象：把 WebDAV 的"目录级文件"操作包装成语义化的
/// manifest / 快照 / 图片 blob / 互斥锁读写，便于测试注入内存替身。
abstract class SyncRemoteStore {
  /// 读取云端 manifest；不存在/解析失败返回 null（视为"云端为空"）。
  Future<SyncManifest?> readManifest();

  /// 写入云端 manifest。
  Future<void> writeManifest(SyncManifest manifest);

  /// 列出快照文件名（`narrchat_snapshot_*.db`）。
  Future<List<String>> listSnapshotNames();

  /// 读取某快照字节；不存在返回 null。
  Future<Uint8List?> readSnapshot(String name);

  Future<void> writeSnapshot(String name, Uint8List bytes);
  Future<void> deleteSnapshot(String name);

  /// 列出本地/云端图片的路径集合（`img/<hash>.<ext>`）。
  Future<List<String>> listImages();

  /// 确保云端图片子集合存在（WebDAV 实现会 MKCOL；内存替身无需实现）。
  ///
  /// 在上传图片 blob 前调用：首次同步时 `img/` 尚无目录，直接 PUT 会被
  /// 多数 WebDAV 服务器以 409 拒绝。
  Future<void> ensureImagesFolder() async {}

  Future<Uint8List?> readImage(String path);
  Future<void> writeImage(String path, Uint8List bytes);
  Future<void> deleteImage(String path);

  /// 读取云端「图片删除墓碑」文件（默认实现：无此文件支持 - 视为空）。
  ///
  /// 墓碑独立于 manifest / 快照：仅记录已删除图片的路径与"删除时间 / 过期时间"，
  /// 条目保留一年，每次同步清除过期项；重新添加的图片由同步合并时抵消。
  Future<ImgTombstones?> readImageTombstones() async => null;

  /// 覆盖写入云端「图片删除墓碑」文件（默认实现：无此文件支持 - 空写入）。
  Future<void> writeImageTombstones(ImgTombstones tombstones) async {}

  /// 尝试获取云端互斥锁（软锁，TTL 超时后可被抢占）。
  ///
  /// 保证"读 manifest → 写快照 → 写 manifest"临界区同时只有一个设备在跑；
  /// 默认实现为无锁（内存替身 / 不支持锁的服务器降级走写前校验）。
  /// 返回 true = 已获得锁，可进入临界区。
  Future<bool> acquireLock({String deviceId = '', int ttlSeconds = 300}) async =>
      true;

  /// 释放云端互斥锁（仅当锁属于 [deviceId] 时删除）。
  Future<void> releaseLock({String deviceId = ''}) async {}

  /// 关闭底层连接。
  void close();

  /// 取云端最新一代快照名（可选指定代际）。
  ///
  /// 按代际新 → 旧排序；同代取文件名倒序（时间戳字典序即时间序）。
  Future<String?> latestSnapshotName({int? generation}) async {
    final names = await listSnapshotNames();
    var best = '';
    var bestGen = -1;
    var bestTs = -1;
    for (final n in names) {
      final g = WebDavSyncStore.generationOf(n);
      if (g == null) continue;
      if (generation != null && g != generation) continue;
      final ts = WebDavSyncStore.snapshotTimeOf(n)?.millisecondsSinceEpoch ?? -1;
      if (g > bestGen || (g == bestGen && ts >= bestTs)) {
        best = n;
        bestGen = g;
        bestTs = ts;
      }
    }
    return best.isEmpty ? null : best;
  }
}

/// 基于 [WebDavService] 的云端存储实现。
///
/// 文件名约定：
/// - manifest：`manifest.json`；
/// - 快照：`narrchat_snapshot_g<gen>_<yyyyMMdd_HHmmss>.db`；
/// - 图片：`img/<hash>.<ext>`（子目录，WebDAV MKCOL 自动建）。
class WebDavSyncStore extends SyncRemoteStore {
  /// 云端快照文件名前缀（与 [snapshotName] 对应）。
  static const String snapshotPrefix = 'narrchat_snapshot_';
  static final RegExp _snapshotRegex =
      RegExp(r'^narrchat_snapshot_g(\d+)_(\d{8})_(\d{6})\.db$');

  final WebDavService dav;
  final String folder;

  WebDavSyncStore({required this.dav, required this.folder});

  Future<void> ensureFolder() => dav.ensureCollection(folder);

  /// 生成一代快照文件名。
  static String snapshotName(int gen, DateTime time) {
    final ts =
        '${time.year}${_two(time.month)}${_two(time.day)}'
        '_${_two(time.hour)}${_two(time.minute)}${_two(time.second)}';
    return '${snapshotPrefix}g$gen' '_$ts.db';
  }

  static bool isSnapshot(String name) => _snapshotRegex.hasMatch(name);

  /// 从快照名解析代际号；非快照名返回 null。
  static int? generationOf(String name) {
    final m = _snapshotRegex.firstMatch(name);
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  /// 从快照名解析生成时间（文件名内嵌时间戳）；非快照名返回 null。
  static DateTime? snapshotTimeOf(String name) {
    final m = _snapshotRegex.firstMatch(name);
    if (m == null) return null;
    final day = m.group(2)!;
    final clock = m.group(3)!;
    return DateTime(
      int.parse(day.substring(0, 4)),
      int.parse(day.substring(4, 6)),
      int.parse(day.substring(6, 8)),
      int.parse(clock.substring(0, 2)),
      int.parse(clock.substring(2, 4)),
      int.parse(clock.substring(4, 6)),
    );
  }

  String get _manifestName => 'manifest.json';
  String get _lockName => 'sync.lock';
  String get _tombstonesName => 'img_tombstones.json';

  /// 云端互斥锁（软锁）实现：`sync.lock` 文件，内容 `{deviceId, expiresAt}`。
  ///
  /// - 锁不存在或已过期 → 抢占并返回 true（TTL 保护崩溃持有者）；
  /// - 锁有效且属于其它设备 → 返回 false；
  /// - 服务器不支持读/删（权限受限）→ 返回 false，调用方降级为「写前校验」。
  @override
  Future<bool> acquireLock({
    String deviceId = '',
    int ttlSeconds = 300,
  }) async {
    try {
      final existing = await _readLock();
      final now = DateTime.now().millisecondsSinceEpoch;
      if (existing != null && existing.expiresAt > now) return false;
      final payload = utf8.encode(jsonEncode({
        'deviceId': deviceId,
        'expiresAt': now + ttlSeconds * 1000,
      }));
      await dav.put(folder, _lockName, Uint8List.fromList(payload));
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> releaseLock({String deviceId = ''}) async {
    try {
      final existing = await _readLock();
      if (existing == null || existing.deviceId != deviceId) return;
      await dav.delete(folder, _lockName);
    } catch (_) {
      // 释放失败可忽略（TTL 兜底）。
    }
  }

  Future<({String deviceId, int expiresAt})?> _readLock() async {
    try {
      final bytes = await dav.get(folder, _lockName);
      final j = jsonDecode(utf8.decode(bytes));
      if (j is! Map<String, dynamic>) return null;
      return (
        deviceId: j['deviceId'] as String? ?? '',
        expiresAt: (j['expiresAt'] as num?)?.toInt() ?? 0,
      );
    } on WebDavException {
      return null;
    }
  }

  @override
  Future<void> ensureImagesFolder() async {
    await dav.ensureCollection('$folder/img');
  }

  @override
  Future<SyncManifest?> readManifest() async {
    try {
      final bytes = await dav.get(folder, _manifestName);
      return SyncManifest.tryParse(utf8.decode(bytes));
    } on WebDavException {
      return null;
    }
  }

  @override
  Future<void> writeManifest(SyncManifest manifest) async {
    await dav.put(
      folder,
      _manifestName,
      Uint8List.fromList(utf8.encode(manifest.toJsonString())),
    );
  }

  @override
  Future<List<String>> listSnapshotNames() async {
    final files = await dav.list(folder);
    return files.map((f) => f.name).where(isSnapshot).toList();
  }

  @override
  Future<Uint8List?> readSnapshot(String name) async {
    try {
      return await dav.get(folder, name);
    } on WebDavException {
      return null;
    }
  }

  @override
  Future<void> writeSnapshot(String name, Uint8List bytes) =>
      dav.put(folder, name, bytes);

  @override
  Future<void> deleteSnapshot(String name) => dav.delete(folder, name);

  // 图片存放在 `<folder>/img/` 子集合；WebDAV 上单个 blob 即可，用相对路径列出。
  @override
  Future<List<String>> listImages() async {
    try {
      await dav.ensureCollection('$folder/img');
      final files = await dav.list('$folder/img');
      return files.map((f) => 'img/${f.name}').toList();
    } on WebDavException {
      return const [];
    }
  }

  @override
  Future<Uint8List?> readImage(String path) async {
    final sub = path.replaceFirst(RegExp(r'^img/'), '');
    try {
      return await dav.get('$folder/img', sub);
    } on WebDavException {
      return null;
    }
  }

  @override
  Future<void> writeImage(String path, Uint8List bytes) async {
    final sub = path.replaceFirst(RegExp(r'^img/'), '');
    await dav.put('$folder/img', sub, bytes);
  }

  @override
  Future<void> deleteImage(String path) async {
    final sub = path.replaceFirst(RegExp(r'^img/'), '');
    await dav.delete('$folder/img', sub);
  }

  @override
  Future<ImgTombstones?> readImageTombstones() async {
    try {
      final bytes = await dav.get(folder, _tombstonesName);
      final j = jsonDecode(utf8.decode(bytes));
      if (j is! Map<String, dynamic>) return ImgTombstones.empty;
      return ImgTombstones.fromJson(j);
    } on WebDavException {
      return null;
    }
  }

  @override
  Future<void> writeImageTombstones(ImgTombstones tombstones) async {
    await dav.put(
      folder,
      _tombstonesName,
      Uint8List.fromList(utf8.encode(jsonEncode(tombstones.toJson()))),
    );
  }

  @override
  void close() => dav.close();

  static String _two(int n) => n.toString().padLeft(2, '0');
}
