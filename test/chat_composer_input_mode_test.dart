import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/config/ai_platforms.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/widgets/composer_input_mode.dart';
import 'package:narrchat/widgets/raw_dialog.dart';

import 'helpers/chat_harness.dart';
import 'helpers/fakes.dart';
import 'helpers/raw_dialog_harness.dart';

/// 输入卡「临时用途」（灰条）的形态与既有「修改并重新提问」的接入测试。
///
/// 形态来源：DeepSeek APP 的「修改输入」灰条（左文案 + 右删除键），正文区
/// 仍复用主输入框；本文件只覆盖「用途」自身的生命周期（亮起 / 载入 /
/// 提交 / 取消 / 退出）与已接入的两条入口（用户气泡、失败条目）。
void main() {
  const book = Book(uuid: kHarnessBookUuid, title: '测试书');

  /// 主输入框（按占位文案定位，与 chat_composer_test 一致）。
  Finder composerField() => find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.hintText == '输入你的行动或对话…',
  );

  Finder modeBar() => find.byKey(ComposerInputModeBar.barKey);
  Finder cancelKey() => find.byKey(ComposerInputModeBar.cancelKey);
  Finder sendButton() => find.ancestor(
    of: find.byIcon(Icons.arrow_upward),
    matching: find.byType(IconButton),
  );

  String fieldText(WidgetTester tester) =>
      tester.widget<TextField>(composerField()).controller!.text;

  /// 用户气泡右键 / 长按菜单 → 「修改并重新提问」。
  Future<void> tapEditAndReAsk(WidgetTester tester, String bubbleText) async {
    await tester.longPress(find.text(bubbleText));
    await tester.pumpAndSettle();
    await tester.tap(find.text('修改并重新提问'));
    await tester.pumpAndSettle();
  }

  /// 预置一轮带图片的用户消息（识图门控用例复用）。
  ///
  /// 真库 I/O 必须包 `tester.runAsync`（fake-async 区域里不会自己转起来）。
  Future<TestStack> seedRoundWithImages(
    WidgetTester tester,
    List<String> images, {
    String input = '第 1 轮的用户输入',
  }) async {
    final stack = (await tester.runAsync(TestStack.create))!;
    addTearDown(() => tester.runAsync(stack.dispose));
    await tester.runAsync(() async {
      await stack.seedBook(uuid: kHarnessBookUuid, title: '测试书');
      await stack.seedRound(
        kHarnessBookUuid,
        roundIndex: 1,
        userInput: input,
        aiNarrative: '第 1 轮的剧情正文。',
        userImages: images,
      );
    });
    return stack;
  }

  testWidgets('未进入用途：输入卡不要灰条', (tester) async {
    await pumpChatScreen(tester, seedRounds: 1);

    expect(modeBar(), findsNothing);
  });

  testWidgets('用户气泡「修改并重新提问」：灰条亮起并载入该轮输入', (tester) async {
    await pumpChatScreen(tester, seedRounds: 1);

    await tapEditAndReAsk(tester, '第 1 轮的用户输入');

    expect(modeBar(), findsOneWidget);
    // 灰条文案带轮号（形态可后续复用到其它轮次用途）。
    expect(find.text('修改并重新提问（第 1 轮）'), findsOneWidget);
    expect(fieldText(tester), '第 1 轮的用户输入');
    expect(cancelKey(), findsOneWidget);
  });

  testWidgets('灰条铺满输入卡顶部：在输入框之上、与输入框同宽', (tester) async {
    await pumpChatScreen(tester, seedRounds: 1);

    await tapEditAndReAsk(tester, '第 1 轮的用户输入');

    final bar = tester.getRect(modeBar());
    final field = tester.getRect(composerField());
    expect(bar.left, closeTo(field.left, 0.01));
    expect(bar.width, closeTo(field.width, 0.01));
    expect(bar.bottom, lessThanOrEqualTo(field.top));
  });

  testWidgets('提交修改：直接上屏（无二次确认），删除本轮及后续轮次并以新输入重新生成', (tester) async {
    // 正文短：两轮同时可见，可直接对第 1 轮气泡操作（列表打开时已滚到底部）。
    final rp = await pumpChatScreen(tester, seedRounds: 2, seedBodyRepeats: 1);

    await tapEditAndReAsk(tester, '第 1 轮的用户输入');
    await tester.enterText(composerField(), '改后的输入');
    await tester.pump();
    await tester.tap(sendButton());
    await tester.pump();

    // 灰条用途直接上屏：不弹确认框（旧行为的对话框文案永不出现）。
    expect(find.textContaining('将删除本轮及之后的所有轮次'), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);

    await waitSendDone(tester, rp);

    // 第 1 轮被替换为新输入、第 2 轮被删除；轮次清空后第零轮按既有规则重建。
    // R3 没有第零轮：修改并重新提问在第 1 轮组内新增一代，旧代仍在。
    expect(rp.rounds.map((r) => r.roundIndex).toList(), [1]);
    expect(rp.versionInfoFor(1)!.aliveCount, greaterThan(1));
    expect(rp.rounds.last.userInput, '改后的输入');
    expect(rp.rounds.last.aiNarrative, contains('成功正文'));
    // 用途已被消费：灰条收起、输入框清空。
    expect(modeBar(), findsNothing);
    expect(fieldText(tester), '');
  });

  testWidgets('提交灰条用途：气泡上屏的同一帧就清空输入并收起灰条（与普通发送同一口径）', (tester) async {
    // 流式替身：请求挂在流上不结束，才能断言「生成进行中」这一刻的界面状态。
    final ai = FakeStreamingAiService();
    final rp = await pumpChatScreen(
      tester,
      ai: ai,
      seedRounds: 2,
      seedBodyRepeats: 1,
    );

    await tapEditAndReAsk(tester, '第 1 轮的用户输入');
    await tester.enterText(composerField(), '改后的输入');
    await tester.pump();

    await tester.tap(sendButton());
    await tester.pump();

    // 此刻生成还在进行（气泡已上屏）：输入框与灰条就该是空的——旧行为要等生成
    // 收尾才清，生成期间输入框一直挂着已提交的内容（与普通发送口径不一致）。
    expect(rp.isSending, isTrue, reason: '前提：生成尚未收尾');
    expect(modeBar(), findsNothing);
    expect(fieldText(tester), '');

    ai.complete();
    await waitSendDone(tester, rp);

    // 早清空只是界面口径：提交内容照样落到第 1 轮。
    expect(rp.rounds.last.roundIndex, 1);
    expect(rp.rounds.last.userInput, '改后的输入');
  });

  testWidgets('灰条右侧删除键：退出用途并清空输入与待发送图片', (tester) async {
    final stack = await seedRoundWithImages(tester, ['img/aaa.png']);
    await pumpChatScreen(tester, stack: stack);

    await tapEditAndReAsk(tester, '第 1 轮的用户输入');
    // 识图模型：该轮图片随文本一并载入待发送条。
    expect(find.byKey(const Key('composer_image_strip')), findsOneWidget);
    expect(fieldText(tester), '第 1 轮的用户输入');

    await tester.tap(cancelKey());
    await tester.pumpAndSettle();

    expect(modeBar(), findsNothing);
    expect(fieldText(tester), '');
    expect(find.byKey(const Key('composer_image_strip')), findsNothing);
  });

  testWidgets('非识图模型：进入用途只载入文本、不携带图片', (tester) async {
    final settings = ChatCompatibleSettings();
    settings.setSelectedModel(AiPlatforms.defaultPlatformId, 'deepseek-v4-pro');
    final stack = await seedRoundWithImages(tester, ['img/aaa.png']);
    await pumpChatScreen(tester, stack: stack, settings: settings);

    await tapEditAndReAsk(tester, '第 1 轮的用户输入');

    expect(fieldText(tester), '第 1 轮的用户输入');
    expect(find.byKey(const Key('composer_image_strip')), findsNothing);
  });

  testWidgets('失败条目「修改并重新提问」：灰条载入失败输入，提交后清空失败条目', (tester) async {
    final ai = ToggleAiService()..fail = true;
    final rp = await pumpChatScreen(tester, ai: ai);

    // 先制造失败代（R3：失败就是链上一条 message_status='error' 的真轮次）。
    await rp.sendRound(userInput: '失败的输入', book: book);
    await settle(tester);
    expect(rp.rounds.single.isError, isTrue);

    // R3 没有独立的失败气泡：「修改并重新提问」走用户气泡的右键菜单（与其他轮次同一入口）。
    await tester.longPress(find.text('失败的输入'));
    await settle(tester);
    await tester.tap(
      find.descendant(
        of: find.byWidgetPredicate(
          (w) => w is PopupMenuItem<String> && w.value == 'editReask',
        ),
        matching: find.text('修改并重新提问'),
      ),
    );
    await settle(tester);

    // 失败条目「本该产生」第 1 轮：灰条文案取该轮号。
    expect(find.text('修改并重新提问（第 1 轮）'), findsOneWidget);
    expect(fieldText(tester), '失败的输入');

    ai.fail = false;
    await tester.enterText(composerField(), '改后的失败输入');
    await tester.pump();
    await tester.tap(sendButton());
    await tester.pump();
    await waitSendDone(tester, rp);

    expect(rp.rounds.last.isError, isFalse);
    // R3 没有第零轮；「修改并重新提问」是在第 1 轮的组里新增一代（旧代留着可切回）。
    expect(rp.rounds, hasLength(1));
    expect(rp.versionInfoFor(1)!.aliveCount, 2, reason: '失败代 + 新代同组');
    expect(rp.rounds.last.userInput, '改后的失败输入');
    expect(rp.rounds.last.aiNarrative, contains('成功正文'));
    expect(modeBar(), findsNothing);
  });

  testWidgets('用途下空白输入：发送键置灰，不触发提交', (tester) async {
    final rp = await pumpChatScreen(tester, seedRounds: 1);

    await tapEditAndReAsk(tester, '第 1 轮的用户输入');
    await tester.enterText(composerField(), '   ');
    await tester.pump();

    expect(tester.widget<IconButton>(sendButton()).onPressed, isNull);

    await tester.tap(sendButton(), warnIfMissed: false);
    await tester.pumpAndSettle();

    // 未提交：不发请求（也不会有任何确认框）、轮次不变、用途保留。
    expect(find.byType(AlertDialog), findsNothing);
    expect(rp.rounds.single.userInput, '第 1 轮的用户输入');
    expect(modeBar(), findsOneWidget);
  });

  testWidgets('灰条以外的破坏性入口（重新生成）依旧二次确认：取消即不生成', (tester) async {
    final rp = await pumpChatScreen(tester, seedRounds: 1, seedBodyRepeats: 1);

    // 底部「重新生成」不经输入框：保留二次确认（与灰条用途的区别就在这）。
    await tester.tap(find.text('重新生成'));
    await tester.pumpAndSettle();

    final dialog = find.byType(AlertDialog);
    expect(dialog, findsOneWidget);
    expect(
      find.descendant(of: dialog, matching: find.text('重新生成')),
      findsOneWidget,
      reason: '确认框与入口同名（全栈统一为一个入口名）',
    );
    expect(find.textContaining('将重新生成第 1 轮'), findsOneWidget);
    expect(
      find.textContaining('将删除本轮'),
      findsNothing,
      reason: '旧版本与后续轮次都保留在版本树，不再喊会丢内容',
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(rp.isSending, isFalse);
    expect(rp.rounds.last.userInput, '第 1 轮的用户输入');
    expect(rp.rounds.last.aiNarrative, contains('第 1 轮的剧情正文'));
  });

  testWidgets('退出用途后回到普通发送：新输入作为新一轮追加', (tester) async {
    final rp = await pumpChatScreen(tester, seedRounds: 1);

    await tapEditAndReAsk(tester, '第 1 轮的用户输入');
    await tester.tap(cancelKey());
    await tester.pumpAndSettle();

    await tester.enterText(composerField(), '继续推进剧情');
    await tester.pump();
    await tester.tap(sendButton());
    await tester.pump();
    await waitSendDone(tester, rp);

    expect(rp.rounds.length, 2);
    expect(rp.rounds.last.roundIndex, 2);
    expect(rp.rounds.last.userInput, '继续推进剧情');
    expect(modeBar(), findsNothing);
  });

  // ---------------------------------------------------------------------------
  // 「预览请求体」必须反映当前灰条用途（重构验收：预览不再按普通新一轮拼）
  // ---------------------------------------------------------------------------

  Finder previewButton() => find.byTooltip('预览请求体');

  /// 预览对话框里的请求体文本（块默认折叠 → 先点标题展开；只取对话框内的 RAW
  /// 内容块，避免命中底层对话气泡里的选中区域）。
  Future<String> previewBodyText(WidgetTester tester) async {
    final dialog = find.byType(RawDialog);
    await tester.tap(
      find.descendant(of: dialog, matching: find.text('【请求体 1】')),
    );
    await tester.pumpAndSettle();
    return rawBlockText(dialog, tester);
  }

  Future<void> closeDialog(WidgetTester tester) async {
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
  }

  testWidgets('灰条「修改并重新提问」：预览给出截断后的新一轮请求，且不消费用途', (tester) async {
    final rp = await pumpChatScreen(tester, seedRounds: 2, seedBodyRepeats: 1);

    await tapEditAndReAsk(tester, '第 1 轮的用户输入');
    await tester.enterText(composerField(), '改后的输入');
    await tester.pump();
    await tester.tap(previewButton());
    await tester.pumpAndSettle();

    expect(find.text('预览请求体'), findsOneWidget);
    final body = await previewBodyText(tester);
    expect(body, contains('改后的输入'));
    expect(body, isNot(contains('第 1 轮的用户输入')), reason: '该轮已被截断重发，不再作为历史');
    expect(body, isNot(contains('第 2 轮的用户输入')), reason: '后续轮次随截断一起离开投影');

    // 预览零副作用：不删轮次、不消费用途（灰条与编辑内容原样保留）。
    await closeDialog(tester);
    expect(rp.rounds.map((r) => r.roundIndex).toList(), [1, 2]);
    expect(modeBar(), findsOneWidget);
    expect(fieldText(tester), '改后的输入');
  });

  testWidgets('灰条「按意见修改」：预览给出修改轮请求（意见 + n+1 历史）', (tester) async {
    final rp = await pumpChatScreen(tester, seedRounds: 1, seedBodyRepeats: 1);

    await tester.tap(find.text('按意见修改'));
    await tester.pumpAndSettle();
    expect(find.text('按意见修改（第 1 轮）'), findsOneWidget);

    await tester.enterText(composerField(), '把这段写紧凑些');
    await tester.pump();
    await tester.tap(previewButton());
    await tester.pumpAndSettle();

    final body = await previewBodyText(tester);
    expect(body, contains('把这段写紧凑些'), reason: '意见进请求');
    expect(body, contains('第 1 轮的用户输入'), reason: '修改轮历史 = n 轮 + 被重写轮自身');

    await closeDialog(tester);
    expect(rp.rounds.map((r) => r.roundIndex).toList(), [1]);
    expect(modeBar(), findsOneWidget);
  });
}
