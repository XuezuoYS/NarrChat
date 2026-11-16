import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'backup_unit.dart';

/// 内容摘要算法版本。
///
/// 参与哈希前缀；改算法（增删参与字段、换编码）时必须 +1，
/// 否则两台设备会算出不同的摘要而互相认为"对方变了"。
///
/// 2026-11-06 的 `current_time` 关键字撞名修复**故意不升版本**：
/// 旧摘要里混的是查询时刻，本来就不稳定，两台设备从来对不上；升版本会让
/// 既有云端清单统一走「摘要版本不同 → 冲突」，而面板目前没有冲突裁决入口，
/// 同步会卡死。不升版本时，修复后每个单元只会多推一代重建基线，下一轮即
/// `upToDate`，自动收敛。
const int backupDigestVersion = 1;

/// 规范化内容摘要：只对"内容"做哈希，**排除**时间戳与纯本机状态。
///
/// 排除清单（写死在这里，改它就要升 [backupDigestVersion]）：
/// - 所有时间列：`created_at` / `updated_at` / `operated_at` / `deleted_at` 的具体值
///   （墓碑只取"是否删除"这个布尔，否则一台设备只要打开过一次就会认为内容变了）；
/// - `branches.branch_working`：本机当前看哪个分支，不是内容；
/// - `meta` / `book_meta` 的 `master_uuid` 与 `database_version`：身份与镜像值；
/// - `raw_response`：当前恒空，但它是内容列，参与哈希更安全（将来会填）；
/// - `mods` 的 v26 三个新列**值为空时完全不出现在哈希里**（见
///   [_DigestTable.omitIfEmpty]）：加列不升版本、也不让升级首同步凭空制造冲突。
///
/// 为什么必须排除时间戳：每台设备每次保存都会刷新 `updated_at`，
/// 如果它进摘要，两台设备会永远觉得对方"又改了"，无限互推代数。
class BackupDigest {
  BackupDigest._();

  static Future<String> ofUnit(BackupUnit unit, DatabaseExecutor db) {
    return switch (unit.kind) {
      BackupUnitKind.library => ofLibrary(unit, db),
      BackupUnitKind.mods => ofMods(unit, db),
      BackupUnitKind.book => ofBook(unit, db),
    };
  }

  static Future<String> ofLibrary(BackupUnit unit, DatabaseExecutor db) =>
      _compute(unit, db, const [
        _DigestTable(
          table: 'books',
          columns: ['book_uuid', 'title'],
          deletedColumn: 'deleted_at',
          orderBy: ['book_uuid'],
        ),
      ]);

  static Future<String> ofMods(BackupUnit unit, DatabaseExecutor db) =>
      _compute(unit, db, const [
        _DigestTable(
          table: 'mods',
          columns: [
            'mod_uuid',
            'name',
            'description',
            'pre_prompt',
            'post_prompt',
            'system_prompt',
            'system_setting',
            'system_writing_style',
            'system_must',
            'world_book',
          ],
          // v26 的三个新列**空值不参与哈希**（缺列时也等于空）：
          // 这样未填写新列的 Mod 摘要与升级前逐字节一致，升级后首次同步不会
          // 把每个单元误判成「本地改过」而弹冲突。
          omitIfEmpty: [
            'system_setting',
            'system_writing_style',
            'system_must',
          ],
          deletedColumn: 'deleted_at',
          orderBy: ['mod_uuid'],
        ),
      ]);

  static Future<String> ofBook(BackupUnit unit, DatabaseExecutor db) =>
      _compute(unit, db, const [
        _DigestTable(
          table: 'book_meta',
          columns: [
            'book_uuid',
            'title',
            'category',
            'base_setting',
            'writing_requirements',
            'writing_style',
            'global_pre_prompt',
            'global_post_prompt',
            'history_rounds',
            'memory_summary_rounds',
            'role_hierarchy',
            'role_hierarchy_detail',
          ],
        ),
        _DigestTable(
          table: 'world_book_entries',
          columns: ['uuid', 'keyword', 'content', 'is_using'],
          orderBy: ['uuid'],
        ),
        _DigestTable(
          table: 'use_mods',
          columns: ['mod_uuid', 'sort_order'],
          orderBy: ['mod_uuid'],
        ),
        _DigestTable(
          table: 'branches',
          columns: [
            'branch_uuid',
            'father_row',
            'father_row_index',
            'father_branch',
            'branch_name',
            'father_row_shot',
          ],
          orderBy: ['branch_uuid'],
        ),
        // 注意：`subagent_*`（非创作步子模型统计）刻意**不参与**摘要。
        // 它们是展示用统计元数据，加列不升 `backupDigestVersion`，避免升级后
        // 首次同步对每个单元弹摘要版本冲突；统计随书库快照照常上传。
        _DigestTable(
          table: 'round_stack',
          columns: [
            'uuid',
            'father_uuid',
            'branch_uuid',
            'round_index',
            'round_serial_num',
            'is_using',
            'message_status',
            'message',
            'model_name',
            'tokens_in',
            'tokens_cached_in',
            'tokens_out',
            'raw_response',
            'user_input',
            'ai_narrative',
            'world_state',
            'character_state',
            'memory_summary',
            'current_time',
            'recommended_action',
            'user_images',
            'ai_images',
          ],
          orderBy: ['uuid'],
        ),
      ]);

  static Future<String> _compute(
    BackupUnit unit,
    DatabaseExecutor db,
    List<_DigestTable> tables,
  ) async {
    final sink = _DigestSink();
    final input = sha256.startChunkedConversion(sink);
    input.add(utf8.encode('$backupDigestVersion|${unit.unitKey}\n'));
    for (final spec in tables) {
      input.add(utf8.encode('## ${spec.table}\n'));
      // 列可能还不存在（例如升级前从未打开过的 v25 文件被同步读到）：
      // 缺列等价于「空值」，与 `omitIfEmpty` 的处理口径一致。
      final existing = await _columnsOf(db, spec.table);
      final rows = await db.rawQuery(spec.sqlFor(existing));
      for (final row in rows) {
        final payload = spec.omitIfEmpty.isEmpty
            ? row
            : <String, Object?>{
                for (final entry in row.entries)
                  if (!spec.isEmptyOmitted(entry.key, entry.value))
                    entry.key: entry.value,
              };
        input.add(utf8.encode(jsonEncode(payload)));
        input.add(const [10]);
      }
    }
    input.close();
    return sink.value.toString();
  }

  /// 表的实际列名集合（`PRAGMA table_info`，只用来容忍缺列）。
  static Future<Set<String>> _columnsOf(
    DatabaseExecutor db,
    String table,
  ) async {
    final rows = await db.rawQuery('PRAGMA table_info("$table")');
    return {for (final row in rows) row['name'] as String? ?? ''};
  }
}

/// 一条摘要查询：表名 + 列清单 (+ 墓碑布尔 + 排序 + 空值省略)。
///
/// **列名一律加引号**：SQLite 会把裸写的 `current_time` 解析成 `CURRENT_TIME`
/// 关键字（查询时刻的墙上时间），摘要于是每秒都变，同步就"没改也 +1 代"。
/// `order` / `key` / `group` 这类保留字同理，统一加引号一劳永逸。
class _DigestTable {
  const _DigestTable({
    required this.table,
    required this.columns,
    this.deletedColumn,
    this.orderBy = const [],
    this.omitIfEmpty = const [],
  });

  /// 表名。
  final String table;

  /// 参与哈希的列（按这个顺序进 SELECT，也就是 JSON 的键序）。
  final List<String> columns;

  /// 非空时额外哈希 `(<列> IS NOT NULL) AS is_deleted`（墓碑只取布尔）。
  final String? deletedColumn;

  /// 排序键；空 = 不排序（单行表）。
  final List<String> orderBy;

  /// 值为 `null` / 空串时**从行里删掉**的列。
  ///
  /// 用途：加列不升 `backupDigestVersion` 也不制造冲突——旧行本来就没有这些值，
  /// 让"空"等价于"不存在"。缺列（老快照）同样按不存在处理。
  final List<String> omitIfEmpty;

  /// 该键值是否属于「空值省略」。
  bool isEmptyOmitted(String? key, Object? value) =>
      key != null &&
      omitIfEmpty.contains(key) &&
      (value == null || (value is String && value.isEmpty));

  /// 按表的**实际列**拼 SELECT：`existing` 里没有的列直接不取。
  String sqlFor(Set<String> existing) {
    final parts = <String>[
      ...columns.where(existing.contains).map(_quote),
      if (deletedColumn != null && existing.contains(deletedColumn))
        '(${_quote(deletedColumn!)} IS NOT NULL) AS "is_deleted"',
    ];
    final order = orderBy.isEmpty
        ? ''
        : ' ORDER BY ${orderBy.where(existing.contains).map(_quote).join(', ')}';
    return 'SELECT ${parts.join(', ')} FROM ${_quote(table)}$order';
  }

  static String _quote(String name) => '"$name"';
}

/// 收集分块哈希的最终结果（`crypto` 只提供 `Sink<Digest>` 入口）。
class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
