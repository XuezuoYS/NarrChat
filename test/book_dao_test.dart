import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/database/book_dao.dart';
import 'package:narrchat/database/database_helper.dart';
import 'package:narrchat/models/book.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// [BookDao] 的「记忆总结轮次合并」档位契约（真库 + 临时目录，不触碰用户数据）。
///
/// 要求：库内出现 0 / 5 / 10 以外的值时按 0 读出，并在下一次保存该书设置时
/// 回写为 0（自愈）；受支持档位原样往返。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory dir;
  late String dbPath;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('book_dao_test_');
    dbPath = p.join(dir.path, 'narrchat.db');
    DatabaseHelper.debugDatabasePathOverride = dbPath;
  });

  tearDown(() async {
    DatabaseHelper.debugDatabasePathOverride = null;
    await DatabaseHelper.instance.close();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {
      // 忽略清理失败。
    }
  });

  /// 直读库内原始档位（绕过模型收敛，验证真实落库值）。
  Future<Object?> rawTier(String uuid) async {
    final db = await DatabaseHelper.instance.database;
    final rows = await db.query(
      'books',
      columns: ['memory_summary_rounds'],
      where: 'uuid = ?',
      whereArgs: [uuid],
    );
    return rows.single['memory_summary_rounds'];
  }

  test('新建书籍默认 0；写入 5 / 10 原样往返', () async {
    final dao = BookDao();
    final uuid = await dao.insertBook(const Book(title: '书A'));
    expect(await rawTier(uuid), 0, reason: '默认不开启');
    expect((await dao.getBookByUuid(uuid))!.memorySummaryRounds, 0);

    for (final tier in const [5, 10]) {
      await dao.updateBook(
        Book(uuid: uuid, title: '书A', memorySummaryRounds: tier),
      );
      expect(await rawTier(uuid), tier);
      expect((await dao.getBookByUuid(uuid))!.memorySummaryRounds, tier);
      expect((await dao.getAllBooks()).single.memorySummaryRounds, tier);
    }
  });

  test('库内非三档位（7）：读出按 0 执行，保存后回写为 0', () async {
    final dao = BookDao();
    final uuid = await dao.insertBook(const Book(title: '书A'));
    // 模拟脏数据（手工改库 / 已移除的档位）：直接写列，绕过模型收敛。
    final db = await DatabaseHelper.instance.database;
    await db.update(
      'books',
      {'memory_summary_rounds': 7},
      where: 'uuid = ?',
      whereArgs: [uuid],
    );
    expect(await rawTier(uuid), 7, reason: '前置：库里确实是越界值');

    final read = (await dao.getBookByUuid(uuid))!;
    expect(read.memorySummaryRounds, 0, reason: '读取即按 0 执行');
    expect((await dao.getAllBooks()).single.memorySummaryRounds, 0,
        reason: '列表读取同口径');

    await dao.updateBook(read);
    expect(await rawTier(uuid), 0, reason: '保存该书设置即把脏数据自愈为 0');
  });
}
