import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/config/ai_platforms.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/providers/ai_settings_provider.dart';
import 'package:narrchat/widgets/image_preview.dart';

import 'helpers/chat_harness.dart';
import 'helpers/fakes.dart';

void main() {
  testWidgets('重新提问：生成一开始用户气泡即带原图片（非发送路径）', (tester) async {
    // 预置一轮带图片的用户消息（重新提问时读取该轮 userImages）。
    final dao = FakeRoundDao();
    await dao.insertRound(
      Round(
        bookId: 1,
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
      'deepseek-v4-flash-vision-exp',
    );
    final ai = FakeStreamingAiService();
    final rp = await pumpChatScreen(
      tester,
      roundDao: dao,
      settings: settings,
      ai: ai,
    );

    // 长按用户气泡 → 上下文菜单 → 重新提问。
    await tester.longPress(find.text('第 1 轮的用户输入'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重新提问'));
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
}
