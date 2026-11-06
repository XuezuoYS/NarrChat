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
/// - `raw_response`：当前恒空，但它是内容列，参与哈希更安全（将来会填）。
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
            'world_book',
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
      final rows = await db.rawQuery(spec.sql);
      for (final row in rows) {
        input.add(utf8.encode(jsonEncode(row)));
        input.add(const [10]);
      }
    }
    input.close();
    return sink.value.toString();
  }
}

/// 一条摘要查询：表名 + 列清单 (+ 墓碑布尔 + 排序)。
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
  });

  /// 表名。
  final String table;

  /// 参与哈希的列（按这个顺序进 SELECT，也就是 JSON 的键序）。
  final List<String> columns;

  /// 非空时额外哈希 `(<列> IS NOT NULL) AS is_deleted`（墓碑只取布尔）。
  final String? deletedColumn;

  /// 排序键；空 = 不排序（单行表）。
  final List<String> orderBy;

  String get sql {
    final parts = <String>[
      ...columns.map(_quote),
      if (deletedColumn != null)
        '(${_quote(deletedColumn!)} IS NOT NULL) AS "is_deleted"',
    ];
    final order = orderBy.isEmpty
        ? ''
        : ' ORDER BY ${orderBy.map(_quote).join(', ')}';
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
