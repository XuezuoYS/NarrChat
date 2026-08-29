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
///
/// `books` / `mods` 的主键就是 uuid（无第二个 int id），因此 DAO 的定位、
/// 返回值与断言一律围绕 uuid；子表 `book_mods` 的引用两端也都是 uuid。
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

  test('insertBook 自动生成 uuid；updateBook 按 uuid 定位且不改写身份', () async {
    final dao = BookDao();
    final uuid = await dao.insertBook(const Book(title: '书A'));
    expect(uuid, isNotEmpty, reason: 'insertBook 返回的就是新书主键 uuid');
    final created = await dao.getBookByUuid(uuid);
    expect(created!.uuid, uuid);

    // UI 直接构造带 uuid 的 Book 更新 → 写集合不含 uuid，身份原样保留。
    await dao.updateBook(Book(uuid: uuid, title: '书A', category: '玄幻'));
    final updated = await dao.getBookByUuid(uuid);
    expect(updated!.uuid, uuid, reason: 'uuid 为唯一身份（主键），不可被覆盖');
    expect(updated.category, '玄幻');

    // 换一个 uuid 更新：命中 0 行，既不改身份也不会「迁移」出新书（旧 int id
    // 主键下的身份迁移路径已随 uuid 唯一化一并移除）。
    final affected =
        await dao.updateBook(const Book(uuid: 'u-migrated', title: '书A'));
    expect(affected, 0, reason: 'updateBook 按 uuid 匹配行，未命中不写任何列');
    expect(await dao.getBookByUuid('u-migrated'), isNull);
    expect((await dao.getAllBooks()).map((b) => b.uuid), [uuid]);
  });

  test('getAllBooks 按 uuid 升序返回（不存在行 id 顺序）', () async {
    final dao = BookDao();
    await dao.insertBook(const Book(uuid: 'u-c', title: '书C'));
    await dao.insertBook(const Book(uuid: 'u-a', title: '书A'));
    await dao.insertBook(const Book(uuid: 'u-b', title: '书B'));
    expect(
      (await dao.getAllBooks()).map((b) => b.uuid),
      ['u-a', 'u-b', 'u-c'],
      reason: '列表顺序由主键 uuid 决定，与插入先后无关',
    );
  });

  test('insertMod 生成 uuid；updateMod 不覆盖；deleteMod 软删并清理引用', () async {
    final bookDao = BookDao();
    final bookUuid = await bookDao.insertBook(const Book(title: '书X'));
    final modDao = ModDao();
    final modUuid = await modDao.insertMod(const Mod(name: '风格'));
    final created = (await modDao.getAllMods()).single;
    final originalUuid = created.uuid;
    expect(originalUuid, modUuid, reason: 'insertMod 返回值即 mods 主键');

    // 书籍挂载该 Mod（引用两端均为 uuid）。
    await modDao.replaceBookMods(bookUuid, [
      BookModConfig(bookUuid: bookUuid, modUuid: modUuid, sortOrder: 0),
    ]);
    expect(
      (await modDao.getBookMods(bookUuid)).single.modUuid,
      modUuid,
      reason: 'book_mods 以 mod_uuid 引用父表主键',
    );

    // 更新不覆盖 uuid（Mod 编辑对话框走 copyWith 保留，双保险）。
    await modDao.updateMod(Mod(uuid: modUuid, name: '风格2'));
    final updated = (await modDao.getAllMods()).single;
    expect(updated.uuid, originalUuid, reason: 'uuid 不可被更新覆盖');
    expect(updated.name, '风格2');

    // 软删：getAllMods 不再返回、book_mods 引用被清理、书籍写时间戳刷新。
    final before = await GetBookTimes.read(bookUuid);
    await modDao.deleteMod(modUuid);
    expect(await modDao.getAllMods(), isEmpty);
    expect(await modDao.getModByUuid(modUuid), isNull);
    expect(await modDao.getBookMods(bookUuid), isEmpty);
    final after = await GetBookTimes.read(bookUuid);
    expect(after, greaterThan(before), reason: '软删引用应刷新书籍设置时间戳');
  });

  test('replaceBookMods 语义一致时跳过写入（保存幂等，不产生假变更）', () async {
    final bookDao = BookDao();
    final bookUuid = await bookDao.insertBook(const Book(title: '书Y'));
    final modDao = ModDao();
    final modUuid1 = await modDao.insertMod(const Mod(name: 'm1'));
    final modUuid2 = await modDao.insertMod(const Mod(name: 'm2'));

    final configs = [
      BookModConfig(
          bookUuid: bookUuid, modUuid: modUuid1, sortOrder: 0, isEnabled: true),
      BookModConfig(
          bookUuid: bookUuid, modUuid: modUuid2, sortOrder: 1, isEnabled: false),
    ];
    await modDao.replaceBookMods(bookUuid, configs);
    final before = await GetBookTimes.read(bookUuid);

    // 相同内容再保存（新 BookModConfig 实例、无 id）→ 跳过写入。
    final same = [
      BookModConfig(
          bookUuid: bookUuid, modUuid: modUuid1, sortOrder: 0, isEnabled: true),
      BookModConfig(
          bookUuid: bookUuid, modUuid: modUuid2, sortOrder: 1, isEnabled: false),
    ];
    await modDao.replaceBookMods(bookUuid, same);
    expect(await GetBookTimes.read(bookUuid), before, reason: '无变更保存不应触写');

    // 语义变化 → 落库。
    final changed = [
      BookModConfig(
          bookUuid: bookUuid, modUuid: modUuid1, sortOrder: 0, isEnabled: true),
      BookModConfig(
          bookUuid: bookUuid, modUuid: modUuid2, sortOrder: 1, isEnabled: true),
    ];
    await modDao.replaceBookMods(bookUuid, changed);
    expect(await GetBookTimes.read(bookUuid), greaterThan(before));
  });

  test('BookModConfig 落库归一化：预置行 mod_uuid 写 NULL，空串不触发外键', () async {
    final bookDao = BookDao();
    final bookUuid = await bookDao.insertBook(const Book(title: '书Z'));
    final modDao = ModDao();

    // 预置 Mod 的 uuid 为空串（Mod.uuid 对预置恒为 ''）；toMap 应把空串归一化
    // 为 NULL，否则 book_mods 的 mod_uuid 外键（FK → mods.uuid）匹配失败。
    await modDao.replaceBookMods(bookUuid, [
      BookModConfig(
        bookUuid: bookUuid,
        presetKey: 'web_novel_style',
        modUuid: '',
        sortOrder: 0,
        isEnabled: true,
      ),
      BookModConfig(
        bookUuid: bookUuid,
        presetKey: 'health_child',
        modUuid: '',
        sortOrder: 1,
        isEnabled: false,
      ),
    ]);

    final rows = await modDao.getBookMods(bookUuid);
    expect(rows, hasLength(2));
    expect(rows[0].presetKey, 'web_novel_style');
    expect(rows[0].modUuid, isNull, reason: '预置行 mod_uuid 必须为 NULL');
    expect(rows[1].presetKey, 'health_child');
    expect(rows[1].modUuid, isNull);
    expect(rows[1].isEnabled, isFalse);
  });
}

/// 读取书籍设置时间戳（断言 `touchBook` 行为，按主键 uuid 定位）。
class GetBookTimes {
  static Future<int> read(String bookUuid) async {
    final db = await DatabaseHelper.instance.database;
    final rows = await db.query(
      'books',
      columns: ['settings_updated_at'],
      where: 'uuid = ?',
      whereArgs: [bookUuid],
      limit: 1,
    );
    return ((rows.first['settings_updated_at'] as int?) ?? 0);
  }
}
