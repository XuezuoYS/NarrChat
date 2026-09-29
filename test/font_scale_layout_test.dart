import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/models/book.dart';

import 'helpers/chat_harness.dart';

/// 全局字体缩放最大档（+45%）下的重点屏布局冒烟：
/// 首页（书籍列表）与对话页在窄屏/宽屏下都不得出现溢出等布局异常。
///
/// 缩放实现见 `main.dart` 的 `MediaQuery.withClampedTextScaling`，
/// 测试经 harness 的 `textScale` 参数等价注入。
void main() {
  const maxScale = 1.45;
  const book = Book(uuid: kHarnessBookUuid, title: '测试书');

  testWidgets('首页 +45%：窄屏（400x800）无布局异常', (tester) async {
    await pumpHomeScreen(
      tester,
      books: const [book],
      size: const Size(400, 800),
      textScale: maxScale,
    );
    expect(find.text('测试书'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('首页 +45%：宽屏（1400x900）无布局异常', (tester) async {
    await pumpHomeScreen(
      tester,
      books: const [book],
      size: const Size(1400, 900),
      textScale: maxScale,
    );
    expect(find.text('测试书'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('对话页 +45%：宽屏（1400x900）无布局异常', (tester) async {
    await pumpChatScreen(
      tester,
      seedRounds: 2,
      seedBodyRepeats: 3,
      size: const Size(1400, 900),
      textScale: maxScale,
    );
    expect(find.text('测试书'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('对话页 +45%：窄屏（400x800）无布局异常', (tester) async {
    await pumpChatScreen(
      tester,
      seedRounds: 2,
      seedBodyRepeats: 3,
      size: const Size(400, 800),
      textScale: maxScale,
    );
    expect(find.text('测试书'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
