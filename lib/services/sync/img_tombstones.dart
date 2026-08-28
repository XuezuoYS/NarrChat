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
/// - **重新添加（导入/粘贴/拖拽）图片** → 删除对应条目并登记 [revived] 标记
///   （path → 复活时刻）；合并时标记抵消**所有设备上** `deletedAt` 不晚于它的
///   条目——撤销是**全局语义**，标记随云端文件与本地工作副本一起传播；
/// - **每次同步** → 合并云端/本地、清除过期条目与过期标记，并把结果回写云端。
///
/// 为什么标记必须传播（历史 bug）：设备 B 同步过 A 的删除后，其**本地工作
/// 副本**也存有该条目；若撤销只留在 A 本机（无时间戳、合并后即消费丢弃），
/// B 下次同步的并集合并会凭陈旧条目"复活"删除意图，反过来删掉 A 刚重新
/// 上传的 blob。带时间戳的标记上云后，B 合并时条目被抵消且 B 也不再删除。
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

/// 一份墓碑清单：[entries] 为有效删除条目；[revived] 为**全局复活标记**
///（path → 复活时刻毫秒，随云端文件跨设备传播）。
class ImgTombstones {
  final List<ImgTombstoneEntry> entries;

  /// 复活标记：重新添加时登记。合并时抵消 `deletedAt <= revivedAt` 的条目
  ///（含其它设备本地工作副本里的陈旧条目）；与条目同 TTL 保留一年后清除。
  final Map<String, int> revived;

  const ImgTombstones({
    this.entries = const [],
    this.revived = const {},
  });

  static const ImgTombstones empty = ImgTombstones();

  Map<String, dynamic> toJson() => {
        'version': 2,
        'entries': entries.map((e) => e.toJson()).toList(),
        'revived': revived,
      };

  factory ImgTombstones.fromJson(Map<String, dynamic> j) {
    final revived = ((j['revived'] as Map?) ?? const {}).map(
      (key, value) => MapEntry(key.toString(), (value as num).toInt()),
    );
    // v1 的 revoked 是设备本地清单（不传播，正是本 bug 根源）。升级兼容：
    // 若存在「已重新添加但尚未同步」的撤销，按读取时刻登记为复活标记
    //（晚于任何既有删除条目，抵消语义与 v1 等价；之后的新删除时间戳更晚，
    // 不受影响）。
    for (final legacy in (j['revoked'] as List? ?? const [])) {
      revived.putIfAbsent(
        legacy.toString(),
        () => DateTime.now().millisecondsSinceEpoch,
      );
    }
    return ImgTombstones(
      entries: ((j['entries'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(ImgTombstoneEntry.fromJson)
          .toList(),
      revived: revived,
    );
  }
}

/// 本地墓碑工作副本与云端墓碑文件的**合并**（纯逻辑）。
///
/// - 并集：本机离线删除（仅存在于本地）与其它设备删除（仅存在于云端）都保留；
///   同路径取删除时间较新的一条；
/// - 撤销（**全局**）：任一端登记过的复活标记（本地 ∪ 云端，按路径取较晚时刻）
///   抵消 `deletedAt <= revivedAt` 的条目——包括其它设备工作副本里同步过、
///   但复活时尚未送达的陈旧条目；晚于复活的新删除（deletedAt 更大）不受影响；
/// - 过期：按 [now] 清除过期条目与过期复活标记（各保留一年；标记必不早于
///   其抵消过的条目过期，清除顺序安全）。
///
/// [local] 为本地工作副本（可含离线改动），[cloud] 为云端文件内容。
ImgTombstones mergeTombstones({
  required ImgTombstones local,
  required ImgTombstones cloud,
  required int now,
}) {
  // 复活标记并集：同路径取较晚时刻，随合并结果传播（本地 → 云端 → 他机）。
  final revived = <String, int>{};
  for (final source in [cloud.revived, local.revived]) {
    for (final e in source.entries) {
      final prev = revived[e.key];
      if (prev == null || e.value > prev) revived[e.key] = e.value;
    }
  }
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
  final entries = <ImgTombstoneEntry>[
    for (final e in byPath.values)
      if (e.expiresAt > now && e.deletedAt > (revived[e.path] ?? -1)) e,
  ];
  return ImgTombstones(
    entries: entries,
    revived: {
      for (final e in revived.entries)
        if (e.value + ImgTombstoneEntry.ttlMillis > now) e.key: e.value,
    },
  );
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
