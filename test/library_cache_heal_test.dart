import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'helpers/fakes.dart';

/// `library_cache.book_index` 自愈回归（P0）。
///
/// 缓存是**纯副本**：它丢了（导入备份后、缓存库被误删、换机器）绝不该让
/// 用户看到"书全没了"。列表读路径因此会在「目录里有、缓存里没有」时
/// 按目录库逐本补齐索引。
void main() {
  late TestStack stack;

  setUp(() async {
    stack = await TestStack.create(prefix: 'cache_heal_');
  });

  tearDown(() async {
    await stack.dispose();
  });

  test('清空 book_index 后 listBooks 仍列出全部书，lastRoundTimes 也正常', () async {
    final first = await stack.seedBook(title: '书甲', category: '武侠');
    final second = await stack.seedBook(title: '书乙');
    await stack.seedRound(
      first,
      roundIndex: 1,
      aiNarrative: '甲的正文',
      operatedAt: DateTime.utc(2026, 3, 4),
    );
    await stack.seedRound(
      second,
      roundIndex: 1,
      aiNarrative: '乙的正文',
      operatedAt: DateTime.utc(2026, 5, 6),
    );

    // 模拟缓存库被删 / 换机：副本清空
    await stack.stores.cache.replaceAllIndex(const []);
    expect(
      await stack.stores.cache.allIndex(includeDeleted: true),
      isEmpty,
      reason: '前置条件：缓存确实是空的',
    );

    final books = await stack.repos.books.listBooks();
    expect(books.map((book) => book.uuid).toSet(), {first, second});
    expect(
      books.firstWhere((book) => book.uuid == first).title,
      '书甲',
      reason: '标题从书库 book_meta 读回来',
    );
    expect(books.firstWhere((book) => book.uuid == first).category, '武侠');

    final times = await stack.repos.books.lastRoundTimes();
    expect(times[first], DateTime.utc(2026, 3, 4));
    expect(times[second], DateTime.utc(2026, 5, 6));

    // 自愈结果已写回缓存：下一次读不用再重建。
    expect(
      (await stack.stores.cache.allIndex(includeDeleted: true)).length,
      2,
    );
  });

  test('墓碑书也能从目录重建，且不会被复活', () async {
    final kept = await stack.seedBook(title: '留下的');
    final removed = await stack.seedBook(title: '删掉的');
    await stack.repos.books.softDeleteBook(removed);

    await stack.stores.cache.replaceAllIndex(const []);
    expect(
      (await stack.repos.books.listBooks()).map((book) => book.uuid).toSet(),
      {kept},
    );
    final all = await stack.repos.books.listBooks(includeDeleted: true);
    expect(all.map((book) => book.uuid).toSet(), {kept, removed});
    expect(
      all.firstWhere((book) => book.uuid == removed).title,
      '删掉的',
    );
  });

  test('正常情况不自愈、不开库：只多一次目录查询', () async {
    await stack.seedBook(title: '书甲');
    await stack.seedBook(title: '书乙');
    expect(stack.stores.books.openCount, 0);

    final books = await stack.repos.books.listBooks();
    expect(books.length, 2);
    expect(
      stack.stores.books.openCount,
      0,
      reason: '缓存与目录一致时不该打开任何书库',
    );
  });

  test('单本书库损坏：列表不空，用目录书名兜底', () async {
    final good = await stack.seedBook(title: '好书');
    final broken = await stack.seedBook(title: '坏书');

    // 清缓存 + 把这本书的文件写成非 sqlite 内容（打开必然失败）
    await stack.stores.cache.replaceAllIndex(const []);
    final brokenPath = p.join(
      stack.paths.booksDir,
      'narrbook_$broken.db',
    );
    await stack.stores.books.close(broken);
    await File(brokenPath).writeAsBytes(const [0, 1, 2, 3, 4, 5, 6, 7]);

    final books = await stack.repos.books.listBooks();
    expect(
      books.map((book) => book.uuid).toSet(),
      {good, broken},
      reason: '单本损坏不能让整页空掉',
    );
    expect(
      books.firstWhere((book) => book.uuid == broken).title,
      '坏书',
      reason: '读不出 book_meta 时用目录里的书名兜底',
    );
  });

  test('书库文件缺失：不造幻影书', () async {
    final existing = await stack.seedBook(title: '在的');
    final vanished = await stack.seedBook(title: '文件没了');

    await stack.stores.cache.replaceAllIndex(const []);
    await stack.stores.books.deleteFile(vanished);

    final books = await stack.repos.books.listBooks();
    expect(books.map((book) => book.uuid).toSet(), {existing});
    final all = await stack.repos.books.listBooks(includeDeleted: true);
    expect(all.map((book) => book.uuid).toSet(), {existing});
  });
}
