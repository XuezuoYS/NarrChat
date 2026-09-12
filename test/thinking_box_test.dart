import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/models/book.dart';

import 'helpers/chat_harness.dart';
import 'helpers/fakes.dart';

/// 超长思考文本：首尾带唯一标记、每行独立成行，末尾混入 Markdown 结构
/// （用于验证思考框不走 Markdown 解析），总长超过末尾窗口上限。
String longReasoning() => '开头标记第一行\n'
    '${'中间推理内容行\n' * 200}'
    '## 末尾小标题\n**末尾粗体**';

/// 思考框渲染策略：
/// - 生成中折叠态只渲染末尾窗口（否则全文排版成本随思考链长度线性上升）；
/// - 思考结束（done）后恢复全文；
/// - 展开态始终渲染全文；
/// - 一律按纯文本渲染（不做 Markdown 解析，保留模型原始分行）。
void main() {
  const book = Book(uuid: kHarnessBookUuid, title: '测试书');

  testWidgets('生成中折叠态：只渲染末尾窗口，且思考文本不走 Markdown', (tester) async {
    final ai = FakeStreamingAiService();
    final provider = await pumpChatScreen(tester, ai: ai);

    final sendFuture = provider.sendRound(userInput: '继续剧情', book: book);
    await tester.pump();
    ai.emitReasoning(longReasoning());
    await tester.pump();

    // 数据层完整：末尾窗口只影响渲染，不影响累积的思考原文。
    expect(provider.agentEvents.single.content, longReasoning());
    expect(provider.agentEvents.single.done, isFalse);

    final body = tester.widget<Text>(find.textContaining('**末尾粗体**'));
    // 窗口外的开头内容不参与渲染（这正是性能修复点）。
    expect(body.data, isNot(contains('开头标记第一行')));
    // 窗口贴住最新内容，且以完整行开头（不出现半行）。
    expect(body.data, startsWith('中间推理内容行\n'));
    expect(body.data, contains('\n'), reason: '纯文本保留模型原始换行');
    // 纯文本渲染：Markdown 标记原样保留，未被解析成标题/粗体。
    expect(body.data, contains('## 末尾小标题'));
    expect(find.text('末尾小标题'), findsNothing);
    expect(find.text('末尾粗体'), findsNothing);

    expect(await finishStream(tester, ai, provider, sendFuture), isTrue);
  });

  testWidgets('思考结束（进入正文）后：折叠框恢复全文', (tester) async {
    final ai = FakeStreamingAiService();
    final provider = await pumpChatScreen(tester, ai: ai);

    final sendFuture = provider.sendRound(userInput: '继续剧情', book: book);
    await tester.pump();
    ai.emitReasoning(longReasoning());
    await tester.pump();
    expect(
      find.textContaining('开头标记第一行'),
      findsNothing,
      reason: '生成中只渲染末尾窗口',
    );

    // 首个正文增量到达 → 当前思考块标记完成（内容不再变化）。
    ai.emit('正文开始');
    await tester.pump();

    expect(provider.agentEvents.single.done, isTrue);
    expect(
      find.textContaining('开头标记第一行'),
      findsOneWidget,
      reason: '思考结束后恢复全文，折叠框内可继续上翻阅读',
    );
    expect(find.textContaining('**末尾粗体**'), findsOneWidget);

    expect(await finishStream(tester, ai, provider, sendFuture), isTrue);
  });

  testWidgets('done 后仍续吐思考（少数线路）：锁定末尾窗口，不退回全量重排', (tester) async {
    final ai = FakeStreamingAiService();
    final provider = await pumpChatScreen(tester, ai: ai);

    final sendFuture = provider.sendRound(userInput: '继续剧情', book: book);
    await tester.pump();
    ai.emitReasoning(longReasoning());
    await tester.pump();

    // 正文开始 → 思考标记完成 → 恢复全文。
    ai.emit('正文开始');
    await tester.pump();
    expect(find.textContaining('开头标记第一行'), findsOneWidget);

    // 已完成的思考块又被追加（异常线路）：重新按「仍在生成」处理。
    ai.emitReasoning('追加的思考');
    await tester.pump();

    expect(provider.agentEvents.first.content, endsWith('追加的思考'));
    expect(
      find.textContaining('开头标记第一行'),
      findsNothing,
      reason: '内容仍在增长 → 只渲染末尾窗口，避免每增量重排全文',
    );
    expect(find.textContaining('追加的思考'), findsOneWidget);

    expect(await finishStream(tester, ai, provider, sendFuture), isTrue);
  });

  testWidgets('生成中展开：立即渲染全文（不受末尾窗口限制）', (tester) async {
    final ai = FakeStreamingAiService();
    final provider = await pumpChatScreen(tester, ai: ai);

    final sendFuture = provider.sendRound(userInput: '继续剧情', book: book);
    await tester.pump();
    ai.emitReasoning(longReasoning());
    await tester.pump();
    expect(find.textContaining('开头标记第一行'), findsNothing);

    await tester.tap(find.text('思考中'));
    await tester.pump();

    expect(find.textContaining('开头标记第一行'), findsOneWidget);
    expect(
      provider.agentEvents.single.done,
      isFalse,
      reason: '展开只是视图状态，不改变思考块完成状态',
    );

    expect(await finishStream(tester, ai, provider, sendFuture), isTrue);
  });
}
