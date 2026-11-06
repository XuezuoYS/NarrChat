import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/config/ai_platforms.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/providers/ai_settings_provider.dart';
import 'package:narrchat/widgets/image_preview.dart';

import 'helpers/chat_harness.dart';
import 'helpers/fakes.dart';

/// 「生成一开始用户气泡即带图」的非发送路径：刷新本轮（正常轮次 / 错误代）。
///
/// R3 语义：失败不再是「底部特殊失败气泡」，而是链上一条 `message_status='error'`
/// 的真轮次（方案 A）；因此失败态由 `Round.isError` 判定，入口仍在
/// `AiBubbleActions` 上（与正常轮次同一个「刷新本轮」）。
void main() {
  testWidgets('刷新本轮：生成一开始用户气泡即带原图片（非发送路径）', (tester) async {
    final settings = AiSettingsProvider();
    settings.setSelectedModel(
      AiPlatforms.defaultPlatformId,
      'deepseek-flash',
    );
    final ai = FakeStreamingAiService();

    // 真库 I/O 必须包 `tester.runAsync`（fake-async 区域里不会自己转起来）。
    final stack = (await tester.runAsync(TestStack.create))!;
    addTearDown(() => tester.runAsync(stack.dispose));
    await tester.runAsync(() async {
      await stack.seedBook(uuid: kHarnessBookUuid, title: '测试书');
      await stack.seedRound(
        kHarnessBookUuid,
        roundIndex: 1,
        userInput: '第 1 轮的用户输入',
        aiNarrative: '第 1 轮的剧情正文。',
        userImages: const ['img/aaa.png'],
      );
    });

    final rp = await pumpChatScreen(
      tester,
      stack: stack,
      settings: settings,
      ai: ai,
    );

    // 长按用户气泡 → 上下文菜单 → 刷新本轮（与气泡底部按钮同一操作）。
    await tester.longPress(find.text('第 1 轮的用户输入'));
    await settle(tester);
    await tester.tap(
      find.descendant(
        of: find.byWidgetPredicate(
          (w) => w is PopupMenuItem<String> && w.value == 'refresh',
        ),
        matching: find.text('刷新本轮'),
      ),
    );
    await settle(tester);
    await tester.tap(find.text('继续'));
    // 生成中有无限转圈动画，不能 settle：推几帧让待发送气泡渲染出来即可。
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    // 生成中：原轮次已删除，待发送条未出现，用户气泡带图片。
    expect(find.byKey(const Key('composer_image_strip')), findsNothing);
    expect(find.byType(ImagePreviewStrip), findsWidgets);

    ai.complete();
    await waitSendDone(tester, rp);
  });

  testWidgets('错误代「刷新本轮」：同一确认框 + 同一路径，以失败输入与原图重刷该轮',
      (tester) async {
    final ai = ToggleAiService()..fail = true;
    final rp = await pumpChatScreen(tester, ai: ai);
    await rp.sendRound(
      userInput: '失败的输入',
      book: const Book(uuid: kHarnessBookUuid, title: '测试书'),
      userImages: const ['img/a.png'],
    );
    await settle(tester);

    // 方案 A：失败就是链上的一轮，红条由 message 呈现。
    expect(rp.rounds, hasLength(1));
    expect(rp.rounds.single.isError, isTrue);
    expect(rp.rounds.single.hasMessage, isTrue, reason: '错误代必须带提示文案');
    expect(rp.rounds.single.userImages, ['img/a.png'], reason: '失败也保留用户图片');

    ai.fail = false;
    // 错误代底部按钮：与正常轮次同一入口 → 先弹同一个二次确认。
    await tester.tap(find.text('刷新本轮').last);
    await settle(tester);
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
    await settle(tester);

    // 生成中：新代正在生成，用户气泡带失败时的原图。
    expect(find.byType(ImagePreviewStrip), findsWidgets);

    await waitSendDone(tester, rp);
    expect(rp.rounds.last.roundIndex, 1);
    expect(rp.rounds.last.isError, isFalse);
    expect(rp.rounds.last.userInput, '失败的输入');
    expect(rp.rounds.last.userImages, ['img/a.png']);
  });
}
