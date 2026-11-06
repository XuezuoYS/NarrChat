import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/database/db_schema.dart';
import 'package:narrchat/services/debug_database_service.dart';
import 'package:path/path.dart' as p;

import 'helpers/fakes.dart';

/// 调试页的库浏览器：R3 是多库，先列库、再列表、再翻页读表。
///
/// 与 R2 的差别：不再有单一 `narrchat.db`，也没有 `readVersion()` 这种
/// "一个库一个版本"的接口——版本按库逐个读。
void main() {
  late TestStack stack;
  late SqliteDebugDatabaseService service;

  setUp(() async {
    stack = await TestStack.create();
    service = SqliteDebugDatabaseService(stores: stack.stores);
  });

  tearDown(() async {
    await stack.dispose();
  });

  test('listDatabases：目录库 / Mod 库 / 每本书 / 两个本地库都登记', () async {
    final bookUuid = await stack.seedBook(title: '书A');
    await stack.seedRound(bookUuid, roundIndex: 1, aiNarrative: '正文');

    final databases = await service.listDatabases();
    final ids = databases.map((d) => d.id).toList();

    expect(
      ids,
      containsAll(['library', 'mods', 'cache', 'sync', 'book:$bookUuid']),
    );

    final library = databases.firstWhere((d) => d.id == 'library');
    expect(library.exists, isTrue);
    expect(library.sizeBytes, greaterThan(0));
    expect(library.expectedVersion, userDataDbVersion);
    expect(library.actualVersion, userDataDbVersion);

    final book = databases.firstWhere((d) => d.id == 'book:$bookUuid');
    expect(book.label, isNotEmpty);
    expect(book.exists, isTrue);
  });

  test('listDatabases：书被物理删除后不再出现在列表里', () async {
    final bookUuid = await stack.seedBook(title: '书A');
    expect(
      (await service.listDatabases()).map((d) => d.id),
      contains('book:$bookUuid'),
    );

    await stack.repos.books.purgeBook(bookUuid);
    expect(
      (await service.listDatabases()).map((d) => d.id),
      isNot(contains('book:$bookUuid')),
    );
  });

  test('listTables：返回目录库的业务表与行数（排除 sqlite_*）', () async {
    await stack.seedBook();
    await stack.seedBook();

    final tables = await service.listTables(stack.paths.libraryDbPath);
    final names = tables.map((t) => t.name).toList();

    expect(names, containsAll(['meta', 'books']));
    expect(names.any((n) => n.startsWith('sqlite_')), isFalse);
    expect(tables.firstWhere((t) => t.name == 'books').rowCount, 2);
    expect(tables.firstWhere((t) => t.name == 'meta').rowCount, 1);
  });

  test('listTables：书库里能看到轮次/分支/世界书/启用 Mod 四张业务表', () async {
    final bookUuid = await stack.seedBook();
    await stack.seedRound(bookUuid, roundIndex: 1, aiNarrative: '正文');

    final names = (await service.listTables(stack.paths.bookDbPath(bookUuid)))
        .map((t) => t.name)
        .toList();
    expect(
      names,
      containsAll([
        'book_meta',
        'round_stack',
        'branches',
        'world_book_entries',
        'use_mods',
      ]),
    );
  });

  test('loadTable：列结构 / 主键 / 行内容 / 总行数', () async {
    final bookUuid = await stack.seedBook(title: '书A');
    await stack.seedRound(
      bookUuid,
      roundIndex: 1,
      userInput: '你好',
      aiNarrative: '正文',
    );

    final page = await service.loadTable(
      stack.paths.bookDbPath(bookUuid),
      'round_stack',
    );
    final columns = page.columns.map((c) => c.name).toList();

    expect(
      columns,
      containsAll(['uuid', 'father_uuid', 'user_input', 'ai_narrative']),
    );
    expect(
      page.columns.firstWhere((c) => c.name == 'uuid').isPrimaryKey,
      isTrue,
    );
    expect(
      page.columns.firstWhere((c) => c.name == 'round_index').notNull,
      isTrue,
    );
    expect(page.rows.single['user_input'], '你好');
    expect(page.rows.single['ai_narrative'], '正文');
    expect(page.totalCount, 1);
    expect(page.page, 0);
    expect(page.pageSize, 20);
  });

  test('loadTable：分页返回，越界页返回空行但总行数不变', () async {
    for (var i = 1; i <= 5; i++) {
      await stack.seedBook(title: '书$i');
    }

    final first = await service.loadTable(
      stack.paths.libraryDbPath,
      'books',
      pageSize: 2,
    );
    expect(first.rows.length, 2);
    expect(first.totalCount, 5);

    final second = await service.loadTable(
      stack.paths.libraryDbPath,
      'books',
      page: 1,
      pageSize: 2,
    );
    expect(second.rows.length, 2);
    expect(second.page, 1);
    expect(
      second.rows.map((r) => r['book_uuid']),
      isNot(equals(first.rows.map((r) => r['book_uuid']))),
    );

    final beyond = await service.loadTable(
      stack.paths.libraryDbPath,
      'books',
      page: 9,
      pageSize: 2,
    );
    expect(beyond.rows, isEmpty);
    expect(beyond.totalCount, 5);
  });

  test('索引信息：目录库的墓碑索引能被读出来', () async {
    await stack.seedBook();
    final page = await service.loadTable(stack.paths.libraryDbPath, 'books');
    expect(page.indexes.map((i) => i.name), contains('ix_books_deleted'));
  });

  test('readBookTitles：读 book_meta 书名，坏文件返回 null', () async {
    final bookUuid = await stack.seedBook(title: '书A');
    final goodPath = stack.paths.bookDbPath(bookUuid);
    final badPath = p.join(stack.paths.booksDir, 'narrbook_bad.db');
    await File(badPath).writeAsString('这不是一个 sqlite 库');

    final titles = await service.readBookTitles([goodPath, badPath]);

    expect(titles[goodPath], '书A');
    expect(titles[badPath], isNull);
  });

  test('库文件不存在时明确报错，而不是返回空结构', () async {
    final missing = p.join(stack.paths.booksDir, 'narrbook_not-exist.db');
    expect(File(missing).existsSync(), isFalse);
    await expectLater(service.listTables(missing), throwsA(anything));
  });
}
