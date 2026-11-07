import 'dart:typed_data';

import 'package:narrchat/services/cloud_backup/backup_remote.dart';
import 'package:narrchat/services/sync/img_tombstones.dart';
import 'package:narrchat/services/webdav_service.dart';

/// 内存版云端：整跑备份 / 还原而不碰网络。
class FakeBackupRemote implements BackupRemote {
  FakeBackupRemote({Map<String, List<int>>? initial}) {
    if (initial != null) {
      initial.forEach((name, bytes) => files[name] = Uint8List.fromList(bytes));
    }
  }

  final Map<String, Uint8List> files = {};

  bool ready = false;
  bool closed = false;

  /// 各方法的调用次数（断言"没有再传一遍"用）。
  int writeCount = 0;
  int deleteCount = 0;
  int listCount = 0;

  /// 置为非空时，所有读操作抛这个异常（模拟网络故障）。
  String? failReads;

  /// 置为非空时，所有删除操作抛这个异常（模拟删除失败）。
  String? failDeletes;

  /// 只对这几个文件名的读取抛异常（模拟 `sync_config.json` 单独读不到）。
  final Set<String> failReadsFor = {};

  @override
  Future<void> ensureReady() async {
    ready = true;
  }

  @override
  Future<Set<String>> list() async {
    listCount++;
    return files.keys.toSet();
  }

  @override
  Future<Uint8List> read(String name) async {
    final failure = failReads;
    if (failure != null) throw BackupRemoteException(failure);
    if (failReadsFor.contains(name)) {
      throw BackupRemoteException('模拟读取失败：$name');
    }
    final bytes = files[name];
    if (bytes == null) {
      throw BackupRemoteException('云端文件不存在：$name');
    }
    return Uint8List.fromList(bytes);
  }

  @override
  Future<void> write(String name, List<int> bytes) async {
    writeCount++;
    files[name] = Uint8List.fromList(bytes);
  }

  @override
  Future<void> delete(String name) async {
    final failure = failDeletes;
    if (failure != null) throw BackupRemoteException(failure);
    deleteCount++;
    files.remove(name);
  }

  @override
  void close() {
    closed = true;
  }

  /// 便利方法：直接塞一份文件（模拟另一台设备上传）。
  void put(String name, List<int> bytes) {
    files[name] = Uint8List.fromList(bytes);
  }

  /// 便利方法：取文本内容。
  String? text(String name) {
    final bytes = files[name];
    return bytes == null ? null : String.fromCharCodes(bytes);
  }
}

/// 内存版墓碑工作副本。
class MemoryTombstoneStore implements SyncTombstoneStore {
  ImgTombstones value = ImgTombstones.empty;

  int saveCount = 0;

  @override
  Future<ImgTombstones> load() async => value;

  @override
  Future<void> save(ImgTombstones tombstones) async {
    value = tombstones;
    saveCount++;
  }
}

/// 内存版 WebDAV 客户端：备份列表 / `sync_config.json` 的读写，不碰网络。
///
/// 数据面（快照 / 清单）走 [FakeBackupRemote]；这里只服务「云端备份」面板的
/// `refreshBackups` / `refreshKeepVersions`（真实 provider，注入 `webDavFactory`）。
class FakeWebDavService extends WebDavService {
  FakeWebDavService({
    Map<String, List<int>> files = const {},
    Map<String, DateTime?> modified = const {},
    this.listError,
    this.getError,
  }) : files = {...files},
       _modifiedTimes = modified,
       super(
         baseUrl: 'https://dav.example.invalid/',
         username: 'user',
         password: 'secret',
       );

  /// 云端文件（名字 → 字节）。
  final Map<String, List<int>> files;

  /// 文件的上传时间（列表展示 / 排序用）。
  final Map<String, DateTime?> _modifiedTimes;

  /// 非 null：`list` 抛这条异常文本（模拟列目录失败）。
  String? listError;

  /// 非 null：`get` 抛这条异常文本（模拟读取失败）。
  String? getError;

  int listCalls = 0;
  int getCalls = 0;
  bool closed = false;

  @override
  Future<void> ensureCollection(String path) async {}

  @override
  Future<List<WebDavFile>> list(String path) async {
    listCalls++;
    if (listError != null) throw WebDavException(listError!);
    return [
      for (final entry in files.entries)
        WebDavFile(
          name: entry.key,
          lastModified: _modifiedTimes[entry.key],
          size: entry.value.length,
        ),
    ];
  }

  @override
  Future<Uint8List> get(String path, String name) async {
    getCalls++;
    if (getError != null) throw WebDavException(getError!);
    final bytes = files[name];
    if (bytes == null) throw const WebDavException('下载失败', statusCode: 404);
    return Uint8List.fromList(bytes);
  }

  @override
  Future<void> put(String path, String name, Uint8List bytes) async {
    files[name] = Uint8List.fromList(bytes);
  }

  @override
  Future<void> delete(String path, String name) async {
    files.remove(name);
  }

  @override
  void close() {
    closed = true;
    super.close();
  }
}
