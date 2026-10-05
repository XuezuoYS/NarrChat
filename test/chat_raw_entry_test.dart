import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/providers/round_provider.dart';
import 'package:narrchat/widgets/action_button.dart';
import 'package:narrchat/widgets/ai_bubble_actions.dart';
import 'package:narrchat/widgets/failed_attempt_bubble.dart';
import 'package:narrchat/widgets/raw_dialog.dart';

import 'helpers/chat_harness.dart';
import 'helpers/fakes.dart';
import 'helpers/notice_harness.dart';

/// 对话页 RAW **入口**契约（回归守护）。
///
/// 背景：RAW 入口曾按「本轮有没有 RAW 数据」显隐——数据是内存态（投影重建 /
/// 换书即清），于是代次切换、编辑正文之后入口整块消失，观感就是「RAW 功能被取消」。
/// 现在入口**恒在**（AI 气泡底部按钮 + 右键菜单 + 失败条目），无数据时点击给出说明。
void main() {
  const book = Book(uuid: kHarnessBookUuid, title: '测试书');

  Finder composerField() => find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.hintText == '输入你的行动或对话…',
  );

  Finder aiFooterButton(String label) => find.descendant(
    of: find.byType(AiBubbleActions),
    matching: find.ancestor(
      of: find.text(label),
      matching: find.byType(ActionButton),
    ),
  );

  /// 在对话页发送一轮（生成完成后气泡 footer 才带 RAW 数据）。
  Future<void> sendRound(WidgetTester tester, RoundProvider provider) async {
    await tester.enterText(composerField(), '新一轮输入');
    await tester.pump();
    await tester.tap(
      find.ancestor(
        of: find.byIcon(Icons.arrow_upward),
        matching: find.byType(IconButton),
      ),
    );
    await tester.pump();
    await waitSendDone(tester, provider);
  }

  testWidgets('AI 气泡底部恒有 RAW 入口（预置轮次无 RAW 数据也照常显示）', (tester) async {
    await pumpChatScreen(tester, seedRounds: 1, seedBodyRepeats: 1);

    final labels = tester
        .widgetList<ActionButton>(
          find.descendant(
            of: find.byType(AiBubbleActions),
            matching: find.byType(ActionButton),
          ),
        )
        .map((b) => b.label)
        .toList();
    expect(labels, contains('RAW'), reason: '入口不按数据显隐');

    await tester.tap(aiFooterButton('RAW'));
    await settleNoticeEnter(tester);
    expect(find.textContaining('本轮暂无 RAW 记录'), findsOneWidget);
    await flushNotices(tester);
  });

  testWidgets('AI 气泡右键菜单恒含 RAW 项（无数据时点击给出说明）', (tester) async {
    await pumpChatScreen(tester, seedRounds: 1, seedBodyRepeats: 1);

    await tester.longPress(find.text('第 1 轮的剧情正文。'));
    await tester.pumpAndSettle();

    final rawItem = find.byWidgetPredicate(
      (w) => w is PopupMenuItem<String> && w.value == 'raw',
    );
    expect(rawItem, findsOneWidget, reason: '菜单入口不按数据显隐');

    await tester.tap(find.descendant(of: rawItem, matching: find.text('RAW')));
    await settleNoticeEnter(tester);
    expect(find.textContaining('本轮暂无 RAW 记录'), findsOneWidget);
    await flushNotices(tester);
  });

  testWidgets('生成后的轮次：RAW 入口打开 RAW 对话框（有数据走对话框，不再提示）', (tester) async {
    final rp = await pumpChatScreen(tester, seedBodyRepeats: 1);
    await sendRound(tester, rp);

    expect(rp.rawExchangesFor(rp.rounds.last.id!), isNotNull);
    await tester.tap(aiFooterButton('RAW'));
    await tester.pumpAndSettle();

    expect(find.byType(RawDialog), findsOneWidget);
    expect(find.textContaining('本轮暂无 RAW 记录'), findsNothing);

    // 关闭对话框（Esc / 关闭按钮任一），避免遗留弹层影响收尾。
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    expect(find.byType(RawDialog), findsNothing);
  });

  testWidgets('失败条目：底部与菜单恒含 RAW 入口，可打开失败尝试的 RAW', (tester) async {
    final ai = ToggleAiService()..fail = true;
    final rp = await pumpChatScreen(tester, ai: ai);
    await rp.sendRound(userInput: '失败的输入', book: book);
    await tester.pumpAndSettle();
    expect(rp.hasFailureEntry, isTrue);

    final labels = tester
        .widgetList<ActionButton>(
          find.descendant(
            of: find.byType(FailedAttemptBubble),
            matching: find.byType(ActionButton),
          ),
        )
        .map((b) => b.label)
        .toList();
    expect(labels, contains('RAW'));

    await tester.tap(
      find.descendant(
        of: find.byType(FailedAttemptBubble),
        matching: find.ancestor(
          of: find.text('RAW'),
          matching: find.byType(ActionButton),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(RawDialog), findsOneWidget);
  });
}
