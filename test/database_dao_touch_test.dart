import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/database/book_dao.dart';
import 'package:narrchat/database/database_helper.dart';
import 'package:narrchat/database/mod_dao.dart';
import 'package:narrchat/database/round_dao.dart';
import 'package:narrchat/database/world_book_dao.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/mod.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/models/world_book_entry.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// DAO 写入路径时间戳 bump + 软删过滤回归测试。
///
/// 用 `DatabaseHelper.debugDatabasePathOverride` 指向临时库，跑真实 DAO，
/// 覆盖：轮次 / 世界书 / 书‑Mod 写入后对应 `books.*_updated_at` 递增，
/// 以及 `softDeleteBook` 后默认列表隐藏、`includeDeleted` 可见、轮次保留。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory dir;
  late String dbPath;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('dao_touch_test_');
    dbPath = p.join(dir.path, 'narrchat.db');
    DatabaseHelper.debugDatabasePathOverride = dbPath;
  });

  tearDown(() async {
    DatabaseHelper.debugDatabasePathOverride = null;
    await DatabaseHelper.instance.close();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {
      // 忽略清理失败（Windows 句柄可能未即时释放）。
    }
  });

  Future<Map<String, Object?>> bookRow(int id) async {
    final db = await DatabaseHelper.instance.database;
    return (await db.query('books', where: 'id = ?', whereArgs: [id])).first;
  }

  Future<void> resetTimestamps(int id) async {
    final db = await DatabaseHelper.instance.database;
    await db.update(
      'books',
      {'settings_updated_at': 100, 'rounds_updated_at': 100},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> settingsOf(int id) async =>
      (await bookRow(id))['settings_updated_at'] as int;
  Future<int> roundsOf(int id) async =>
      (await bookRow(id))['rounds_updated_at'] as int;

  test('软删书：默认隐藏、includeDeleted 可见、轮次保留', () async {
    final bookDao = BookDao();
    final roundDao = RoundDao();
    final bookId = await bookDao.insertBook(const Book(title: '书A', category: '玄幻'));
    await roundDao.insertRound(
      Round(bookId: bookId, roundIndex: 1, userInput: '你好'),
    );

    // 未删除时正常可见。
    expect((await bookDao.getAllBooks()).map((b) => b.id), contains(bookId));
    expect((await bookDao.getBookById(bookId))!.id, bookId);

    await bookDao.softDeleteBook(bookId);

    // 默认过滤墓碑：列表与按 id 查询均不可见。
    expect(await bookDao.getAllBooks(), isEmpty);
    expect(await bookDao.getBookById(bookId), isNull);
    // includeDeleted 仍可见，且标记已删。
    expect((await bookDao.getBookById(bookId, includeDeleted: true))!.id, bookId);
    expect((await bookRow(bookId))['deleted_at'], isNotNull);
    // 软删不级联清空轮次。
    expect(await roundDao.getRoundsByBook(bookId), hasLength(1));
  });

  test('写世界书/轮次/书-Mod 后仅对应时间戳递增', () async {
    final bookDao = BookDao();
    final roundDao = RoundDao();
    final wbDao = WorldBookDao();
    final modDao = ModDao();
    final bookId = await bookDao.insertBook(const Book(title: '书B'));

    // 世界书写入 → settings 递增、rounds 不变。
    await resetTimestamps(bookId);
    await wbDao.insertEntry(
      WorldBookEntry(bookId: bookId, keyword: '主角', content: '设定'),
    );
    expect(await settingsOf(bookId), greaterThan(100));
    expect(await roundsOf(bookId), 100);

    // 轮次写入 → rounds 递增、settings 不变。
    await resetTimestamps(bookId);
    await roundDao.insertRound(
      Round(bookId: bookId, roundIndex: 1, userInput: '开始'),
    );
    expect(await roundsOf(bookId), greaterThan(100));
    expect(await settingsOf(bookId), 100);

    // 书-Mod 配置保存 → settings 递增、rounds 不变。
    await resetTimestamps(bookId);
    await modDao.replaceBookMods(
      bookId,
      [BookModConfig(bookId: bookId, presetKey: 'web_novel_style')],
    );
    expect(await settingsOf(bookId), greaterThan(100));
    expect(await roundsOf(bookId), 100);
  });

  test('更新/删除轮次与世界书同样 bump 对应时间戳', () async {
    final bookDao = BookDao();
    final roundDao = RoundDao();
    final wbDao = WorldBookDao();
    final bookId = await bookDao.insertBook(const Book(title: '书C'));
    final roundId = await roundDao.insertRound(
      Round(bookId: bookId, roundIndex: 1, userInput: '开始'),
    );
    final entryId = await wbDao.insertEntry(
      WorldBookEntry(bookId: bookId, keyword: '主角', content: '设定'),
    );

    // updateRound → rounds 递增。
    await resetTimestamps(bookId);
    final roundsBefore = await roundsOf(bookId);
    await roundDao.updateRound(
      (await roundDao.getRoundById(roundId))!.copyWith(userInput: '改'),
    );
    expect(await roundsOf(bookId), greaterThan(roundsBefore));

    // updateRoundFields → rounds 递增。
    await resetTimestamps(bookId);
    await roundDao.updateRoundFields(roundId, {'user_input': '再改'});
    expect(await roundsOf(bookId), greaterThan(100));

    // deleteRound → rounds 递增，settings 不变。
    await resetTimestamps(bookId);
    await roundDao.deleteRound(roundId);
    expect(await roundsOf(bookId), greaterThan(100));
    expect(await settingsOf(bookId), 100);

    // updateEntry → settings 递增。
    await resetTimestamps(bookId);
    await wbDao.updateEntry(
      (await wbDao.getEntriesByBook(bookId)).single.copyWith(content: '新设定'),
    );
    expect(await settingsOf(bookId), greaterThan(100));

    // deleteEntry → settings 递增。
    await resetTimestamps(bookId);
    await wbDao.deleteEntry(entryId);
    expect(await settingsOf(bookId), greaterThan(100));

    // deleteEntriesByBook / deleteRoundsByBook → 对应递增。
    await resetTimestamps(bookId);
    await wbDao.insertEntry(
      WorldBookEntry(bookId: bookId, keyword: '另一', content: '内容'),
    );
    await wbDao.deleteEntriesByBook(bookId);
    expect(await settingsOf(bookId), greaterThan(100));

    await resetTimestamps(bookId);
    await roundDao.insertRound(
      Round(bookId: bookId, roundIndex: 2, userInput: '第二轮'),
    );
    await roundDao.deleteRoundsByBook(bookId);
    expect(await roundsOf(bookId), greaterThan(100));
  });
}
