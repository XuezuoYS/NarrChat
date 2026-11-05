import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/database/migration/migration_paths.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/mod.dart';
import 'package:narrchat/models/world_book_entry.dart';
import 'package:narrchat/services/app_repositories.dart';
import 'package:narrchat/services/app_stores.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 仓库集合 + 世界书 / Mod 仓储：验证 R3 读写与旧界面的模型能对上。
void main() {
  final tempDirs = <Directory>[];

  MigrationPaths makePaths() {
    final userData = Directory.systemTemp.createTempSync('app_repo_user_');
    final localConfig = Directory.systemTemp.createTempSync('app_repo_cfg_');
    tempDirs.addAll([userData, localConfig]);
    return MigrationPaths(
      userDataDir: userData.path,
      localConfigDir: localConfig.path,
    );
  }

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDownAll(() async {
    await AppRepositories.reset();
    for (final dir in tempDirs) {
      try {
        await dir.delete(recursive: true);
      } catch (_) {
        // 清理失败不影响结论。
      }
    }
    tempDirs.clear();
  });

  test('未初始化时访问会明确报错，而不是拿空数据', () {
    expect(AppRepositories.isInitialized, isFalse);
    expect(() => AppRepositories.instance, throwsStateError);
  });

  test('initialize 组装出四个仓库，reset 后释放', () async {
    final paths = makePaths();
    final stores = await AppStores.openAt(paths);
    final repos = await AppRepositories.initialize(stores: stores);

    expect(AppRepositories.isInitialized, isTrue);
    expect(identical(AppRepositories.instance, repos), isTrue);
    expect(await repos.books.listBooks(), isEmpty);
    expect(await repos.mod.listMods(), isEmpty);
    expect(repos.bookPool, same(stores.books));

    await AppRepositories.reset();
    expect(AppRepositories.isInitialized, isFalse);
  });

  group('世界书仓储', () {
    late AppRepositories repos;
    late String bookUuid;

    setUp(() async {
      final paths = makePaths();
      final stores = await AppStores.openAt(paths);
      repos = await AppRepositories.initialize(stores: stores);
      bookUuid = await repos.books.createBook(const Book(
        title: '书',
      ));
    });

    tearDown(() async {
      await AppRepositories.reset();
    });

    test('新增自动生成 uuid，读回带上时间戳', () async {
      final saved = await repos.worldBook.upsert(
        bookUuid,
        const WorldBookEntry(bookUuid: '', keyword: '龙, 蛇', content: '爬行类'),
      );
      expect(saved.uuid, isNotEmpty);

      final rows = await repos.worldBook.list(bookUuid);
      expect(rows.single.uuid, saved.uuid);
      expect(rows.single.keywords, ['龙', '蛇']);
      expect(rows.single.isActive, isTrue);
      expect(rows.single.updatedAt, isNotNull);
    });

    test('覆盖同 uuid 是更新而不是新增', () async {
      final saved = await repos.worldBook.upsert(
        bookUuid,
        const WorldBookEntry(bookUuid: '', keyword: '龙', content: '旧'),
      );
      await repos.worldBook.upsert(
        bookUuid,
        saved.copyWith(content: '新', isActive: false),
      );
      final rows = await repos.worldBook.list(bookUuid);
      expect(rows.single.content, '新');
      expect(rows.single.isActive, isFalse);
    });

    test('删除与整体替换', () async {
      final first = await repos.worldBook.upsert(
        bookUuid,
        const WorldBookEntry(bookUuid: '', keyword: '甲', content: '1'),
      );
      await repos.worldBook.delete(bookUuid, first.uuid);
      expect(await repos.worldBook.list(bookUuid), isEmpty);

      await repos.worldBook.replaceAll(bookUuid, const [
        WorldBookEntry(uuid: 'w1', bookUuid: '', keyword: '乙', content: '2'),
        WorldBookEntry(
          uuid: 'w2',
          bookUuid: '',
          keyword: '丙',
          content: '3',
          isActive: false,
        ),
      ]);
      final rows = await repos.worldBook.list(bookUuid);
      expect(rows.map((e) => e.uuid), ['w1', 'w2']);
      expect(rows.last.isActive, isFalse);
    });

    test('空书 uuid 直接返回空，不炸', () async {
      expect(await repos.worldBook.list(''), isEmpty);
      await repos.worldBook.delete('', 'x');
      await repos.worldBook.replaceAll('', const []);
    });
  });

  group('Mod 仓储', () {
    late AppRepositories repos;
    late String bookUuid;

    setUp(() async {
      final paths = makePaths();
      final stores = await AppStores.openAt(paths);
      repos = await AppRepositories.initialize(stores: stores);
      bookUuid = await repos.books.createBook(const Book(title: '书'));
    });

    tearDown(() async {
      await AppRepositories.reset();
    });

    test('新建 / 读取 / 软删', () async {
      final uuid = await repos.mod.createMod(const Mod(name: '甲', prePrompt: '前'));
      expect(uuid, isNotEmpty);

      final loaded = await repos.mod.getMod(uuid);
      expect(loaded!.name, '甲');
      expect(loaded.prePrompt, '前');

      await repos.mod.deleteMod(uuid);
      expect(await repos.mod.listMods(), isEmpty);
      expect((await repos.mod.listMods(includeDeleted: true)).single.uuid, uuid);
    });

    test('启用清单：顺序保留、重复去掉、空串忽略', () async {
      await repos.mod.setUseModUuids(bookUuid, ['preset::a', 'm1', 'm1', '', 'm2']);
      expect(await repos.mod.useModUuids(bookUuid), ['preset::a', 'm1', 'm2']);

      await repos.mod.setUseModUuids(bookUuid, const []);
      expect(await repos.mod.useModUuids(bookUuid), isEmpty);
    });

    test('updateMod 对空 uuid 明确报错', () async {
      await expectLater(
        repos.mod.updateMod(const Mod(name: 'x')),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
