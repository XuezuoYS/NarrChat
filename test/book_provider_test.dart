import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/providers/book_provider.dart';

import 'helpers/fakes.dart';

void main() {
  group('BookProvider：currentBook 始终指向最新实例', () {
    test('loadBooks 后用最新实例替换 currentBook（同 uuid）', () async {
      final dao = FakeBookDao(books: [const Book(uuid: 'b1', title: '旧标题')]);
      final provider = BookProvider(dao: dao);
      await provider.loadBooks();
      final stale = provider.currentBook!;
      expect(stale.title, '旧标题');

      // 模拟云同步落地：库中数据已更新（新实例），重新加载。
      dao.books[0] = stale.copyWith(title: '新标题', category: '新分类');
      await provider.loadBooks();

      expect(provider.currentBook!.title, '新标题');
      expect(identical(provider.currentBook, stale), isFalse,
          reason: 'currentBook 应指向最新实例，而非旧的字段快照');
    });

    test('selectBook 同 uuid 重复选择也刷新为最新实例', () async {
      final dao = FakeBookDao(books: [
        const Book(uuid: 'b1', title: '旧标题'),
        const Book(uuid: 'b2', title: '书B'),
      ]);
      final provider = BookProvider(dao: dao);
      await provider.loadBooks();
      final staleA = provider.books.firstWhere((b) => b.uuid == 'b1');
      // 当前选中书 B。
      provider.selectBook(provider.books.firstWhere((b) => b.uuid == 'b2'));
      expect(provider.currentBook!.uuid, 'b2');

      // 云同步落地：书 A 更新为新实例。
      dao.books[0] = staleA.copyWith(title: '新标题');
      await provider.loadBooks();

      // 重新选中书 A：即使调用方传入的是陈旧快照，也解析为最新实例。
      provider.selectBook(staleA);
      expect(provider.currentBook!.uuid, 'b1');
      expect(provider.currentBook!.title, '新标题');
    });
  });
}
