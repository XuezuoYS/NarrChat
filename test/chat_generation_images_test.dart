import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/config/ai_platforms.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/providers/ai_settings_provider.dart';
import 'package:narrchat/widgets/failed_attempt_bubble.dart';
import 'package:narrchat/widgets/image_preview.dart';

import 'helpers/chat_harness.dart';
import 'helpers/fakes.dart';

/// 「生成一开始用户气泡即带图」的非发送路径：刷新本轮（正常轮次 / 失败条目）。
///
/// 「刷新本轮」是唯一入口（气泡底部按钮、气泡菜单、失败条目三处同一确认框与同一
/// Provider 路径），本文件覆盖其中两条会「借旧输入重新生成」的路径。
void main() {
  testWidgets('刷新本轮：生成一开始用户气泡即带原图片（非发送路径）', (tester) async {
    // 预置一轮带图片的用户消息（刷新本轮时读取该轮 userImages）。
    final dao = FakeRoundDao();
    await dao.insertRound(
      Round(
        bookUuid: kHarnessBookUuid,
        roundIndex: 1,
        userInput: '第 1 轮的用户输入',
        aiNarrative: '第 1 轮的剧情正文。',
        userImages: ['img/aaa.png'],
        createdAt: DateTime.now(),
      ),
    );

    final settings = AiSettingsProvider();
    settings.setSelectedModel(
      AiPlatforms.defaultPlatformId,
      'deepseek-flash',
    );
    final ai = FakeStreamingAiService();
    final rp = await pumpChatScreen(
      tester,
      roundDao: dao,
      settings: settings,
      ai: ai,
    );

    // 长按用户气泡 → 上下文菜单 → 刷新本轮（与气泡底部按钮同一操作）。
    await tester.longPress(find.text('第 1 轮的用户输入'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byWidgetPredicate(
          (w) => w is PopupMenuItem<String> && w.value == 'refresh',
        ),
        matching: find.text('刷新本轮'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('继续'));
    await tester.pump();

    // 生成中：原轮次已删除，待发送条未出现，用户气泡带图片。
    expect(find.byKey(const Key('composer_image_strip')), findsNothing);
    expect(find.byType(ImagePreviewStrip), findsWidgets);

    ai.complete();
    for (var i = 0; i < 20 && rp.isSending; i++) {
      await tester.pump();
    }
    await tester.pumpAndSettle();
  });

  testWidgets('失败条目「刷新本轮」：同一确认框 + 同一路径，以失败输入与原图重刷该轮', (tester) async {
    final ai = ToggleAiService()..fail = true;
    final rp = await pumpChatScreen(tester, ai: ai);
    await rp.sendRound(
      userInput: '失败的输入',
      book: const Book(uuid: kHarnessBookUuid, title: '测试书'),
      userImages: const ['img/a.png'],
    );
    await tester.pumpAndSettle();
    expect(rp.hasFailureEntry, isTrue);

    ai.fail = false;
    // 失败条目底部按钮：与正常轮次同一入口 → 先弹同一个二次确认。
    await tester.tap(
      find.descendant(
        of: find.byType(FailedAttemptBubble),
        matching: find.text('刷新本轮'),
      ),
    );
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    expect(dialog, findsOneWidget);
    expect(
      find.descendant(of: dialog, matching: find.text('刷新本轮')),
      findsOneWidget,
      reason: '确认框标题与入口同名',
    );
    expect(find.textContaining('将重新生成第 1 轮'), findsOneWidget);
    expect(
      find.textContaining('将删除本轮'),
      findsNothing,
      reason: '不再喊会丢后续内容（旧版本与后续轮次都保留在版本树）',
    );

    await tester.tap(find.text('继续'));
    await tester.pump();

    // 生成中：失败条目已清（同一条路径会先清失败态），用户气泡带失败时的原图。
    expect(rp.hasFailureEntry, isFalse);
    expect(find.byType(ImagePreviewStrip), findsWidgets);

    await waitSendDone(tester, rp);
    expect(rp.rounds.last.roundIndex, 1);
    expect(rp.rounds.last.userInput, '失败的输入');
    expect(rp.rounds.last.userImages, ['img/a.png']);
  });
}
