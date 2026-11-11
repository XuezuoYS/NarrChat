/// Mod 库的**逐 Mod 冲突**：内容指纹、逐项比较与合并计划。
///
/// 一个 Mod 的同步身份是 `mod_uuid`，比较两件事：
/// - 内容指纹（[ModContentDigest]）：包含名称、简介、四段内容、世界书与
///   墓碑布尔，**排除所有时间戳**，所以「只是重新保存一次」不会被当成内容变化；
/// - 修改时间 `updated_at`：内容不同时，新者居上（与书籍的时间口径一致）。
///
/// 比较结果按 Mod 逐条给出，最终聚合成一个结论（本地 / 云端 / 持平 / 判不了）：
/// - 所有差异都指向同一侧 → 自动裁决，整库推 / 拉；
/// - 两个方向都有，或时间相同 / 缺失 → 判不了，交给用户在冲突决策页逐项选择。
///
/// 合并（[ModsMergePlanner]）是**并集**语义：只写入选「云端」与「仅云端有」的
/// 行；本地其余行原样保留，绝不删除本地 Mod。写入的行是远端整行原样（含
/// `created_at` / `updated_at` / `deleted_at`），墓碑与时间都能落地。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../utils/timestamp_format.dart';
import 'backup_runner.dart';

/// 读取 `mods` 行：预览、逐 Mod PK、合并三处共用同一份列清单与排序。
///
/// 列名一律加引号（`current_time` 之类的保留字曾被 SQLite 当关键字解析过）。
const String modRowsSql =
    'SELECT "mod_uuid", "name", "description", "pre_prompt", "post_prompt", '
    '"system_prompt", "world_book", "created_at", "updated_at", "deleted_at" '
    'FROM "mods" ORDER BY "mod_uuid" ASC';

/// 从已打开的库连接读出全部 Mod 行（含墓碑）。
///
/// 本地库与云端快照都走这一份 SQL：两侧的行结构一致，比较和合并才有意义。
Future<List<Map<String, Object?>>> readModRowsFromDatabase(
  DatabaseExecutor db,
) => db.rawQuery(modRowsSql);

/// 单个 Mod 的内容指纹。
///
/// 只用于**运行时**的两侧比较，不写入清单、不参与整库摘要，所以改算法没有
/// 历史兼容问题；但仍然只取内容列，排除时间戳与纯本机状态。
class ModContentDigest {
  ModContentDigest._();

  static String ofRow(Map<String, Object?> row) {
    final payload = <Object?>[
      _textOf(row, 'mod_uuid'),
      _textOf(row, 'name'),
      _textOf(row, 'description'),
      _textOf(row, 'pre_prompt'),
      _textOf(row, 'post_prompt'),
      _textOf(row, 'system_prompt'),
      _textOf(row, 'world_book'),
      row['deleted_at'] != null,
    ];
    return sha256.convert(utf8.encode(jsonEncode(payload))).toString();
  }
}

/// 单条 Mod 的比较结论。
enum ModsPkStatus {
  /// 两侧都有、内容不同，本地时间更新。
  local,

  /// 两侧都有、内容不同，云端时间更新。
  remote,

  /// 两侧都有且内容指纹一致。
  same,

  /// 只有本地有（云端快照里没有这一行）。
  onlyLocal,

  /// 只有云端有（本地没有这一行）。
  onlyRemote,

  /// 两侧都有、内容不同，但时间相同或缺失，判不了。
  unknown,
}

extension ModsPkStatusLabel on ModsPkStatus {
  /// 卡片徽标文案。
  String get label => switch (this) {
    ModsPkStatus.local => '本地较新',
    ModsPkStatus.remote => '云端较新',
    ModsPkStatus.same => '一致',
    ModsPkStatus.onlyLocal => '仅本地有',
    ModsPkStatus.onlyRemote => '仅云端有',
    ModsPkStatus.unknown => '需要你选',
  };
}

/// 一次逐 Mod 比较的聚合结论。
enum ModsPkOutcome { local, remote, tie, unknown }

/// 一条 Mod 的比较明细（冲突页直接渲染）。
class ModsPkEntry {
  const ModsPkEntry({
    required this.uuid,
    required this.name,
    required this.status,
    this.localUpdatedAt,
    this.remoteUpdatedAt,
    this.localDeleted = false,
    this.remoteDeleted = false,
  });

  final String uuid;
  final String name;
  final ModsPkStatus status;
  final DateTime? localUpdatedAt;
  final DateTime? remoteUpdatedAt;

  /// 本地 / 云端两侧是否带墓碑（不存在的一侧恒为 false）。
  final bool localDeleted;
  final bool remoteDeleted;

  /// 需要用户逐项选择：内容不同且两侧都有，但方向无法自动判定。
  ///
  /// `same` / `onlyLocal` / `onlyRemote` 不需要选择（一致保留本地，独有行自动
  /// 带入合并结果）。
  bool get needsChoice =>
      status == ModsPkStatus.local ||
      status == ModsPkStatus.remote ||
      status == ModsPkStatus.unknown;

  bool get presentLocal => status != ModsPkStatus.onlyRemote;
  bool get presentRemote => status != ModsPkStatus.onlyLocal;

  /// uuid 前 8 位（同名 Mod 靠它区分）。
  String get uuidShort => uuid.length <= 8 ? uuid : uuid.substring(0, 8);
}

/// 逐 Mod 比较的完整结果。
class ModsPk {
  const ModsPk._({
    required this.entries,
    required this.comparable,
    this.unavailableReason = '',
  });

  /// 逐 Mod 明细不可用（读不到本地 / 云端某侧的行）。
  const ModsPk.unavailable(
    String reason, {
    List<ModsPkEntry> entries = const [],
  }) : this._(entries: entries, comparable: false, unavailableReason: reason);

  /// 按展示顺序排好的明细：需要决策的在前，`same` 在最后。
  final List<ModsPkEntry> entries;

  /// 两侧逐 Mod 明细是否可比较（false = 只能退回整库时间轴）。
  final bool comparable;

  /// 不可比较时的原因（页面直接展示）。
  final String unavailableReason;

  /// 比较两侧的原始 `mods` 行。
  static ModsPk compare({
    required List<Map<String, Object?>> localRows,
    required List<Map<String, Object?>> remoteRows,
  }) {
    final localByUuid = _byUuid(localRows);
    final remoteByUuid = _byUuid(remoteRows);
    final uuids = <String>{...localByUuid.keys, ...remoteByUuid.keys}.toList()
      ..sort();
    final entries = <ModsPkEntry>[
      for (final uuid in uuids)
        _compareOne(uuid, localByUuid[uuid], remoteByUuid[uuid]),
    ]..sort(_compareEntries);
    return ModsPk._(entries: entries, comparable: true);
  }

  /// 两侧明细是否给了同一组 uuid 与同样的逐项状态（防陈旧决策）。
  static bool sameEntries(ModsPk a, ModsPk b) {
    if (!a.comparable || !b.comparable) return false;
    if (a.entries.length != b.entries.length) return false;
    final statuses = {for (final entry in b.entries) entry.uuid: entry.status};
    for (final entry in a.entries) {
      if (statuses[entry.uuid] != entry.status) return false;
    }
    return true;
  }

  int countOf(ModsPkStatus status) =>
      entries.where((entry) => entry.status == status).length;

  /// 有差异的条目数（不含内容一致）。
  int get differenceCount =>
      entries.where((entry) => entry.status != ModsPkStatus.same).length;

  int get localWinCount => countOf(ModsPkStatus.local);
  int get remoteWinCount => countOf(ModsPkStatus.remote);
  int get onlyLocalCount => countOf(ModsPkStatus.onlyLocal);
  int get onlyRemoteCount => countOf(ModsPkStatus.onlyRemote);
  int get unknownCount => countOf(ModsPkStatus.unknown);
  int get sameCount => countOf(ModsPkStatus.same);

  /// 需要用户逐项选择的条目数。
  int get needsChoiceCount =>
      entries.where((entry) => entry.needsChoice).length;

  /// 聚合结论：全部差异指向同一侧才自动裁决，其余一律 `unknown`。
  ModsPkOutcome get outcome {
    if (!comparable) return ModsPkOutcome.unknown;
    final localDirections =
        countOf(ModsPkStatus.local) + countOf(ModsPkStatus.onlyLocal);
    final remoteDirections =
        countOf(ModsPkStatus.remote) + countOf(ModsPkStatus.onlyRemote);
    if (unknownCount > 0) return ModsPkOutcome.unknown;
    if (localDirections > 0 && remoteDirections > 0) {
      return ModsPkOutcome.unknown;
    }
    if (localDirections > 0) return ModsPkOutcome.local;
    if (remoteDirections > 0) return ModsPkOutcome.remote;
    return ModsPkOutcome.tie;
  }

  /// 面向用户的一句话解释（冲突卡片 / 提示都用它）。
  String get explanation {
    if (!comparable) {
      final reason = unavailableReason.trim();
      return reason.isEmpty ? '读不到两侧的逐 Mod 明细，无法逐项比较，需要你选择保留哪一侧。' : reason;
    }
    if (entries.isEmpty) return '两侧都没有 Mod。';
    final parts = <String>[
      if (localWinCount > 0) '本地较新 $localWinCount 个',
      if (remoteWinCount > 0) '云端较新 $remoteWinCount 个',
      if (onlyLocalCount > 0) '仅本地有 $onlyLocalCount 个',
      if (onlyRemoteCount > 0) '仅云端有 $onlyRemoteCount 个',
      if (unknownCount > 0) '时间相同或缺失 $unknownCount 个',
    ];
    final body = parts.isEmpty ? '逐 Mod 内容一致' : parts.join('、');
    return switch (outcome) {
      ModsPkOutcome.local => '逐 Mod 比较：$body，全部指向本地，可自动保留本地。',
      ModsPkOutcome.remote => '逐 Mod 比较：$body，全部指向云端，可自动采用云端。',
      ModsPkOutcome.tie => '逐 Mod 比较：两侧 Mod 内容一致，无法判断哪边更新。',
      ModsPkOutcome.unknown => '逐 Mod 比较：$body，方向不一致或无法判定，需要你逐个选择。',
    };
  }

  static Map<String, Map<String, Object?>> _byUuid(
    List<Map<String, Object?>> rows,
  ) {
    final byUuid = <String, Map<String, Object?>>{};
    for (final row in rows) {
      final uuid = _textOf(row, 'mod_uuid');
      if (uuid.isEmpty) continue;
      byUuid[uuid] = row;
    }
    return byUuid;
  }

  static ModsPkEntry _compareOne(
    String uuid,
    Map<String, Object?>? local,
    Map<String, Object?>? remote,
  ) {
    final localTime = parseTimestamp(local?['updated_at']);
    final remoteTime = parseTimestamp(remote?['updated_at']);
    final localDeleted = local?['deleted_at'] != null;
    final remoteDeleted = remote?['deleted_at'] != null;
    final ModsPkStatus status;
    if (local == null) {
      status = ModsPkStatus.onlyRemote;
    } else if (remote == null) {
      status = ModsPkStatus.onlyLocal;
    } else if (ModContentDigest.ofRow(local) ==
        ModContentDigest.ofRow(remote)) {
      status = ModsPkStatus.same;
    } else if (localTime == null || remoteTime == null) {
      status = ModsPkStatus.unknown;
    } else {
      final comparison = localTime.toUtc().compareTo(remoteTime.toUtc());
      status = comparison > 0
          ? ModsPkStatus.local
          : comparison < 0
          ? ModsPkStatus.remote
          : ModsPkStatus.unknown;
    }
    return ModsPkEntry(
      uuid: uuid,
      name: _preferredName(local, remote),
      status: status,
      localUpdatedAt: localTime,
      remoteUpdatedAt: remoteTime,
      localDeleted: localDeleted,
      remoteDeleted: remoteDeleted,
    );
  }

  static String _preferredName(
    Map<String, Object?>? local,
    Map<String, Object?>? remote,
  ) {
    final localName = _textOf(local, 'name').trim();
    if (localName.isNotEmpty) return localName;
    final remoteName = _textOf(remote, 'name').trim();
    if (remoteName.isNotEmpty) return remoteName;
    return '（未命名 Mod）';
  }

  /// 排序：需要决策的在前，其次按名称 / uuid，保证页面顺序稳定。
  static int _compareEntries(ModsPkEntry a, ModsPkEntry b) {
    final byStatus = _statusOrder(a.status).compareTo(_statusOrder(b.status));
    if (byStatus != 0) return byStatus;
    final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    if (byName != 0) return byName;
    return a.uuid.compareTo(b.uuid);
  }

  static int _statusOrder(ModsPkStatus status) => switch (status) {
    ModsPkStatus.unknown => 0,
    ModsPkStatus.local => 1,
    ModsPkStatus.remote => 2,
    ModsPkStatus.onlyLocal => 3,
    ModsPkStatus.onlyRemote => 4,
    ModsPkStatus.same => 5,
  };
}

/// 逐 Mod 合并的计划结果。
class ModsMergePlan {
  const ModsMergePlan({
    this.rowsToWrite = const [],
    this.localKept = 0,
    this.remoteTaken = 0,
  });

  /// 需要写进本地 Mod 库的远端行（整行原样，含墓碑与时间）。
  final List<Map<String, Object?>> rowsToWrite;

  /// 保留本地版本的条目数（一致 / 仅本地 / 选本地）。
  final int localKept;

  /// 采用云端版本的条目数（仅云端 / 选云端）。
  final int remoteTaken;

  bool get isEmpty => rowsToWrite.isEmpty;
}

/// 合并计划不合法（缺选择 / 缺远端行）。
class ModsMergeException implements Exception {
  const ModsMergeException(this.message);

  final String message;

  @override
  String toString() => 'ModsMergeException: $message';
}

/// 把「逐 Mod 选择」翻译成要写进本地的远端行（纯逻辑，无 I/O）。
///
/// 规则（并集）：
/// - 内容一致 / 仅本地有 / 选择本地 → 保留本地，不写入；
/// - 仅云端有 → 自动带入云端行；
/// - 选择云端 → 写入云端行；
/// - 两侧都有且内容不同（`local` / `remote` / `unknown`）却没给选择 → 报错；
/// - 远端缺行 → 报错（快照与清单不匹配，不能吞）。
class ModsMergePlanner {
  ModsMergePlanner._();

  static ModsMergePlan plan({
    required ModsPk comparison,
    required Map<String, BackupConflictChoice> choices,
    required Map<String, Map<String, Object?>> remoteRowsByUuid,
  }) {
    if (!comparison.comparable) {
      throw const ModsMergeException('读不到两侧的逐 Mod 明细，无法合并');
    }
    final rows = <Map<String, Object?>>[];
    final missing = <String>[];
    var localKept = 0;
    var remoteTaken = 0;
    for (final entry in comparison.entries) {
      switch (entry.status) {
        case ModsPkStatus.same:
        case ModsPkStatus.onlyLocal:
          localKept++;
        case ModsPkStatus.onlyRemote:
          rows.add(_remoteRowOf(entry, remoteRowsByUuid));
          remoteTaken++;
        case ModsPkStatus.local:
        case ModsPkStatus.remote:
        case ModsPkStatus.unknown:
          final choice = choices[entry.uuid];
          if (choice == BackupConflictChoice.remote) {
            rows.add(_remoteRowOf(entry, remoteRowsByUuid));
            remoteTaken++;
          } else if (choice == BackupConflictChoice.local) {
            localKept++;
          } else {
            missing.add(
              entry.name.trim().isEmpty ? entry.uuidShort : entry.name.trim(),
            );
          }
      }
    }
    if (missing.isNotEmpty) {
      final preview = missing.take(3).join('、');
      throw ModsMergeException(
        '还有 ${missing.length} 个 Mod 没有选择：$preview'
        '${missing.length > 3 ? ' 等' : ''}',
      );
    }
    return ModsMergePlan(
      rowsToWrite: rows,
      localKept: localKept,
      remoteTaken: remoteTaken,
    );
  }

  static Map<String, Object?> _remoteRowOf(
    ModsPkEntry entry,
    Map<String, Map<String, Object?>> remoteRowsByUuid,
  ) {
    final row = remoteRowsByUuid[entry.uuid];
    if (row == null) {
      throw ModsMergeException('云端缺少 Mod「${entry.name}」的内容，请重新同步');
    }
    return Map<String, Object?>.from(row);
  }
}

String _textOf(Map<String, Object?>? row, String column) {
  if (row == null) return '';
  final value = row[column];
  return value is String ? value : '';
}
