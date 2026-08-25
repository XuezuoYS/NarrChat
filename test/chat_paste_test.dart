import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/config/ai_platforms.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/providers/ai_settings_provider.dart';
import 'package:narrchat/widgets/image_preview.dart';

import 'helpers/chat_harness.dart';
import 'helpers/fakes.dart';

/// 聊天输入框的右键菜单 / 粘贴（含图片）集成测试。
///
/// 依赖 [pumpChatScreen]（已注入 [FakeClipboardPasteService]）与
/// [FakeClipboardPasteService]，不触碰真实剪贴板 / 文件系统。
void main() {
  const book = Book(id: 1, title: '测试书');

  /// 主输入框（悬浮输入卡内，按占位文案定位）。
  Finder composerField() => find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == '输入你的行动或对话…',
      );

  testWidgets('右键/长按菜单：包含全选、复制、粘贴、剪切', (tester) async {
    await pumpChatScreen(tester, bookDao: FakeBookDao(books: [book]));

    await tester.longPress(composerField());
    await tester.pumpAndSettle();

    expect(find.text('全选'), findsOneWidget);
    expect(find.text('复制'), findsOneWidget);
    expect(find.text('粘贴'), findsOneWidget);
    expect(find.text('剪切'), findsOneWidget);
  });

  testWidgets('右键→粘贴文本：插入到输入框', (tester) async {
    await pumpChatScreen(
      tester,
      bookDao: FakeBookDao(books: [book]),
      clipboardPaste: FakeClipboardPasteService(text: '粘贴文本'),
    );

    await tester.longPress(composerField());
    await tester.pumpAndSettle();
    await tester.tap(find.text('粘贴'));
    await tester.pumpAndSettle();

    expect(tester.widget<TextField>(composerField()).controller!.text, '粘贴文本');
  });

  testWidgets('识图模型：粘贴图片加入待发送附件条', (tester) async {
    final settings = AiSettingsProvider();
    settings.setSelectedModel(
      AiPlatforms.defaultPlatformId,
      'deepseek-v4-flash-vision-exp',
    );
    await pumpChatScreen(
      tester,
      bookDao: FakeBookDao(books: [book]),
      settings: settings,
      clipboardPaste: FakeClipboardPasteService(
        imagePng: Uint8List.fromList([0, 1, 2]),
      ),
    );

    await tester.longPress(composerField());
    await tester.pumpAndSettle();
    await tester.tap(find.text('粘贴'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('composer_image_strip')), findsOneWidget);
  });

  testWidgets('非识图模型：粘贴图片提示并忽略', (tester) async {
    await pumpChatScreen(
      tester,
      bookDao: FakeBookDao(books: [book]),
      clipboardPaste: FakeClipboardPasteService(
        imagePng: Uint8List.fromList([0, 1, 2]),
      ),
    );

    await tester.longPress(composerField());
    await tester.pumpAndSettle();
    await tester.tap(find.text('粘贴'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('composer_image_strip')), findsNothing);
    expect(find.textContaining('不支持识图'), findsOneWidget);
  });

  testWidgets('识图模型：粘贴图片超限提示，不加附件', (tester) async {
    final settings = AiSettingsProvider();
    settings.setSelectedModel(
      AiPlatforms.defaultPlatformId,
      'deepseek-v4-flash-vision-exp',
    );
    await pumpChatScreen(
      tester,
      bookDao: FakeBookDao(books: [book]),
      settings: settings,
      clipboardPaste: FakeClipboardPasteService(
        imageWarning: '剪贴板图片超过 16MB，请压缩后重试。',
      ),
    );

    await tester.longPress(composerField());
    await tester.pumpAndSettle();
    await tester.tap(find.text('粘贴'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('composer_image_strip')), findsNothing);
    expect(find.textContaining('超过'), findsOneWidget);
  });

  testWidgets('Ctrl+V 粘贴文本（快捷键路径）', (tester) async {
    await pumpChatScreen(
      tester,
      bookDao: FakeBookDao(books: [book]),
      clipboardPaste: FakeClipboardPasteService(text: '快捷键粘贴'),
    );

    await tester.enterText(composerField(), '');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(tester.widget<TextField>(composerField()).controller!.text, '快捷键粘贴');
  });

  testWidgets('粘贴文本+图片并发送：用户气泡带文本与图', (tester) async {
    final settings = AiSettingsProvider();
    settings.setSelectedModel(
      AiPlatforms.defaultPlatformId,
      'deepseek-v4-flash-vision-exp',
    );
    final rp = await pumpChatScreen(
      tester,
      bookDao: FakeBookDao(books: [book]),
      settings: settings,
      clipboardPaste: FakeClipboardPasteService(
        text: '看图说话',
        imagePng: Uint8List.fromList([0, 1, 2]),
      ),
    );

    await tester.longPress(composerField());
    await tester.pumpAndSettle();
    await tester.tap(find.text('粘贴'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('composer_image_strip')), findsOneWidget);

    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();
    await waitSendDone(tester, rp);

    // 发送后：输入框附件条清空，用户气泡带图带文本。
    expect(find.byKey(const Key('composer_image_strip')), findsNothing);
    expect(find.text('看图说话'), findsOneWidget);
    expect(find.byType(ImagePreviewStrip), findsOneWidget);
  });
}
