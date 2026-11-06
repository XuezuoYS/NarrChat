import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/chat/chat_height_bucket.dart';
import 'package:narrchat/chat/chat_item.dart';

import 'helpers/fakes.dart';

/// 对话页高度缓存（C4）：写入→读回、档位隔离、覆盖、删书清理。
///
/// 为什么按档位隔离：条目高度由折行数决定，折行数同时取决于列宽与字号。
/// 只按 `(书, 条目)` 存的话，改窗口宽度或换字号之后旧高度全部失真。
void main() {
  late TestStack stack;

  setUp(() async {
    stack = await TestStack.create();
  });

  tearDown(() async {
    await stack.dispose();
  });

  test('档位换算：同档归并、跨档分开，且 1.0 字号固定在 100% 档', () {
    expect(ChatHeightBucket.widthOf(760), ChatHeightBucket.widthOf(763));
    expect(ChatHeightBucket.widthOf(760), isNot(ChatHeightBucket.widthOf(776)));
    expect(ChatHeightBucket.typeScaleOf(1.0), 20);
    expect(ChatHeightBucket.typeScaleOf(1.02), 20, reason: '2% 仍在同一档');
    expect(ChatHeightBucket.typeScaleOf(1.10), 22);
    // 异常输入不抛（首帧宽度可能是 0）。
    expect(ChatHeightBucket.widthOf(0), 0);
    expect(ChatHeightBucket.widthOf(double.nan), 0);
  });

  test('写入 → 读回一致（同档）', () async {
    const book = 'book-1';
    await stack.stores.cache.putHeights(
      book,
      {'r1:ai': 412.5, 'r1:user': 96.0},
      widthBucket: 95,
      typeScaleBucket: 20,
    );

    final loaded = await stack.stores.cache.heightsOf(
      book,
      widthBucket: 95,
      typeScaleBucket: 20,
    );
    expect(loaded, {'r1:ai': 412.5, 'r1:user': 96.0});
  });

  test('不同列宽档 / 字号档互不命中', () async {
    const book = 'book-1';
    await stack.stores.cache.putHeights(
      book,
      {'r1:ai': 400.0},
      widthBucket: 95,
      typeScaleBucket: 20,
    );

    expect(
      await stack.stores.cache.heightsOf(book,
          widthBucket: 96, typeScaleBucket: 20),
      isEmpty,
      reason: '列宽换档后不该命中',
    );
    expect(
      await stack.stores.cache.heightsOf(book,
          widthBucket: 95, typeScaleBucket: 21),
      isEmpty,
      reason: '字号换档后不该命中',
    );
  });

  test('同 key 再写覆盖旧值', () async {
    const book = 'book-1';
    await stack.stores.cache
        .putHeights(book, {'r1:ai': 300.0}, widthBucket: 95, typeScaleBucket: 20);
    await stack.stores.cache
        .putHeights(book, {'r1:ai': 520.0}, widthBucket: 95, typeScaleBucket: 20);

    final loaded = await stack.stores.cache
        .heightsOf(book, widthBucket: 95, typeScaleBucket: 20);
    expect(loaded['r1:ai'], 520.0);
    expect(loaded.length, 1, reason: '同主键只留一行');
  });

  test('删书清理：clearHeights 清掉所有档位', () async {
    const book = 'book-1';
    await stack.stores.cache
        .putHeights(book, {'r1:ai': 300.0}, widthBucket: 95, typeScaleBucket: 20);
    await stack.stores.cache
        .putHeights(book, {'r1:ai': 340.0}, widthBucket: 96, typeScaleBucket: 20);
    await stack.stores.cache
        .putHeights('book-2', {'r1:ai': 300.0}, widthBucket: 95, typeScaleBucket: 20);

    await stack.stores.cache.clearHeights(book);

    expect(
      await stack.stores.cache.heightsOf(book, widthBucket: 95, typeScaleBucket: 20),
      isEmpty,
    );
    expect(
      await stack.stores.cache.heightsOf(book, widthBucket: 96, typeScaleBucket: 20),
      isEmpty,
    );
    expect(
      await stack.stores.cache
          .heightsOf('book-2', widthBucket: 95, typeScaleBucket: 20),
      {'r1:ai': 300.0},
      reason: '别的书不受影响',
    );
  });

  test('item_key 编解码往返（持久化键 = ChatItemKey.toString）', () {
    const key = ChatItemKey('uuid-1', ChatItemKind.ai);
    expect(ChatItemKey.parse(key.toString()), key);
    expect(ChatItemKey.parse('uuid-1:notAKind'), isNull);
    expect(ChatItemKey.parse(''), isNull);
  });
}
