import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

import '../app_paths.dart';

/// 图片删除墓碑（不进入数据库）。
///
/// 图片删除是**全局意图**：不再写入 `sync_pending_del` 等数据库表，而是维护
/// 一份墓碑清单——云端一份（WebDAV `img_tombstones.json`，跨设备共享），
/// 本地一份工作副本（`local_config/img_tombstones.json`，离线可用、改动在
/// 同步时合并进云端并回写）。
///
/// 生命周期：
/// - **删除图片** → 添加条目（含 `expiresAt = deletedAt + 1 年`）；
/// - **重新添加（导入/粘贴/拖拽）图片** → 删除对应条目并记入 [revoked]
///   （撤销本机的删除意图；同步合并时凭 revoked 抵消云端残留条目）；
/// - **每次同步** → 合并云端/本地、清除过期条目（[purge]），并把结果回写云端。
class ImgTombstoneEntry {
  /// 内容寻址路径（`img/<hash>.<ext>`）。
  final String path;

  final int deletedAt;

  /// 过期时间（毫秒时间戳）：过期条目在每次同步时被清除。
  final int expiresAt;

  const ImgTombstoneEntry({
    required this.path,
    required this.deletedAt,
    required this.expiresAt,
  });

  /// 条目保留期：一年。
  static const int ttlMillis = 365 * 24 * 60 * 60 * 1000;

  factory ImgTombstoneEntry.deleted(String path, int now) => ImgTombstoneEntry(
        path: path,
        deletedAt: now,
        expiresAt: now + ttlMillis,
      );

  Map<String, dynamic> toJson() =>
      {'path': path, 'deletedAt': deletedAt, 'expiresAt': expiresAt};

  factory ImgTombstoneEntry.fromJson(Map<String, dynamic> j) => ImgTombstoneEntry(
        path: j['path'] as String? ?? '',
        deletedAt: (j['deletedAt'] as num?)?.toInt() ?? 0,
        expiresAt: (j['expiresAt'] as num?)?.toInt() ?? 0,
      );
}

/// 一份墓碑清单：[entries] 为有效删除条目；[revoked] 为本机撤消的路径
///（重新添加早于下一次同步，合并时用它抵消云端残留条目；同步成功后清空）。
class ImgTombstones {
  final List<ImgTombstoneEntry> entries;
  final List<String> revoked;

  const ImgTombstones({this.entries = const [], this.revoked = const []});

  static const ImgTombstones empty = ImgTombstones();

  Map<String, dynamic> toJson() => {
        'version': 1,
        'entries': entries.map((e) => e.toJson()).toList(),
        'revoked': revoked,
      };

  factory ImgTombstones.fromJson(Map<String, dynamic> j) => ImgTombstones(
        entries: ((j['entries'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(ImgTombstoneEntry.fromJson)
            .toList(),
        revoked: ((j['revoked'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
      );
}

/// 本地墓碑工作副本与云端墓碑文件的**合并**（纯逻辑）。
///
/// - 并集：本机离线删除（仅存在于本地）与其它设备删除（仅存在于云端）都保留；
///   同路径取删除时间较新的一条；
/// - 撤销：本机重新添加（[local.revoked]）抵消对应条目（仅影响本机合并结果，
///   上传时即视为重新添加删除意图）；
/// - 过期：按 [now] 清除过期条目（条目保留一年）。
///
/// [local] 为本地工作副本（可含离线改动），[cloud] 为云端文件内容。
ImgTombstones mergeTombstones({
  required ImgTombstones local,
  required ImgTombstones cloud,
  required int now,
}) {
  final byPath = <String, ImgTombstoneEntry>{};
  for (final e in cloud.entries) {
    byPath[e.path] = e;
  }
  for (final e in local.entries) {
    final prev = byPath[e.path];
    if (prev == null || e.deletedAt >= prev.deletedAt) {
      byPath[e.path] = e;
    }
  }
  final revoked = local.revoked.toSet();
  final entries = <ImgTombstoneEntry>[
    for (final e in byPath.values)
      if (!revoked.contains(e.path) && e.expiresAt > now) e,
  ];
  return ImgTombstones(entries: entries);
}

/// 墓碑工作副本存取抽象（本地文件 / 内存替身）。
abstract class SyncTombstoneStore {
  /// 读取本地工作副本；不存在/解析失败返回空清单。
  Future<ImgTombstones> load();

  Future<void> save(ImgTombstones tombstones);
}

/// 本地文件实现：`<local_config>/img_tombstones.json`（与 AppSettings 同目录，
/// 明文 JSON；写入采用「临时文件 + 原子替换」，避免进程被杀留下截断文件）。
class FileTombstoneStore implements SyncTombstoneStore {
  /// 测试用本地配置根目录覆盖（null 走真实 [AppPaths.localConfig]）。
  @visibleForTesting
  static String? testRootOverride;

  static Future<File> _file() async {
    final dir = testRootOverride != null
        ? Directory(p.join(testRootOverride!, 'local_config'))
        : await AppPaths.localConfig();
    await dir.create(recursive: true);
    return File(p.join(dir.path, 'img_tombstones.json'));
  }

  @override
  Future<ImgTombstones> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return ImgTombstones.empty;
      final j = jsonDecode(await f.readAsString());
      if (j is! Map<String, dynamic>) return ImgTombstones.empty;
      return ImgTombstones.fromJson(j);
    } catch (_) {
      return ImgTombstones.empty;
    }
  }

  @override
  Future<void> save(ImgTombstones tombstones) async {
    final target = await _file();
    final temp = File('${target.path}.tmp-${DateTime.now().microsecondsSinceEpoch}');
    try {
      await temp.writeAsString(
        const JsonEncoder.withIndent('  ').convert(tombstones.toJson()),
        flush: true,
      );
      await temp.rename(target.path);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }
}
