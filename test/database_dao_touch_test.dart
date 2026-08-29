import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/database/book_dao.dart';
import 'package:narrchat/database/database_helper.dart';
import 'package:narrchat/database/mod_dao.dart';
import 'package:narrchat/database/round_dao.dart';
import 'package:narrchat/database/world_book_dao.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/failed_attempt.dart';
import 'package:narrchat/models/mod.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/models/world_book_entry.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 写时间戳契约测试：每次会改动同步部件的本地写入都必须触碰对应时间戳，
/// 否则「本地比云端新」永远判不出来，本地编辑不会被推送。
///
/// 时间戳按部件分列：内容（轮次 / 失败条目）→ rounds_updated_at，
/// 设置（设置字段 / 世界书 / 书‑Mod）→ settings_updated_at。
///
/// 书籍主键即 uuid，`touchBook` 与所有子表引用都以 uuid 定位。
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
      // 忽略清理失败。
    }
  });

  test('updateBook 刷新设置时间戳（改设置可被推送到云端）', () async {
    final bookDao = BookDao();
    final bookUuid =
        await bookDao.insertBook(const Book(title: '书A', category: '玄幻'));
    await resetTimestamps(bookUuid);
    final updated = await bookDao
        .updateBook(Book(uuid: bookUuid, title: '书A', category: '都市'));
    expect(updated, greaterThan(0));
    final row = await bookRow(bookUuid);
    expect((row['settings_updated_at'] as int?) ?? 0,
        greaterThan((row['rounds_updated_at'] as int?) ?? 0),
        reason: '改设置应刷新 settings_updated_at');
    expect(row['title'], '书A');
  });

  test('软删书写墓碑并刷新双时间戳（删除可被传播）', () async {
    final bookDao = BookDao();
    final roundDao = RoundDao();
    final bookUuid = await bookDao.insertBook(const Book(title: '书A'));
    await roundDao.insertRound(
        Round(bookUuid: bookUuid, roundIndex: 1, userInput: '你好'));
    await resetTimestamps(bookUuid);

    await bookDao.softDeleteBook(bookUuid);
    final row = await bookRow(bookUuid);
    expect(row['deleted_at'], isNotNull, reason: '软删应写入删除墓碑');
    final settings = (row['settings_updated_at'] as int?) ?? 0;
    final rounds = (row['rounds_updated_at'] as int?) ?? 0;
    expect(settings, greaterThan(0), reason: '软删应刷新设置时间戳');
    expect(rounds, greaterThan(0), reason: '软删应刷新轮次时间戳');

    // 墓碑行对普通读取不可见，但按 uuid 可含墓碑读出。
    expect(await bookDao.getAllBooks(), isEmpty);
    expect(await bookDao.getBookByUuid(bookUuid), isNull);
    expect(
      (await bookDao.getBookByUuid(bookUuid, includeDeleted: true))!.uuid,
      bookUuid,
    );
    // 轮次保留（同步删除传播后本地彻底清理前不丢内容）。
    expect(await roundDao.getRoundsByBook(bookUuid), hasLength(1));
  });

  test('insertRound / updateRoundFields / deleteRound 刷新轮次时间戳', () async {
    final bookDao = BookDao();
    final roundDao = RoundDao();
    final bookUuid = await bookDao.insertBook(const Book(title: '书A'));
    await resetTimestamps(bookUuid);

    final roundId = await roundDao.insertRound(
        Round(bookUuid: bookUuid, roundIndex: 1, userInput: '你好'));
    expect(await roundsOf(bookUuid), greaterThan(0), reason: '新增轮次应触写');

    // 编辑轮次（重新生成 / 改写）同样触写。
    await resetTimestamps(bookUuid);
    await roundDao.updateRoundFields(roundId, {'user_input': '改过的输入'});
    expect(await roundsOf(bookUuid), greaterThan(0));

    // 删除轮次同样触写。
    await resetTimestamps(bookUuid);
    await roundDao.deleteRound(roundId);
    expect(await roundsOf(bookUuid), greaterThan(0));
    expect(await roundDao.getRoundsByBook(bookUuid), isEmpty);
  });

  test('setFailedAttempt 触碰轮次时间戳（失败条目随轮次部件同步）', () async {
    final bookDao = BookDao();
    final bookUuid = await bookDao.insertBook(const Book(title: '书A'));
    await resetTimestamps(bookUuid);
    await bookDao.setFailedAttempt(
        bookUuid, const FailedAttempt(userInput: '半截输入', errorMessage: '超时'));
    expect(await roundsOf(bookUuid), greaterThan(0));
  });

  test('世界书写入 / 删除刷新设置时间戳', () async {
    final bookDao = BookDao();
    final wbDao = WorldBookDao();
    final bookUuid = await bookDao.insertBook(const Book(title: '书A'));
    await resetTimestamps(bookUuid);

    final entryId = await wbDao.insertEntry(
        WorldBookEntry(bookUuid: bookUuid, keyword: '主角', content: '设定'));
    expect(await settingsOf(bookUuid), greaterThan(0), reason: '新增条目应触写');

    await resetTimestamps(bookUuid);
    final existing = (await wbDao.getEntriesByBook(bookUuid)).single;
    await wbDao.updateEntry(existing.copyWith(content: '新设定'));
    expect(await settingsOf(bookUuid), greaterThan(0), reason: '更新条目应触写');

    await resetTimestamps(bookUuid);
    await wbDao.deleteEntry(entryId);
    expect(await settingsOf(bookUuid), greaterThan(0), reason: '删除条目应触写');
  });

  test('deleteEntriesByBook 刷新设置时间戳', () async {
    final bookDao = BookDao();
    final wbDao = WorldBookDao();
    final bookUuid = await bookDao.insertBook(const Book(title: '书A'));
    await wbDao.insertEntry(
        WorldBookEntry(bookUuid: bookUuid, keyword: 'k', content: 'c'));
    await resetTimestamps(bookUuid);
    await wbDao.deleteEntriesByBook(bookUuid);
    expect(await settingsOf(bookUuid), greaterThan(0));
    expect(await wbDao.getEntriesByBook(bookUuid), isEmpty);
  });

  test('书‑Mod 挂载变更刷新设置时间戳', () async {
    final bookDao = BookDao();
    final modDao = ModDao();
    final bookUuid = await bookDao.insertBook(const Book(title: '书A'));
    await resetTimestamps(bookUuid);
    await modDao.replaceBookMods(bookUuid, [
      BookModConfig(bookUuid: bookUuid, presetKey: 'web_novel_style'),
    ]);
    expect(await settingsOf(bookUuid), greaterThan(0));
  });
}

/// 读取书籍行（按主键 uuid）。
Future<Map<String, Object?>> bookRow(String bookUuid) async {
  final db = await DatabaseHelper.instance.database;
  final rows = await db.query('books', where: 'uuid = ?', whereArgs: [bookUuid], limit: 1);
  return rows.first;
}

/// 把两个时间戳重置为 0，用于断言「某次写入是否触碰了对应列」。
Future<void> resetTimestamps(String bookUuid) async {
  final db = await DatabaseHelper.instance.database;
  await db.update(
    'books',
    {'settings_updated_at': 0, 'rounds_updated_at': 0},
    where: 'uuid = ?',
    whereArgs: [bookUuid],
  );
}

Future<int> settingsOf(String bookUuid) async =>
    ((await bookRow(bookUuid))['settings_updated_at'] as int?) ?? 0;

Future<int> roundsOf(String bookUuid) async =>
    ((await bookRow(bookUuid))['rounds_updated_at'] as int?) ?? 0;
