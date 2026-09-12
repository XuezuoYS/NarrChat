import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/models/book.dart';
import 'package:narrchat/widgets/chat_bubble.dart';
import 'package:narrchat/widgets/sidebar_panel.dart';

import 'helpers/chat_harness.dart';
import 'helpers/fakes.dart';

/// 流式增量的重建范围。
///
/// 每个增量只应重建「生成中的气泡」那一小块；外壳（侧栏 / 输入面板 / 历史气泡）
/// 必须保持同一 widget 实例——外壳逐增量重建曾是移动端生成期间卡顿的主因
/// （整页重建含侧栏面板与全部可见气泡）。
///
/// 断言方式：widget 实例的同一性。父级只要重建，列表项 / 输入框就会重新构造，
/// 实例必然变化；反之未被重建者实例不变。
void main() {
  const book = Book(uuid: kHarnessBookUuid, title: '测试书');

  testWidgets('流式增量只重建生成中的气泡，外壳与历史气泡不重建', (tester) async {
    final ai = FakeStreamingAiService();
    final provider = await pumpChatScreen(tester, ai: ai, seedRounds: 3);

    final sendFuture = provider.sendRound(userInput: '继续剧情', book: book);
    await tester.pump();
    ai.emit('第一段正文');
    await tester.pump();
    expect(find.textContaining('第一段正文'), findsOneWidget, reason: '正文已上屏');

    // 记录外壳与历史条目的 widget 实例。
    final historyBubble = tester.widget<ChatBubble>(find.byType(ChatBubble).first);
    final composerField = tester.widget<TextField>(find.byType(TextField).first);
    final sidebar = tester.widget<SidebarPanel>(find.byType(SidebarPanel));

    // 下一个流式增量。
    ai.emit('第二段正文');
    await tester.pump();

    // 流式气泡仍实时更新（重建范围收敛不能牺牲实时性）。
    expect(find.textContaining('第二段正文'), findsOneWidget);

    expect(
      identical(
        tester.widget<ChatBubble>(find.byType(ChatBubble).first),
        historyBubble,
      ),
      isTrue,
      reason: '历史气泡不应随流式增量重建',
    );
    expect(
      identical(
        tester.widget<TextField>(find.byType(TextField).first),
        composerField,
      ),
      isTrue,
      reason: '输入面板不应随流式增量重建',
    );
    expect(
      identical(tester.widget<SidebarPanel>(find.byType(SidebarPanel)), sidebar),
      isTrue,
      reason: '侧栏不应随流式增量重建',
    );

    expect(await finishStream(tester, ai, provider, sendFuture), isTrue);
  });

  testWidgets('生成起止（外壳信号变化）仍会刷新外壳', (tester) async {
    final ai = FakeStreamingAiService();
    final provider = await pumpChatScreen(tester, ai: ai, seedRounds: 3);

    final sendFuture = provider.sendRound(userInput: '继续剧情', book: book);
    await tester.pump();
    ai.emit('正文内容');
    await tester.pump();
    // 生成中：输入面板的发送按钮切换为「停止生成」。
    expect(find.byTooltip('停止生成'), findsOneWidget);

    expect(await finishStream(tester, ai, provider, sendFuture), isTrue);
    // 生成结束：外壳随低频信号刷新，按钮回到「发送」。
    expect(find.byTooltip('发送'), findsOneWidget);
    expect(find.byTooltip('停止生成'), findsNothing);
  });
}
