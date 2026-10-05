import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/config/ai_platforms.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/widgets/composer_input_mode.dart';

import 'helpers/chat_harness.dart';
import 'helpers/fakes.dart';

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
  Future<FakeRoundDao> seedRoundWithImages(
    List<String> images, {
    String input = '第 1 轮的用户输入',
  }) async {
    final dao = FakeRoundDao();
    await dao.insertRound(
      Round(
        bookUuid: kHarnessBookUuid,
        roundIndex: 1,
        userInput: input,
        aiNarrative: '第 1 轮的剧情正文。',
        userImages: images,
        createdAt: DateTime.now(),
      ),
    );
    return dao;
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
    final rp = await pumpChatScreen(
      tester,
      seedRounds: 2,
      seedBodyRepeats: 1,
    );

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
    expect(rp.rounds.map((r) => r.roundIndex).toList(), [0, 1]);
    expect(rp.rounds.last.userInput, '改后的输入');
    expect(rp.rounds.last.aiNarrative, contains('成功正文'));
    // 用途已被消费：灰条收起、输入框清空。
    expect(modeBar(), findsNothing);
    expect(fieldText(tester), '');
  });

  testWidgets('灰条右侧删除键：退出用途并清空输入与待发送图片', (tester) async {
    final dao = await seedRoundWithImages(['img/aaa.png']);
    await pumpChatScreen(tester, roundDao: dao);

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
    settings.setSelectedModel(
      AiPlatforms.defaultPlatformId,
      'deepseek-v4-pro',
    );
    final dao = await seedRoundWithImages(['img/aaa.png']);
    await pumpChatScreen(tester, roundDao: dao, settings: settings);

    await tapEditAndReAsk(tester, '第 1 轮的用户输入');

    expect(fieldText(tester), '第 1 轮的用户输入');
    expect(find.byKey(const Key('composer_image_strip')), findsNothing);
  });

  testWidgets('失败条目「修改并重新提问」：灰条载入失败输入，提交后清空失败条目', (tester) async {
    final ai = ToggleAiService()..fail = true;
    final rp = await pumpChatScreen(tester, ai: ai);

    // 先制造失败条目（失败原因以红框气泡展示）。
    await rp.sendRound(userInput: '失败的输入', book: book);
    await tester.pumpAndSettle();
    expect(rp.hasFailureEntry, isTrue);

    await tester.tap(find.text('修改并重新提问'));
    await tester.pumpAndSettle();

    // 失败条目「本该产生」第 1 轮：灰条文案取该轮号。
    expect(find.text('修改并重新提问（第 1 轮）'), findsOneWidget);
    expect(fieldText(tester), '失败的输入');

    ai.fail = false;
    await tester.enterText(composerField(), '改后的失败输入');
    await tester.pump();
    await tester.tap(sendButton());
    await tester.pump();
    await waitSendDone(tester, rp);

    expect(rp.hasFailureEntry, isFalse);
    // 新书无轮次时自动建「第零轮」，故本次生成为第 1 轮（列表末项）。
    expect(rp.rounds.length, 2);
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

  testWidgets('灰条以外的破坏性入口（刷新本轮）依旧二次确认：取消即不生成', (tester) async {
    final rp = await pumpChatScreen(tester, seedRounds: 1, seedBodyRepeats: 1);

    // 底部「刷新本轮」不经输入框：保留二次确认（与灰条用途的区别就在这）。
    await tester.tap(find.text('刷新本轮'));
    await tester.pumpAndSettle();

    final dialog = find.byType(AlertDialog);
    expect(dialog, findsOneWidget);
    expect(
      find.descendant(of: dialog, matching: find.text('刷新本轮')),
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
}
