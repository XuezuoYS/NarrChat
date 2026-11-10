import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../database/library_store.dart';
import '../../database/sqflite_desktop.dart';
import 'backup_remote.dart';

/// 一份书架库的内容（本地文件或云端快照）。
class LibrarySnapshot {
  const LibrarySnapshot({this.masterUuid = '', this.rows = const []});

  /// `meta.master_uuid`：用来确认两侧是不是同一套数据。
  final String masterUuid;

  final List<LibraryBookRow> rows;
}

/// 书架合并的输入。
///
/// [localBookContentAt] / [remoteBookContentAt] 是「活书一侧的内容时间」：
/// 本地取书库 `book_meta.updated_at`，云端取该书单元清单的 `contentUpdatedAt`。
/// 只有「一侧活、一侧墓碑」时才需要它们来判断谁更新。
class LibraryMergeInputs {
  const LibraryMergeInputs({
    required this.localRows,
    required this.remoteRows,
    this.localBookContentAt = const {},
    this.remoteBookContentAt = const {},
  });

  final List<LibraryBookRow> localRows;
  final List<LibraryBookRow> remoteRows;
  final Map<String, DateTime?> localBookContentAt;
  final Map<String, DateTime?> remoteBookContentAt;
}

/// 书架合并结果。
class LibraryMergeResult {
  const LibraryMergeResult({
    required this.mergedRows,
    required this.changedRows,
    this.addedLocal = 0,
    this.addedRemote = 0,
    this.keptLocalTombstone = 0,
    this.adoptedRemoteTombstone = 0,
    this.revived = 0,
  });

  /// 合并后的全部行（按 book_uuid 排序，便于断言）。
  final List<LibraryBookRow> mergedRows;

  /// 与本地不同、需要写回的行。
  final List<LibraryBookRow> changedRows;

  /// 只有本地有的行数（本地离线新增的书）。
  final int addedLocal;

  /// 只有云端有的行数（云端新增的书，之后由书单元补齐）。
  final int addedRemote;

  /// 墓碑冲突里本地胜出的次数。
  final int keptLocalTombstone;

  /// 墓碑冲突里云端胜出的次数。
  final int adoptedRemoteTombstone;

  /// 「活」胜过墓碑（回收站还原）的次数。
  final int revived;

  bool get hasChanges => changedRows.isNotEmpty;

  /// 面向用户的一行摘要。
  String get summary {
    final parts = <String>[
      if (addedLocal > 0) '保留本地新增 $addedLocal 本',
      if (addedRemote > 0) '补入云端新增 $addedRemote 本',
      if (keptLocalTombstone > 0) '沿用本地删除 $keptLocalTombstone 本',
      if (adoptedRemoteTombstone > 0) '采用云端删除 $adoptedRemoteTombstone 本',
      if (revived > 0) '还原 $revived 本',
    ];
    return parts.isEmpty ? '书架无需改动' : parts.join('，');
  }
}

/// 书架合并失败（身份不一致 / 快照读不出来）。
///
/// 上层拿到它就把这次冲突降级成「人工二选一」，绝不带着不一致的数据硬合。
class LibraryMergeException implements Exception {
  const LibraryMergeException(this.message);

  final String message;

  @override
  String toString() => '书架合并失败：$message';
}

/// 书架自动合并（**纯逻辑**，无 I/O）。
///
/// 为什么不能整库二选一：书架是「身份证 + 墓碑」的集合，整份替换会丢掉本地
/// 离线新增的书，或者把别处刚删掉的书原地复活。所以按 `book_uuid` 逐行合并：
///
/// 1. 只有一侧有 → 原样保留（本地新增不丢、云端新增补进来、墓碑继续传播）；
/// 2. 两侧都活 → 活；书名副本优先用本地（书名信源在 `book_meta`，会自愈）；
/// 3. 两侧都是墓碑 → 取 `deleted_at` 更新的那条（删除信息以最新为准）；
/// 4. 一侧活一侧墓碑 → 比较「墓碑的 `deleted_at`」与「活侧书库内容时间」：
///    - 两侧都有时间且活侧更新 → 活（回收站还原不会被旧墓碑反杀）；
///    - 两侧都有时间且墓碑更新 → 墓碑（删除正常传播）；
///    - 活侧时间未知 → **墓碑胜**（删除是显式动作，绝不静默复活）。
class LibraryMerger {
  LibraryMerger._();

  static LibraryMergeResult merge(LibraryMergeInputs inputs) {
    final byLocal = {for (final row in inputs.localRows) row.bookUuid: row};
    final byRemote = {for (final row in inputs.remoteRows) row.bookUuid: row};
    final uuids = <String>{...byLocal.keys, ...byRemote.keys}.toList()..sort();

    var addedLocal = 0;
    var addedRemote = 0;
    var keptLocalTombstone = 0;
    var adoptedRemoteTombstone = 0;
    var revived = 0;

    final merged = <LibraryBookRow>[];
    for (final uuid in uuids) {
      final local = byLocal[uuid];
      final remote = byRemote[uuid];
      if (local == null) {
        merged.add(remote!);
        addedRemote++;
        continue;
      }
      if (remote == null) {
        merged.add(local);
        addedLocal++;
        continue;
      }
      if (local.isDeleted == remote.isDeleted) {
        if (!local.isDeleted) {
          // 两侧都活：内容以书库为准，这里只保留可展示的书名副本。
          merged.add(_preferLocalRow(local, remote));
        } else {
          final remoteNewer = _isNewer(remote.deletedAt, local.deletedAt);
          merged.add(remoteNewer ? remote : local);
          if (remoteNewer) {
            adoptedRemoteTombstone++;
          } else {
            keptLocalTombstone++;
          }
        }
        continue;
      }

      final tombstone = local.isDeleted ? local : remote;
      final alive = local.isDeleted ? remote : local;
      final aliveAt = local.isDeleted
          ? inputs.remoteBookContentAt[uuid]
          : inputs.localBookContentAt[uuid];
      final aliveWins =
          aliveAt != null &&
          tombstone.deletedAt != null &&
          aliveAt.toUtc().isAfter(tombstone.deletedAt!.toUtc());
      if (aliveWins) {
        merged.add(_preferLocalRow(alive, local));
        revived++;
      } else {
        merged.add(tombstone);
        if (local.isDeleted) {
          keptLocalTombstone++;
        } else {
          adoptedRemoteTombstone++;
        }
      }
    }

    final changed = [
      for (final row in merged)
        if (!_sameAsLocal(row, byLocal[row.bookUuid])) row,
    ];

    return LibraryMergeResult(
      mergedRows: merged,
      changedRows: changed,
      addedLocal: addedLocal,
      addedRemote: addedRemote,
      keptLocalTombstone: keptLocalTombstone,
      adoptedRemoteTombstone: adoptedRemoteTombstone,
      revived: revived,
    );
  }

  /// 活的一侧胜出时，书名副本优先取本地（信源在 `book_meta`）。
  static LibraryBookRow _preferLocalRow(
    LibraryBookRow alive,
    LibraryBookRow fallback,
  ) {
    if (alive.title.trim().isNotEmpty) return alive;
    if (fallback.title.trim().isNotEmpty) {
      return LibraryBookRow(bookUuid: alive.bookUuid, title: fallback.title);
    }
    return alive;
  }

  static bool _isNewer(DateTime? a, DateTime? b) {
    if (a == null) return false;
    if (b == null) return true;
    return a.toUtc().isAfter(b.toUtc());
  }

  static bool _sameAsLocal(LibraryBookRow row, LibraryBookRow? local) {
    if (local == null) return false;
    return local.title == row.title &&
        local.deletedAt?.toUtc() == row.deletedAt?.toUtc() &&
        local.deletedRoundIndex == row.deletedRoundIndex;
  }

  /// 把云端书架快照下载到临时文件、只读读出 `meta.master_uuid` 与 `books`。
  ///
  /// 读完立刻关连接、删临时目录；`openDatabase` 仅供测试注入（默认走 ffI 只读）。
  static Future<LibrarySnapshot> readRemoteSnapshot(
    BackupRemote remote,
    String snapshotName, {
    Future<Database> Function(String path)? openDatabase,
  }) async {
    final bytes = await remote.read(snapshotName);
    final dir = await Directory.systemTemp.createTemp('narrchat_lib_snap_');
    final path = p.join(dir.path, 'snapshot.db');
    try {
      await File(path).writeAsBytes(bytes, flush: true);
      final db = await (openDatabase ?? _openReadOnly)(path);
      try {
        final metaRows = await db.query('meta', limit: 1);
        final bookRows = await db.query('books', orderBy: 'book_uuid ASC');
        return LibrarySnapshot(
          masterUuid: metaRows.isEmpty
              ? ''
              : (metaRows.first['master_uuid'] as String?) ?? '',
          rows: bookRows.map(LibraryBookRow.fromRow).toList(),
        );
      } finally {
        await db.close();
      }
    } finally {
      try {
        await dir.delete(recursive: true);
      } catch (_) {
        // 临时目录删不掉不影响结论。
      }
    }
  }

  static Future<Database> _openReadOnly(String path) async {
    ensureDesktopSqfliteFactory();
    return databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
  }
}
