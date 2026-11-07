import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/providers/book_provider.dart';

import 'helpers/fakes.dart';

/// 书籍列表状态：`currentBook` 永远指向"最新实例"，不是字段快照。
///
/// 这一条在多设备场景下很关键：云备份落地后库里已经是新数据，
/// 若 provider 还抱着旧实例，对话页/设置页会一直展示陈旧设置。
void main() {
  late TestStack stack;
  late BookProvider provider;

  setUp(() async {
    stack = await TestStack.create();
    provider = BookProvider(repository: stack.repos.books);
  });

  tearDown(() async {
    await stack.dispose();
  });

  test('loadBooks 后用最新实例替换 currentBook（同 uuid）', () async {
    await stack.seedBook(uuid: 'b1', title: '旧标题');
    await provider.loadBooks();
    final stale = provider.currentBook!;
    expect(stale.title, '旧标题');

    // 模拟云备份落地：库中数据已更新，重新加载。
    await stack.repos.books.saveBook(
      stale.copyWith(title: '新标题', category: '新分类'),
    );
    await provider.loadBooks();

    expect(provider.currentBook!.title, '新标题');
    expect(provider.currentBook!.category, '新分类');
    expect(
      identical(provider.currentBook, stale),
      isFalse,
      reason: 'currentBook 应指向最新实例，而非旧的字段快照',
    );
  });

  test('selectBook 同 uuid 重复选择也刷新为最新实例', () async {
    await stack.seedBook(uuid: 'b1', title: '旧标题');
    await stack.seedBook(uuid: 'b2', title: '书B');
    await provider.loadBooks();

    final staleA = provider.books.firstWhere((b) => b.uuid == 'b1');
    provider.selectBook(provider.books.firstWhere((b) => b.uuid == 'b2'));
    expect(provider.currentBook!.uuid, 'b2');

    // 云备份落地：书 A 更新为新实例。
    await stack.repos.books.saveBook(staleA.copyWith(title: '新标题'));
    await provider.loadBooks();

    // 重新选中书 A：即使调用方传入的是陈旧快照，也解析为最新实例。
    provider.selectBook(staleA);
    expect(provider.currentBook!.uuid, 'b1');
    expect(provider.currentBook!.title, '新标题');
  });

  test('删除当前书后不再指向它（自动改选剩下的那本）', () async {
    await stack.seedBook(uuid: 'b1', title: '书A');
    await stack.seedBook(uuid: 'b2', title: '书B');
    await provider.loadBooks();
    final target = provider.books.firstWhere((b) => b.uuid == 'b1');
    provider.selectBook(target);
    expect(provider.currentBook!.uuid, 'b1');

    await provider.deleteBook(target);

    expect(provider.books.map((b) => b.uuid), ['b2']);
    expect(provider.currentBook?.uuid, isNot('b1'), reason: '被删掉的书不能继续被选中');
    expect(provider.currentBook?.uuid, 'b2', reason: '无选中时默认选第一本');
  });

  test('删除会清本机数据、保留墓碑，并通知云同步清理', () async {
    final cloud = FakeCloudSyncProvider();
    final cloudProvider = BookProvider(
      repository: stack.repos.books,
      cloudSyncProvider: cloud,
    );
    final uuid = await stack.seedBook(uuid: 'b1', title: '书A');
    await cloudProvider.loadBooks();

    await cloudProvider.deleteBook(cloudProvider.books.single);

    expect(cloud.deletedBooks, [uuid], reason: '云端清理交给 CloudSyncProvider');
    expect(await stack.stores.books.exists(uuid), isFalse);
    expect(await stack.stores.cache.indexOf(uuid), isNull);
    expect((await stack.stores.library.book(uuid))!.isDeleted, isTrue);
    expect(cloudProvider.books, isEmpty);
  });

  test('更新时间来自缓存副本，用于列表更新时间排序', () async {
    await stack.seedBook(uuid: 'b1', title: '书A');
    await stack.seedBook(uuid: 'b2', title: '书B');
    await stack.setBookUpdatedAt('b1', DateTime.utc(2026, 3, 1));
    await stack.setBookUpdatedAt('b2', DateTime.utc(2026, 4, 1));

    await provider.loadBooks();
    expect(provider.updatedTimes['b1'], DateTime.utc(2026, 3, 1));
    expect(provider.updatedTimes['b2'], DateTime.utc(2026, 4, 1));

    // 刷新入口（从对话页返回首页时调用）也要读到最新值。
    await stack.setBookUpdatedAt('b1', DateTime.utc(2026, 5, 1));
    await provider.refreshTimes();
    expect(provider.updatedTimes['b1'], DateTime.utc(2026, 5, 1));
  });

  test('新建书籍自动选中，并带上完整设置（不是空壳）', () async {
    await stack.seedBook(uuid: 'existing', title: '已有书');
    await provider.loadBooks();

    final ok = await provider.createBook(
      const Book(
        title: '新书',
        category: '武侠',
        historyRounds: 7,
        memorySummaryRounds: 5,
      ),
    );
    expect(ok, isTrue);
    expect(provider.currentBook, isNotNull);
    expect(provider.currentBook!.title, '新书');
    expect(provider.currentBook!.category, '武侠');
    expect(provider.currentBook!.historyRounds, 7);
    expect(provider.currentBook!.memorySummaryRounds, 5);
    expect(provider.books.length, 2);
  });
}
