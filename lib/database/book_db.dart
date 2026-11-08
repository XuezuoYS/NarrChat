import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/book_meta.dart';
import '../models/branch.dart';
import '../models/round_generation.dart';
import '../models/world_book_row.dart';
import '../services/app_paths.dart';
import '../utils/timestamp_format.dart';
import 'book_store.dart';
import 'db_open.dart';
import 'db_schema.dart';

/// 单本书库（`user_data/books/narrbook_<book_uuid>.db`）的 SQLite 实现。
///
/// 一条铁律：**任何写操作都走这里**。`book_meta.updated_at` 的刷新、组内
/// `is_using` 的归一化都在本类收口，不允许调用方各自拼 SQL——否则
/// "本地较新"的判断会随调用点漂移，云备份冲突裁决随之失灵。
class BookDb implements BookStore {
  BookDb._(this.bookUuid, this._db)
    : meta = _BookMetaStoreImpl._(_db),
      rounds = _RoundStoreImpl._(_db),
      branches = _BranchStoreImpl._(_db),
      worldBook = _WorldBookStoreImpl._(_db),
      useMods = _UseModStoreImpl._(_db);

  /// 正文列白名单：只允许这些列经由 [RoundStore.updateContent] 写入。
  ///
  /// 与 [RoundGeneration.contentRow] 的键集一致，`v3_schema_test` 会断言两者
  /// 相同，防止有人加列时只改一边。
  static const Set<String> contentColumns = {
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
  };

  /// 元信息列白名单（经由 [RoundStore.updateMeta] 写入）。
  static const Set<String> metaFields = {
    'message',
    'message_status',
    'operated_at',
  };

  /// 代级提示长度上限（与 R2 的 `clampMessage` 同口径）。
  ///
  /// 为什么要截：`round_stack.message` 是 TEXT，而**整本书库会作为一份快照
  /// 上云**——一条几万字的提示会把每一代快照都撑大，还会拖慢摘要计算与
  /// B-tree 写入。提示是给人看的短文本，不是正文，4000 字符绰绰有余。
  static const int maxMessageLength = 4000;

  /// 把提示截到 [maxMessageLength]，超出部分用省略号收尾。
  ///
  /// 空串 / 空白原样返回：`message` 为空就是「没有提示框」，
  /// 这里绝不能把空串变成省略号。
  static String clampMessage(String message) {
    if (message.length <= maxMessageLength) return message;
    if (maxMessageLength <= 1) return message.substring(0, maxMessageLength);
    return '${message.substring(0, maxMessageLength - 1)}…';
  }

  /// 行映射里的 `message` 过一遍截断，其它列原样。
  ///
  /// 所有写 `round_stack` 的路径（插代 / 批量导入 / 改元信息）都走这里，
  /// 避免"某条新加的写路径忘了截断"。
  static Map<String, Object?> _clampRowMessage(Map<String, Object?> row) {
    final value = row['message'];
    if (value is! String || value.length <= maxMessageLength) return row;
    return {...row, 'message': clampMessage(value)};
  }

  /// 打开一本**已存在**的书库，并校验身份。
  ///
  /// 文件不存在 / 缺 `book_meta` / `book_uuid` 与文件名不符 → 抛
  /// [DbIntegrityException]，交上层提示，不做自动修复。
  static Future<BookDb> open({
    required String bookUuid,
    String? pathOverride,
  }) async {
    final path = pathOverride ?? await AppPaths.bookDatabasePath(bookUuid);
    if (!await File(path).exists()) {
      throw DbIntegrityException(
        '书库文件不存在：${AppPaths.bookDbFileName(bookUuid)}',
      );
    }
    final db = await _openRaw(path, bookUuid);
    return BookDb._(bookUuid, db);
  }

  /// 新建一本书库（同名文件会被覆盖，仅迁移重试用）。
  static Future<BookDb> create({
    required BookMeta meta,
    String? pathOverride,
  }) async {
    final path = pathOverride ?? await AppPaths.bookDatabasePath(meta.bookUuid);
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
    final db = await openAppDatabase(
      path: path,
      version: userDataDbVersion,
      onCreate: createBookSchema,
      onUpgrade: _upgradeSchema,
    );
    await db.insert('book_meta', {
      ...meta.toRow(),
      'database_version': userDataDbVersion,
    });
    return BookDb._(meta.bookUuid, db);
  }

  /// 书库升级：从 24 起 `book_meta` 多了 `book_cover_img`。
  ///
  /// 书库是「一本书一个文件」，老书在**各自首次打开时**补列；加列前先查
  /// `PRAGMA table_info`，进度领先于版本号的库重复执行也不会报 duplicate column。
  static Future<void> _upgradeSchema(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 24 &&
        !await columnExists(db, 'book_meta', 'book_cover_img')) {
      await db.execute(
        'ALTER TABLE book_meta ADD COLUMN book_cover_img TEXT',
      );
    }
    await writeDatabaseVersion(db, 'book_meta', newVersion);
  }

  /// 打开并做完整性校验（`open` 与迁移共用）。
  ///
  /// 迁移时也用这个入口读**刚迁移出来**的书库，顺带验证产物可用。
  static Future<Database> _openRaw(String path, String bookUuid) async {
    final db = await openAppDatabase(
      path: path,
      version: userDataDbVersion,
      onCreate: createBookSchema,
      onUpgrade: _upgradeSchema,
    );
    try {
      if (!await tableExists(db, 'book_meta')) {
        throw DbIntegrityException(
          '书库缺少 book_meta 表：${AppPaths.bookDbFileName(bookUuid)}',
        );
      }
      final rows = await db.query('book_meta', limit: 2);
      if (rows.isEmpty) {
        throw DbIntegrityException(
          '书库缺少 book_meta 行：${AppPaths.bookDbFileName(bookUuid)}',
        );
      }
      if (rows.length > 1) {
        throw DbIntegrityException('book_meta 应为单行，实际 ${rows.length} 行');
      }
      final actual = (rows.first['book_uuid'] as String?) ?? '';
      if (actual != bookUuid) {
        throw DbIntegrityException('文件名与 book_meta.book_uuid 不一致：$actual');
      }
    } catch (_) {
      await db.close();
      rethrow;
    }
    return db;
  }

  @override
  final String bookUuid;

  final Database _db;

  @override
  final BookMetaStore meta;

  @override
  final RoundStore rounds;

  @override
  final BranchStore branches;

  @override
  final WorldBookStore worldBook;

  @override
  final UseModStore useMods;

  @override
  Future<void> close() => _db.close();

  /// 事务入口：跨表的写（删代 + 清孤儿、删分支 + 删轮次）走这里保证原子性。
  Future<T> transaction<T>(Future<T> Function(DatabaseExecutor txn) action) =>
      _db.transaction(action);

  /// 刷新 `book_meta.updated_at`（内容变更唯一的时间戳出口）。
  static Future<void> touch(DatabaseExecutor e) async {
    await e.update('book_meta', {'updated_at': nowTimestamp()});
  }

  /// 拷贝链分批写入的行数（同一事务内分批提交，仅用于向界面回报进度）。
  static const int _copyChunkSize = 500;

  /// 一次事务写入新分支与它的拷贝链（「从此代拷贝链」专用）。
  ///
  /// - 分支行与全部代在同一事务里落库：任一步失败整体回滚，不会留下半条分支；
  /// - 代按 [_copyChunkSize] 分批提交并回调 [onProgress]，同一事务仍然原子；
  /// - `message` 走统一的截断（见 [_clampRowMessage]）；
  /// - 只刷新一次 `book_meta.updated_at`；**不**改 `branch_working`
  ///   （新分支默认不激活，等用户点「点击跳转」再切）。
  Future<void> insertBranchCopy({
    required Branch branch,
    required List<RoundGeneration> rows,
    void Function(int done, int total)? onProgress,
  }) async {
    if (branch.isDefault) {
      throw ArgumentError('拷贝分支不能是默认分支');
    }
    await _db.transaction((txn) async {
      await txn.insert('branches', branch.toRow());
      final total = rows.length;
      onProgress?.call(0, total);
      for (var start = 0; start < total; start += _copyChunkSize) {
        final end =
            start + _copyChunkSize > total ? total : start + _copyChunkSize;
        final batch = txn.batch();
        for (var i = start; i < end; i++) {
          // 不做逐条组内归一化：拷贝保留源数据自己的 is_using，
          // 同组「至多一个选中」的不变量由源分支负责（与 importAll 同口径）。
          batch.insert('round_stack', BookDb._clampRowMessage(rows[i].toRow()));
        }
        await batch.commit(noResult: true);
        onProgress?.call(end, total);
      }
      await BookDb.touch(txn);
    });
  }
}

// ---------------------------------------------------------------------------
// book_meta
// ---------------------------------------------------------------------------

class _BookMetaStoreImpl implements BookMetaStore {
  _BookMetaStoreImpl._(this._db);

  final Database _db;

  @override
  Future<BookMeta> read() async {
    final rows = await _db.query('book_meta', limit: 2);
    if (rows.isEmpty) {
      throw DbIntegrityException('book_meta 为空');
    }
    if (rows.length > 1) {
      throw DbIntegrityException('book_meta 应为单行，实际 ${rows.length} 行');
    }
    return BookMeta.fromRow(rows.first);
  }

  @override
  Future<void> writeSettings(BookMeta meta) async {
    await _db.update('book_meta', {
      ...meta.settingsRow(),
      'updated_at': nowTimestamp(),
    });
  }

  @override
  Future<void> touch() => BookDb.touch(_db);

  @override
  Future<void> setUpdatedAt(DateTime updatedAt) async {
    await _db.update('book_meta', {'updated_at': formatTimestamp(updatedAt)});
  }
}

// ---------------------------------------------------------------------------
// round_stack
// ---------------------------------------------------------------------------

class _RoundStoreImpl implements RoundStore {
  _RoundStoreImpl._(this._db);

  final Database _db;

  /// `IN (...)` 变量数上限保守取 500（SQLite 默认上限 999）。
  static const int _chunkSize = 500;

  @override
  Future<List<RoundMeta>> listMeta() async {
    final rows = await _db.rawQuery(
      'SELECT ${RoundMeta.metaColumns} FROM round_stack '
      'ORDER BY round_index ASC, round_serial_num ASC, uuid ASC',
    );
    return rows.map(RoundMeta.fromRow).toList();
  }

  @override
  Future<List<RoundGeneration>> listGenerations({
    int? firstRoundIndex,
    int? lastRoundIndex,
  }) async {
    final where = <String>[];
    final args = <Object?>[];
    if (firstRoundIndex != null) {
      where.add('round_index >= ?');
      args.add(firstRoundIndex);
    }
    if (lastRoundIndex != null) {
      where.add('round_index <= ?');
      args.add(lastRoundIndex);
    }
    final rows = await _db.query(
      'round_stack',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'round_index ASC, round_serial_num ASC, uuid ASC',
    );
    return rows.map(RoundGeneration.fromRow).toList();
  }

  @override
  Future<RoundGeneration?> generation(String uuid) async {
    if (uuid.isEmpty) return null;
    final rows = await _db.query(
      'round_stack',
      where: 'uuid = ?',
      whereArgs: [uuid],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return RoundGeneration.fromRow(rows.first);
  }

  @override
  Future<List<RoundGeneration>> generations(Iterable<String> uuids) async {
    final ids = uuids.where((e) => e.isNotEmpty).toSet().toList();
    if (ids.isEmpty) return const [];
    final result = <RoundGeneration>[];
    for (final chunk in _chunks(ids)) {
      final placeholders = List.filled(chunk.length, '?').join(', ');
      final rows = await _db.query(
        'round_stack',
        where: 'uuid IN ($placeholders)',
        whereArgs: chunk,
        orderBy: 'round_index ASC, round_serial_num ASC, uuid ASC',
      );
      result.addAll(rows.map(RoundGeneration.fromRow));
    }
    return result;
  }

  @override
  Future<void> insert(RoundGeneration generation) async {
    if (generation.uuid.isEmpty) {
      throw ArgumentError('插入轮次需要非空 uuid');
    }
    await _db.transaction((txn) async {
      if (generation.isUsing) {
        await _clearUsingInGroup(txn, generation.meta);
      }
      await txn.insert(
        'round_stack',
        BookDb._clampRowMessage(generation.toRow()),
      );
      await BookDb.touch(txn);
    });
  }

  @override
  Future<void> importAll(List<RoundGeneration> rows) async {
    if (rows.isEmpty) return;
    await _db.transaction((txn) async {
      final batch = txn.batch();
      for (final row in rows) {
        batch.insert(
          'round_stack',
          BookDb._clampRowMessage(row.toRow()),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
      await BookDb.touch(txn);
    });
  }

  @override
  Future<void> updateContent(String uuid, Map<String, Object?> content) async {
    final filtered = _filterColumns(content, BookDb.contentColumns);
    if (filtered.isEmpty) return;
    await _db.transaction((txn) async {
      await txn.update(
        'round_stack',
        filtered,
        where: 'uuid = ?',
        whereArgs: [uuid],
      );
      await BookDb.touch(txn);
    });
  }

  @override
  Future<void> updateMeta(String uuid, Map<String, Object?> fields) async {
    final filtered = BookDb._clampRowMessage(
      _filterColumns(fields, BookDb.metaFields),
    );
    if (filtered.isEmpty) return;
    await _db.transaction((txn) async {
      await txn.update(
        'round_stack',
        filtered,
        where: 'uuid = ?',
        whereArgs: [uuid],
      );
      await BookDb.touch(txn);
    });
  }

  @override
  Future<void> setUsing(String uuid, {bool isUsing = true}) async {
    await _db.transaction((txn) async {
      final rows = await txn.query(
        'round_stack',
        columns: const ['uuid', 'branch_uuid', 'round_index', 'father_uuid'],
        where: 'uuid = ?',
        whereArgs: [uuid],
        limit: 1,
      );
      if (rows.isEmpty) return;
      final row = rows.first;
      final father = row['father_uuid'] as String?;
      final meta = RoundMeta(
        uuid: (row['uuid'] as String?) ?? '',
        fatherUuid: (father == null || father.isEmpty) ? null : father,
        branchUuid: (row['branch_uuid'] as String?) ?? '',
        roundIndex: (row['round_index'] as int?) ?? 0,
        roundSerialNum: 0,
        isUsing: isUsing,
        operatedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );
      // 设为选中时才需要"同组其它代清 0"；取消选中只动它自己，
      // 否则会把整组清成"没有一个选中"。
      if (isUsing) {
        await _clearUsingInGroup(txn, meta);
      }
      await txn.update(
        'round_stack',
        {'is_using': isUsing ? 1 : 0},
        where: 'uuid = ?',
        whereArgs: [uuid],
      );
      // 切换版本属"看哪一代"，不算内容变更：不动 book_meta.updated_at。
    });
  }

  @override
  Future<void> delete(Iterable<String> uuids) async {
    final ids = uuids.where((e) => e.isNotEmpty).toSet().toList();
    if (ids.isEmpty) return;
    await _db.transaction((txn) async {
      for (final chunk in _chunks(ids)) {
        final placeholders = List.filled(chunk.length, '?').join(', ');
        await txn.delete(
          'round_stack',
          where: 'uuid IN ($placeholders)',
          whereArgs: chunk,
        );
      }
      await BookDb.touch(txn);
    });
  }

  @override
  Future<int> count() async {
    final rows = await _db.rawQuery('SELECT COUNT(*) AS c FROM round_stack');
    return (rows.first['c'] as int?) ?? 0;
  }

  @override
  Future<int> maxRoundIndex() async {
    final rows = await _db.rawQuery(
      'SELECT MAX(round_index) AS i FROM round_stack',
    );
    final value = rows.first['i'];
    return value is int ? value : 0;
  }

  @override
  Future<DateTime?> lastRoundAt() async {
    final rows = await _db.rawQuery(
      'SELECT MAX(operated_at) AS t FROM round_stack',
    );
    final raw = rows.first['t'];
    return raw is String ? parseTimestamp(raw) : null;
  }

  @override
  Future<bool> containsImage(String imagePath) async {
    if (imagePath.isEmpty) return false;
    // JSON 文本里找子串：封面文件名是哈希，不会出现转义问题。
    final rows = await _db.rawQuery(
      'SELECT 1 FROM round_stack '
      'WHERE instr(user_images, ?) > 0 OR instr(ai_images, ?) > 0 LIMIT 1',
      [imagePath, imagePath],
    );
    return rows.isNotEmpty;
  }

  /// 把同组（分支 + 轮号 + 父代）的其它代 `is_using` 清零。
  static Future<void> _clearUsingInGroup(
    DatabaseExecutor e,
    RoundMeta meta,
  ) async {
    await e.update(
      'round_stack',
      {'is_using': 0},
      where:
          "branch_uuid = ? AND round_index = ? "
          "AND IFNULL(father_uuid, '') = IFNULL(?, '') AND uuid <> ?",
      whereArgs: [
        meta.branchUuid,
        meta.roundIndex,
        // 用空串而不是 null：SQL 侧已经 IFNULL 归一化，参数给 null 会被
        // sqflite 判为"以后会抛异常"的用法。
        meta.fatherUuid ?? '',
        meta.uuid,
      ],
    );
  }

  static Map<String, Object?> _filterColumns(
    Map<String, Object?> source,
    Set<String> allowed,
  ) {
    final unknown = source.keys.where((k) => !allowed.contains(k)).toList();
    if (unknown.isNotEmpty) {
      throw ArgumentError('不允许写入的列：${unknown.join(', ')}');
    }
    return Map<String, Object?>.from(source);
  }

  static Iterable<List<String>> _chunks(List<String> ids) sync* {
    for (var i = 0; i < ids.length; i += _chunkSize) {
      final end = i + _chunkSize > ids.length ? ids.length : i + _chunkSize;
      yield ids.sublist(i, end);
    }
  }
}

// ---------------------------------------------------------------------------
// branches
// ---------------------------------------------------------------------------

class _BranchStoreImpl implements BranchStore {
  _BranchStoreImpl._(this._db);

  final Database _db;

  @override
  Future<List<Branch>> list() async {
    final rows = await _db.query(
      'branches',
      orderBy: 'created_at ASC, branch_uuid ASC',
    );
    return rows.map(Branch.fromRow).toList();
  }

  @override
  Future<Branch?> get(String branchUuid) async {
    if (branchUuid.isEmpty) return null;
    final rows = await _db.query(
      'branches',
      where: 'branch_uuid = ?',
      whereArgs: [branchUuid],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Branch.fromRow(rows.first);
  }

  @override
  Future<void> upsert(Branch branch) async {
    if (branch.isDefault) {
      throw ArgumentError('默认分支不记 branches 表');
    }
    await _db.transaction((txn) async {
      await txn.insert(
        'branches',
        branch.toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await BookDb.touch(txn);
    });
  }

  @override
  Future<void> setWorking(String branchUuid) async {
    await _db.transaction((txn) async {
      await txn.update('branches', {'branch_working': 0});
      if (branchUuid.isNotEmpty) {
        await txn.update(
          'branches',
          {'branch_working': 1},
          where: 'branch_uuid = ?',
          whereArgs: [branchUuid],
        );
      }
      // 分支激活属本机会话状态：不动 book_meta.updated_at，也不进云备份摘要。
    });
  }

  @override
  Future<void> delete(String branchUuid) async {
    if (branchUuid.isEmpty) {
      throw ArgumentError('默认分支不可删除');
    }
    await _db.transaction((txn) async {
      await txn.delete(
        'branches',
        where: 'branch_uuid = ?',
        whereArgs: [branchUuid],
      );
      await BookDb.touch(txn);
    });
  }
}

// ---------------------------------------------------------------------------
// world_book_entries
// ---------------------------------------------------------------------------

class _WorldBookStoreImpl implements WorldBookStore {
  _WorldBookStoreImpl._(this._db);

  final Database _db;

  @override
  Future<List<WorldBookRow>> list() async {
    final rows = await _db.query(
      'world_book_entries',
      orderBy: 'created_at ASC, uuid ASC',
    );
    return rows.map(WorldBookRow.fromRow).toList();
  }

  @override
  Future<void> upsert(WorldBookRow row) async {
    if (row.uuid.isEmpty) {
      throw ArgumentError('世界书条目需要非空 uuid');
    }
    await _db.transaction((txn) async {
      await txn.insert(
        'world_book_entries',
        row.toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await BookDb.touch(txn);
    });
  }

  @override
  Future<void> delete(String uuid) async {
    await _db.transaction((txn) async {
      await txn.delete(
        'world_book_entries',
        where: 'uuid = ?',
        whereArgs: [uuid],
      );
      await BookDb.touch(txn);
    });
  }

  @override
  Future<void> replaceAll(List<WorldBookRow> rows) async {
    await _db.transaction((txn) async {
      await txn.delete('world_book_entries');
      final batch = txn.batch();
      for (final row in rows) {
        batch.insert(
          'world_book_entries',
          row.toRow(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
      await BookDb.touch(txn);
    });
  }
}

// ---------------------------------------------------------------------------
// use_mods
// ---------------------------------------------------------------------------

class _UseModStoreImpl implements UseModStore {
  _UseModStoreImpl._(this._db);

  final Database _db;

  @override
  Future<List<UseModRow>> list() async {
    final rows = await _db.query(
      'use_mods',
      orderBy: 'sort_order ASC, mod_uuid ASC',
    );
    return rows.map(UseModRow.fromRow).toList();
  }

  @override
  Future<void> replaceAll(List<UseModRow> rows) async {
    await _db.transaction((txn) async {
      await txn.delete('use_mods');
      for (final row in rows) {
        await txn.insert('use_mods', row.toRow());
      }
      await BookDb.touch(txn);
    });
  }
}
