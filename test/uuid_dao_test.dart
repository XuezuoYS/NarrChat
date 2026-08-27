import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/database/book_dao.dart';
import 'package:narrchat/database/database_helper.dart';
import 'package:narrchat/database/mod_dao.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/mod.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 书籍 / Mod uuid 身份测试：插入生成、更新不覆盖、软删墓碑与引用清理。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory dir;
  late String dbPath;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('uuid_dao_test_');
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

  test('insertBook 自动生成 uuid；updateBook 不覆盖既有 uuid', () async {
    final dao = BookDao();
    final id = await dao.insertBook(const Book(title: '书A'));
    final created = await dao.getBookById(id);
    expect(created!.uuid, isNotEmpty);
    final originalUuid = created.uuid;

    // UI 直接构造不带 uuid 的 Book 更新 → 沿用库中 uuid。
    await dao.updateBook(Book(id: id, title: '书A', category: '玄幻'));
    final updated = await dao.getBookById(id);
    expect(updated!.uuid, originalUuid, reason: 'uuid 为同步身份，不可被覆盖');
    expect(updated.category, '玄幻');

    // 显式携带 uuid 时按传入值更新（身份迁移路径）。
    await dao.updateBook(
      Book(id: id, uuid: 'u-migrated', title: '书A'),
    );
    expect((await dao.getBookById(id))!.uuid, 'u-migrated');
  });

  test('insertMod 生成 uuid；updateMod 不覆盖；deleteMod 软删并清理引用', () async {
    final bookDao = BookDao();
    final bookId = await bookDao.insertBook(const Book(title: '书X'));
    final modDao = ModDao();
    final modId = await modDao.insertMod(const Mod(name: '风格'));
    final created = (await modDao.getAllMods()).single;
    final originalUuid = created.uuid;
    expect(originalUuid, isNotEmpty);

    // 书籍挂载该 Mod。
    await modDao.replaceBookMods(bookId, [
      BookModConfig(bookId: bookId, modId: modId, sortOrder: 0),
    ]);

    // 更新不覆盖 uuid（Mod 编辑对话框走 copyWith 保留，双保险）。
    await modDao.updateMod(Mod(id: modId, name: '风格2'));
    final updated = (await modDao.getAllMods()).single;
    expect(updated.uuid, originalUuid, reason: 'uuid 不可被更新覆盖');
    expect(updated.name, '风格2');

    // 软删：getAllMods 不再返回、book_mods 引用被清理、书籍写时间戳刷新。
    final before = await GetBookTimes.read(bookId);
    await modDao.deleteMod(modId);
    expect(await modDao.getAllMods(), isEmpty);
    expect(await modDao.getBookMods(bookId), isEmpty);
    final after = await GetBookTimes.read(bookId);
    expect(after, greaterThan(before), reason: '软删引用应刷新书籍设置时间戳');
  });

  test('replaceBookMods 语义一致时跳过写入（保存幂等，不产生假变更）', () async {
    final bookDao = BookDao();
    final bookId = await bookDao.insertBook(const Book(title: '书Y'));
    final modDao = ModDao();
    final modId1 = await modDao.insertMod(const Mod(name: 'm1'));
    final modId2 = await modDao.insertMod(const Mod(name: 'm2'));

    final configs = [
      BookModConfig(bookId: bookId, modId: modId1, sortOrder: 0, isEnabled: true),
      BookModConfig(bookId: bookId, modId: modId2, sortOrder: 1, isEnabled: false),
    ];
    await modDao.replaceBookMods(bookId, configs);
    final before = await GetBookTimes.read(bookId);

    // 相同内容再保存（新 BookModConfig 实例、无 id）→ 跳过写入。
    final same = [
      BookModConfig(bookId: bookId, modId: modId1, sortOrder: 0, isEnabled: true),
      BookModConfig(bookId: bookId, modId: modId2, sortOrder: 1, isEnabled: false),
    ];
    await modDao.replaceBookMods(bookId, same);
    expect(await GetBookTimes.read(bookId), before, reason: '无变更保存不应触写');

    // 语义变化 → 落库。
    final changed = [
      BookModConfig(bookId: bookId, modId: modId1, sortOrder: 0, isEnabled: true),
      BookModConfig(bookId: bookId, modId: modId2, sortOrder: 1, isEnabled: true),
    ];
    await modDao.replaceBookMods(bookId, changed);
    expect(await GetBookTimes.read(bookId), greaterThan(before));
  });
}

/// 读取书籍设置时间戳（断言 `touchBook` 行为）。
class GetBookTimes {
  static Future<int> read(int bookId) async {
    final db = await DatabaseHelper.instance.database;
    final rows = await db.query(
      'books',
      columns: ['settings_updated_at'],
      where: 'id = ?',
      whereArgs: [bookId],
      limit: 1,
    );
    return ((rows.first['settings_updated_at'] as int?) ?? 0);
  }
}
