import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/providers/round_provider.dart';

import 'helpers/chat_harness.dart';
import 'helpers/fakes.dart';

/// 气泡页眉行为：流式期间显示「第 n 轮 · 正在生成中…… + 转圈」，
/// 完成后收敛为「第 n 轮 ·」（转圈与状态文字消失）。
void main() {
  const book = Book(uuid: kHarnessBookUuid, title: '测试书');

  /// 页眉行（含文案的最近一层 Row）内应有一枚转圈。
  Finder headerSpinnerOf(String text) => find.descendant(
        of: find
            .ancestor(of: find.text(text), matching: find.byType(Row))
            .first,
        matching: find.byType(CircularProgressIndicator),
      );

  /// 发送后结束流式（期间有无限转圈动画，不能 pumpAndSettle）。
  Future<void> finishStream(
    WidgetTester tester,
    FakeStreamingAiService ai,
    RoundProvider provider,
    Future<bool> sendFuture,
  ) async {
    ai.complete();
    for (var i = 0; i < 20 && provider.isSending; i++) {
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(await sendFuture, isTrue);
  }

  testWidgets('宽屏：页眉流式显示「第 n 轮 · 正在生成中…… + 转圈」，完成后为「第 n 轮」', (tester) async {
    final ai = FakeStreamingAiService();
    final roundProvider =
        await pumpChatScreen(tester, ai: ai, size: const Size(1400, 900));
    final sendFuture = roundProvider.sendRound(userInput: '继续剧情', book: book);
    await tester.pump();

    expect(find.text('第 1 轮 · 正在生成中……'), findsOneWidget);
    expect(headerSpinnerOf('第 1 轮 · 正在生成中……'), findsOneWidget);

    await finishStream(tester, ai, roundProvider, sendFuture);

    // 完成后：状态文字与转圈消失，页眉收敛为「第 1 轮」。
    expect(find.text('第 1 轮'), findsOneWidget);
    expect(find.text('第 1 轮 · 正在生成中……'), findsNothing);
    expect(headerSpinnerOf('第 1 轮'), findsNothing);
  });

  testWidgets('窄屏：页眉流式显示「第 n 轮 · 正在生成中…… + 转圈」，完成后为「第 n 轮」', (tester) async {
    final ai = FakeStreamingAiService();
    final roundProvider =
        await pumpChatScreen(tester, ai: ai, size: const Size(400, 800));
    final sendFuture = roundProvider.sendRound(userInput: '继续剧情', book: book);
    await tester.pump();

    expect(find.text('第 1 轮 · 正在生成中……'), findsOneWidget);
    expect(headerSpinnerOf('第 1 轮 · 正在生成中……'), findsOneWidget);

    await finishStream(tester, ai, roundProvider, sendFuture);

    expect(find.text('第 1 轮'), findsOneWidget);
    expect(find.text('第 1 轮 · 正在生成中……'), findsNothing);
    expect(headerSpinnerOf('第 1 轮'), findsNothing);
  });
}
