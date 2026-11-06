import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/database/book_db.dart';
import 'package:narrchat/database/library_store.dart';
import 'package:narrchat/database/mods_store.dart';
import 'package:narrchat/database/sqflite_desktop.dart';
import 'package:narrchat/models/book_meta.dart';
import 'package:narrchat/models/branch.dart';
import 'package:narrchat/models/mod.dart';
import 'package:narrchat/models/round_generation.dart';
import 'package:narrchat/services/cloud_backup/backup_digest.dart';
import 'package:narrchat/services/cloud_backup/backup_unit.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 内容摘要：同一内容必须算同一个值，时间戳与本机状态**不得**影响摘要。
void main() {
  final tempDirs = <Directory>[];

  String newTempDir(String prefix) {
    final dir = Directory.systemTemp.createTempSync(prefix);
    tempDirs.add(dir);
    return dir.path;
  }

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    ensureDesktopSqfliteFactory();
  });

  tearDownAll(() async {
    for (final dir in tempDirs) {
      try {
        await dir.delete(recursive: true);
      } catch (_) {
        // 清理失败不影响结论。
      }
    }
    tempDirs.clear();
  });

  /// 打开一个**独立**连接来算摘要。
  ///
  /// `singleInstance` 必须关掉：sqflite 默认按路径复用 Database 实例，而这个
  /// 文件里「BookDb.create → openDb 取摘要 → BookDb.open 改数据 → openDb 再取摘要」
  /// 全在同一个路径上反复开关；复用实例时一旦某个旧 handle 还没真正关闭，
  /// 第二次读到的就不是磁盘上的最新内容（全量并行跑时曾触发过一次摘要不一致）。
  Future<Database> openDb(String path) => databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(singleInstance: false),
      );

  /// 摘要不一致时的现场：把这些表整表 dump 出来，一眼看出是哪张表/哪一列变了。
  ///
  /// 只在失败分支调用，正常路径零开销。
  Future<String> digestScene(Database db) async {
    Future<String> dump(String table, String orderBy) async {
      final rows = await db.query(table, orderBy: orderBy);
      return '$table(${rows.length})=$rows';
    }

    return [
      await dump('book_meta', ''),
      await dump('round_stack', 'uuid ASC'),
      await dump('branches', 'branch_uuid ASC'),
      await dump('world_book_entries', 'uuid ASC'),
      await dump('use_mods', 'mod_uuid ASC'),
    ].join('\n');
  }

  RoundGeneration gen(String uuid, int index, {String narrative = '', bool using = false}) {
    return RoundGeneration(
      meta: RoundMeta(
        uuid: uuid,
        roundIndex: index,
        roundSerialNum: 1,
        isUsing: using,
        operatedAt: DateTime.utc(2026, 1, 1),
      ),
      userInput: '问',
      aiNarrative: narrative,
    );
  }

  BookMeta meta(String uuid) => BookMeta(
        bookUuid: uuid,
        masterUuid: 'master',
        title: '书',
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 2),
      );

  group('book 单元', () {
    test('同内容重复计算结果一致', () async {
      final dir = newTempDir('digest_book_');
      final path = p.join(dir, 'narrbook_b1.db');
      final book = await BookDb.create(meta: meta('b1'), pathOverride: path);
      await book.rounds.insert(gen('g1', 1, using: true));
      await book.close();

      final db = await openDb(path);
      final first = await BackupDigest.ofBook(BackupUnit.book('b1'), db);
      final second = await BackupDigest.ofBook(BackupUnit.book('b1'), db);
      expect(first, second);
      expect(first.length, 64, reason: 'sha256 十六进制');
      await db.close();
    });

    test('时间戳变化不影响摘要', () async {
      final dir = newTempDir('digest_time_');
      final path = p.join(dir, 'narrbook_b1.db');
      final book = await BookDb.create(meta: meta('b1'), pathOverride: path);
      await book.rounds.insert(gen('g1', 1, using: true));
      await book.close();

      final db = await openDb(path);
      final before = await BackupDigest.ofBook(BackupUnit.book('b1'), db);
      await db.close();

      final again = await BookDb.open(bookUuid: 'b1', pathOverride: path);
      await again.meta.setUpdatedAt(DateTime.utc(2030, 1, 1));
      await again.meta.writeSettings(meta('b1').copyWith(title: '书'));
      await again.close();

      final db2 = await openDb(path);
      final after = await BackupDigest.ofBook(BackupUnit.book('b1'), db2);
      final scene = after == before ? '' : await digestScene(db2);
      await db2.close();
      expect(after, before,
          reason: '只动时间戳不该被当成内容变更。当前库内容：\n$scene');
    });

    test('branch_working 变化不影响摘要', () async {
      final dir = newTempDir('digest_branch_');
      final path = p.join(dir, 'narrbook_b1.db');
      final book = await BookDb.create(meta: meta('b1'), pathOverride: path);
      await book.branches.upsert(Branch(
        branchUuid: 'br1',
        branchName: '如果',
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
      ));
      await book.close();

      final db = await openDb(path);
      final before = await BackupDigest.ofBook(BackupUnit.book('b1'), db);
      await db.close();

      final again = await BookDb.open(bookUuid: 'b1', pathOverride: path);
      await again.branches.setWorking('br1');
      await again.close();

      final db2 = await openDb(path);
      final after = await BackupDigest.ofBook(BackupUnit.book('b1'), db2);
      await db2.close();
      expect(after, before, reason: '看哪个分支是本机状态，不是内容');
    });
  });

  test('正文变化改变摘要', () async {
    final dir = newTempDir('digest_content_');
    final path = p.join(dir, 'narrbook_b1.db');
    final book = await BookDb.create(meta: meta('b1'), pathOverride: path);
    await book.rounds.insert(gen('g1', 1, using: true, narrative: '原文'));
    await book.close();

    final db = await openDb(path);
    final before = await BackupDigest.ofBook(BackupUnit.book('b1'), db);
    await db.close();

    final again = await BookDb.open(bookUuid: 'b1', pathOverride: path);
    await again.rounds.updateContent('g1', {'ai_narrative': '改过的'});
    await again.close();

    final db2 = await openDb(path);
    final after = await BackupDigest.ofBook(BackupUnit.book('b1'), db2);
    await db2.close();
    expect(after, isNot(before));
  });

  test('切换版本（is_using）属于内容变化', () async {
    final dir = newTempDir('digest_using_');
    final path = p.join(dir, 'narrbook_b1.db');
    final book = await BookDb.create(meta: meta('b1'), pathOverride: path);
    await book.rounds.insert(gen('g1', 1, using: true));
    await book.rounds.insert(gen('g2', 1, narrative: '另一版'));
    await book.close();

    final db = await openDb(path);
    final before = await BackupDigest.ofBook(BackupUnit.book('b1'), db);
    await db.close();

    final again = await BookDb.open(bookUuid: 'b1', pathOverride: path);
    await again.rounds.setUsing('g2');
    await again.close();

    final db2 = await openDb(path);
    final after = await BackupDigest.ofBook(BackupUnit.book('b1'), db2);
    await db2.close();
    expect(after, isNot(before), reason: '看哪一代决定了后续轮次，是内容');
  });

  group('library 单元', () {
    test('改名 / 墓碑都改变摘要，且墓碑只取布尔（时间不同不影响）', () async {
      final dir = newTempDir('digest_library_');
      final path = p.join(dir, 'narrchat_library.db');
      final library = LibraryDb(pathOverride: path, masterUuidOverride: 'm');
      await library.putBook(
        const LibraryBookRow(bookUuid: 'b1', title: '甲'),
      );
      await library.close();

      final db = await openDb(path);
      final before = await BackupDigest.ofLibrary(BackupUnit.library, db);
      await db.close();

      final again = LibraryDb(pathOverride: path);
      await again.setTitle('b1', '乙');
      await again.close();

      final db2 = await openDb(path);
      final renamed = await BackupDigest.ofLibrary(BackupUnit.library, db2);
      await db2.close();
      expect(renamed, isNot(before));

      final third = LibraryDb(pathOverride: path);
      await third.setDeletedAt('b1', DateTime.utc(2026, 3, 1));
      await third.close();

      final db3 = await openDb(path);
      final tombstoned = await BackupDigest.ofLibrary(BackupUnit.library, db3);
      await db3.close();
      expect(tombstoned, isNot(renamed));

      // 墓碑换一个时间：摘要不变（删除意图相同，时间不是内容）。
      final fourth = LibraryDb(pathOverride: path);
      await fourth.setDeletedAt('b1', DateTime.utc(2027, 9, 9));
      await fourth.close();

      final db4 = await openDb(path);
      final tombstonedLater = await BackupDigest.ofLibrary(BackupUnit.library, db4);
      await db4.close();
      expect(tombstonedLater, tombstoned);
    });
  });

  group('mods 单元', () {
    test('改提示词改变摘要，改更新时间不改变', () async {
      final dir = newTempDir('digest_mods_');
      final path = p.join(dir, 'narrchat_mods.db');
      final mods = ModsDb(pathOverride: path, masterUuidOverride: 'm');
      await mods.upsert(Mod(
        uuid: 'm1',
        name: '甲',
        prePrompt: '前置',
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
      ));
      await mods.close();

      final db = await openDb(path);
      final before = await BackupDigest.ofMods(BackupUnit.mods, db);
      await db.close();

      final again = ModsDb(pathOverride: path);
      await again.upsert(Mod(
        uuid: 'm1',
        name: '甲',
        prePrompt: '前置',
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2031, 5, 5),
      ));
      await again.close();

      final db2 = await openDb(path);
      final touched = await BackupDigest.ofMods(BackupUnit.mods, db2);
      await db2.close();
      expect(touched, before, reason: '只刷更新时间不该算内容变化');

      final third = ModsDb(pathOverride: path);
      await third.upsert(Mod(
        uuid: 'm1',
        name: '甲',
        prePrompt: '改过的前置',
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
      ));
      await third.close();

      final db3 = await openDb(path);
      final changed = await BackupDigest.ofMods(BackupUnit.mods, db3);
      await db3.close();
      expect(changed, isNot(before));
    });
  });

  test('单元键参与哈希：同样的表结构不会与其它单元撞摘要', () async {
    final dir = newTempDir('digest_unit_');
    final bookPath = p.join(dir, 'narrbook_b1.db');
    final otherPath = p.join(dir, 'narrbook_b2.db');
    final book = await BookDb.create(meta: meta('b1'), pathOverride: bookPath);
    final other = await BookDb.create(meta: meta('b2'), pathOverride: otherPath);
    await book.close();
    await other.close();

    final db1 = await openDb(bookPath);
    final digest1 = await BackupDigest.ofBook(BackupUnit.book('b1'), db1);
    await db1.close();

    final db2 = await openDb(otherPath);
    final digest2 = await BackupDigest.ofBook(BackupUnit.book('b2'), db2);
    await db2.close();

    expect(digest1, isNot(digest2));
  });
}
