import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/config/ai_platforms.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/providers/ai_settings_provider.dart';
import 'package:narrchat/services/image_import_service.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/image_preview.dart';

import 'helpers/chat_harness.dart';
import 'helpers/fakes.dart';

/// 搜索 BETA 标黄的警告色（取自浅色主题，与 UI 实现一致）。
final Color _kWarningYellow = NarrChatColors.light.warning;

/// 全部选项关闭的设置（用于「无」摘要用例）。
class _AllDisabledSettings extends AiSettingsProvider {
  @override
  bool get thinking => false;
  @override
  bool get streaming => false;
  @override
  bool get lastSearch => false;
}

/// 记录生成完成回调的测试记录器。
class _RecordingCompletion {
  final List<({int bookId, String bookTitle})> calls = [];

  void call(int bookId, String bookTitle) {
    calls.add((bookId: bookId, bookTitle: bookTitle));
  }
}

void main() {
  const book = Book(id: 1, title: '测试书');

  /// 主输入框（悬浮输入卡内，按占位文案定位，避免与侧栏字段混淆）。
  Finder composerField() => find.byWidgetPredicate(
        (w) =>
            w is TextField &&
            w.decoration?.hintText == '输入你的行动或对话…',
      );

  /// 「滚动到底部」按钮上的「有新内容」红点（圆形红色 Container）。
  Finder redDot() => find.byWidgetPredicate(
        (w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).shape == BoxShape.circle &&
            (w.decoration as BoxDecoration).color == Colors.red,
      );

  testWidgets('输入框：预设 3 行起步，最高 8 行（超出内滚）', (tester) async {
    await pumpChatScreen(tester, bookDao: FakeBookDao(books: [book]));

    final field = tester.widget<TextField>(composerField());
    expect(field.minLines, 3);
    expect(field.maxLines, 8);
  });

  testWidgets('宽屏侧栏常驻：仅显示滚动到底部按钮（侧栏按钮隐藏）', (tester) async {
    await pumpChatScreen(tester, bookDao: FakeBookDao(books: [book]));

    // 宽屏 + 侧栏默认展开（常驻）：只保留滚动到底部按钮，自动右对齐。
    expect(find.byIcon(Icons.vertical_align_bottom), findsOneWidget);
    expect(find.byIcon(Icons.view_sidebar_outlined), findsNothing);
  });

  testWidgets('窄屏：两个 1:1 方形按钮齐全（从右往左 = 打开侧栏在右）', (tester) async {
    await pumpChatScreen(
      tester,
      bookDao: FakeBookDao(books: [book]),
      size: const Size(600, 900),
    );

    final scrollBtn = find.byIcon(Icons.vertical_align_bottom);
    final sidebarBtn = find.byIcon(Icons.view_sidebar_outlined);
    expect(scrollBtn, findsOneWidget);
    expect(sidebarBtn, findsOneWidget);

    // 从右往左：打开侧栏在右，滚动到底部在左。
    final scrollX = tester.getCenter(scrollBtn).dx;
    final sidebarX = tester.getCenter(sidebarBtn).dx;
    expect(sidebarX, greaterThan(scrollX));
  });

  testWidgets('下拉摘要：默认「流式 | 思考」（搜索默认关闭），开启后搜索段警告色', (tester) async {
    await pumpChatScreen(tester, bookDao: FakeBookDao(books: [book]));

    // 默认：思考/流式开启、联网搜索关闭。
    expect(find.textContaining('流式'), findsOneWidget);
    expect(find.textContaining('思考'), findsOneWidget);
    expect(find.textContaining('搜索(BETA)'), findsNothing);

    // 打开菜单，点击「搜索」行启用。
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    await tester.tap(find.text('搜索'));
    await tester.pumpAndSettle();
    // 收起菜单 → 摘要含 搜索(BETA)。
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();

    // 搜索(BETA) 段为警告色（不加粗）。
    final summary = find.textContaining('搜索(BETA)');
    expect(summary, findsOneWidget);
    final text = tester.widget<Text>(summary);
    final span = text.textSpan! as TextSpan;
    final searchSpan = span.children!
        .cast<TextSpan>()
        .firstWhere((s) => s.text == '搜索(BETA)');
    expect(searchSpan.style?.color, _kWarningYellow);
    expect(searchSpan.style?.fontWeight, FontWeight.w500);
  });

  testWidgets('下拉摘要：全部选项关闭时显示「无」', (tester) async {
    await pumpChatScreen(
      tester,
      bookDao: FakeBookDao(books: [book]),
      settings: _AllDisabledSettings(),
    );

    expect(find.text('无'), findsOneWidget);
    expect(find.textContaining('搜索(BETA)'), findsNothing);
  });

  testWidgets('下拉菜单：打开与关闭带 Material 动画（淡入淡出）', (tester) async {
    await pumpChatScreen(tester, bookDao: FakeBookDao(books: [book]));

    // 任一祖先 FadeTransition 透明度 < 1 → 动画进行中（淡入/淡出）。
    bool anyFading() {
      for (final e in find
          .ancestor(
            of: find.text('流式'),
            matching: find.byType(FadeTransition),
          )
          .evaluate()) {
        if ((e.widget as FadeTransition).opacity.value < 1.0) return true;
      }
      return false;
    }

    // 打开：停在动画中途（100ms < 打开时长 500ms），菜单项应处于淡入中。
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(anyFading(), isTrue, reason: '菜单打开应带动画（淡入中）');

    // 动画完成后菜单项完全可见。
    await tester.pumpAndSettle();
    expect(find.text('流式'), findsOneWidget);

    // 关闭：停在动画中途（100ms < 关闭时长 150ms），菜单项应处于淡出中。
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(anyFading(), isTrue, reason: '菜单关闭应带动画（淡出中）');

    // 关闭动画完成后菜单项消失。
    await tester.pumpAndSettle();
    expect(find.text('流式'), findsNothing);
  });

  testWidgets('联网搜索：未启用时二级提示灰色，启用后变警告色', (tester) async {
    await pumpChatScreen(tester, bookDao: FakeBookDao(books: [book]));

    // 打开选项下拉：搜索默认关闭 → 二级提示为灰色。
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    const warnText = '此功能为试验版，存在大量问题，启动会数倍增加 token 消耗';
    final warn = find.text(warnText);
    expect(warn, findsOneWidget);
    expect(
      tester.widget<Text>(warn).style?.color,
      isNot(_kWarningYellow),
      reason: '搜索未启用时二级提示为灰色',
    );

    // 点击「搜索」行启用 → 二级提示变为警告色。
    await tester.tap(find.text('搜索'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.text(warnText)).style?.color,
      _kWarningYellow,
    );
  });

  testWidgets('联网搜索二级提示：未启用为灰且可点二级文本启用', (tester) async {
    await pumpChatScreen(tester, bookDao: FakeBookDao(books: [book]));

    // 打开菜单：搜索默认关闭，二级提示显示且为灰色。
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    const warnText = '此功能为试验版，存在大量问题，启动会数倍增加 token 消耗';
    expect(find.text(warnText), findsOneWidget);
    expect(
      tester.widget<Text>(find.text(warnText)).style?.color,
      isNot(_kWarningYellow),
    );

    // 点击二级提示文本本身（位于按钮内）→ 启用搜索 → 变警告色。
    await tester.tap(find.text(warnText));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.text(warnText)).style?.color,
      _kWarningYellow,
    );

    // 收起菜单：摘要含 搜索(BETA)（已启用）。
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(find.textContaining('搜索(BETA)'), findsOneWidget);
  });

  testWidgets('下拉菜单：切换选项后摘要实时更新', (tester) async {
    await pumpChatScreen(tester, bookDao: FakeBookDao(books: [book]));

    // 默认：思考/流式开启、联网搜索关闭。
    expect(find.textContaining('思考'), findsOneWidget);
    expect(find.textContaining('搜索(BETA)'), findsNothing);

    // 打开菜单，点击「思考」行关闭该选项。
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    await tester.tap(find.text('思考'));
    await tester.pumpAndSettle();

    // closeOnActivate:false → 菜单保持展开（二级提示仍在）。
    expect(
      find.text('此功能为试验版，存在大量问题，启动会数倍增加 token 消耗'),
      findsOneWidget,
    );

    // 收起菜单 → 摘要不再含「思考」。
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(find.textContaining('思考'), findsNothing);
    expect(find.textContaining('流式'), findsOneWidget);
    expect(find.textContaining('搜索(BETA)'), findsNothing);
  });

  testWidgets('生成完成后调用 onGenerationCompleted 回调', (tester) async {
    final completion = _RecordingCompletion();
    final roundProvider = await pumpChatScreen(
      tester,
      bookDao: FakeBookDao(books: [book]),
      onGenerationCompleted: completion.call,
    );

    await tester.enterText(composerField(), '开始新的剧情');
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await waitSendDone(tester, roundProvider);

    expect(completion.calls, hasLength(1));
    expect(completion.calls.single.bookId, book.id);
    expect(completion.calls.single.bookTitle, book.title);
  });

  testWidgets('生成结束红点：生成中不显示，结束离开底部显示，回到底部消失', (tester) async {
    final ai = FakeStreamingAiService();
    final roundProvider = await pumpChatScreen(
      tester,
      bookDao: FakeBookDao(books: [book]),
      ai: ai,
      seedRounds: 4,
    );

    // 触发生成（UI 发送，流式进行中）。
    await tester.enterText(composerField(), '继续剧情');
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();
    ai.emit('第一段内容');
    await tester.pump();
    expect(redDot(), findsNothing, reason: '生成过程中不应显示红点');

    // 生成中上翻离开底部：仍不显示红点。
    await tester.drag(find.byType(ListView), const Offset(0, 150));
    await tester.pump();
    expect(redDot(), findsNothing, reason: '生成过程中上翻也不应显示红点');

    // 生成结束（此时用户未在底部）→ 显示红点。
    ai.complete();
    for (var i = 0; i < 20 && roundProvider.isSending; i++) {
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(redDot(), findsOneWidget, reason: '生成结束且未在底部时应显示红点');

    // 滚动回底部 → 红点消失。
    await tester.drag(find.byType(ListView), const Offset(0, -3000));
    await tester.pumpAndSettle();
    expect(redDot(), findsNothing, reason: '滚动回底部后红点应消失');
  });

  testWidgets('红点不因调整窗口宽度/修改左下角选项误触发', (tester) async {
    await pumpChatScreen(
      tester,
      bookDao: FakeBookDao(books: [book]),
      seedRounds: 2,
    );

    // 位于底部：无红点。
    expect(redDot(), findsNothing);

    // 修改左下角选项（打开下拉 → 切换流式 → 收起）。
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    await tester.tap(find.text('流式'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(redDot(), findsNothing, reason: '修改左下角选项不应触发红点');

    // 调整窗口宽度（1200 仍为宽屏）→ 恢复。
    tester.view.physicalSize = const Size(1200, 900);
    await tester.pumpAndSettle();
    expect(redDot(), findsNothing, reason: '调整窗口宽度不应触发红点');
    tester.view.physicalSize = const Size(1400, 900);
    await tester.pumpAndSettle();
    expect(redDot(), findsNothing);
  });

  testWidgets('右下角模型选择器：显示当前模型，可在菜单中切换', (tester) async {
    final settings = AiSettingsProvider();
    await pumpChatScreen(tester, settings: settings);

    // 当前模型（默认 deepseek-v4-pro，无简写标识时显示模型名）。
    expect(find.text('deepseek-v4-pro'), findsWidgets);

    // 打开模型菜单。
    await tester.tap(find.text('deepseek-v4-pro').first);
    await tester.pumpAndSettle();

    // 菜单含其它模型。
    expect(find.text('deepseek-v4-flash'), findsWidgets);

    // 切换到 flash。
    await tester.tap(find.text('deepseek-v4-flash').last);
    await tester.pumpAndSettle();
    expect(settings.selectedModelId, 'deepseek-v4-flash');
  });

  testWidgets('识图模型：功能菜单出现「导入图片」', (tester) async {
    final settings = AiSettingsProvider();
    // 不 await：FakeAsync 下真实文件 I/O 的 Future 不会完成，但内存态同步生效。
    settings.setSelectedModel(
      AiPlatforms.defaultPlatformId,
      'deepseek-v4-flash-vision-exp',
    );
    await pumpChatScreen(tester, settings: settings);

    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();

    expect(find.text('导入图片'), findsOneWidget);
  });

  testWidgets('非识图模型：功能菜单不出现「导入图片」', (tester) async {
    // 默认选中 deepseek-v4-pro（supportsVision=false）。
    await pumpChatScreen(tester);

    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();

    expect(find.text('导入图片'), findsNothing);
  });

  testWidgets('识图模型：点击「导入图片」调用导入服务（默认 16MB）', (tester) async {
    final settings = AiSettingsProvider();
    settings.setSelectedModel(
      AiPlatforms.defaultPlatformId,
      'deepseek-v4-flash-vision-exp',
    );
    final imageImport = FakeImageImportService(
      results: [const ImageImportResult(paths: ['img/aaa.png'])],
    );
    await pumpChatScreen(tester, settings: settings, imageImport: imageImport);

    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(find.text('导入图片'), findsOneWidget);

    await tester.tap(find.text('导入图片'));
    await tester.pumpAndSettle();

    expect(imageImport.calls, 1);
    expect(imageImport.lastSizeLimitMb, 16);
  });

  testWidgets('待发送图片条：位于输入框上方且靠左（不再居中）', (tester) async {
    final settings = AiSettingsProvider();
    // 不 await：FakeAsync 下真实文件 I/O 的 Future 不会完成，但内存态同步生效。
    settings.setSelectedModel(
      AiPlatforms.defaultPlatformId,
      'deepseek-v4-flash-vision-exp',
    );
    final imageImport = FakeImageImportService(
      results: [const ImageImportResult(paths: ['img/aaa.png'])],
    );
    await pumpChatScreen(tester, settings: settings, imageImport: imageImport);

    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导入图片'));
    await tester.pumpAndSettle();

    final strip = find.byKey(const Key('composer_image_strip'));
    expect(strip, findsOneWidget);
    final stripRect = tester.getTopLeft(strip);
    final fieldRect = tester.getTopLeft(composerField());
    // 缩略条在输入框上方。
    expect(stripRect.dy, lessThan(fieldRect.dy));
    // 靠左对齐输入框左缘（允许 14px 内容边距），而非居中。
    expect((stripRect.dx - fieldRect.dx).abs(), lessThan(40));
  });

  testWidgets('发送后：待发送图片立即清空并上屏至用户气泡', (tester) async {
    final settings = AiSettingsProvider();
    settings.setSelectedModel(
      AiPlatforms.defaultPlatformId,
      'deepseek-v4-flash-vision-exp',
    );
    final imageImport = FakeImageImportService(
      results: [const ImageImportResult(paths: ['img/aaa.png'])],
    );
    final rp = await pumpChatScreen(
      tester,
      settings: settings,
      imageImport: imageImport,
    );

    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导入图片'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('composer_image_strip')), findsOneWidget);

    await tester.enterText(composerField(), '看图');
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();

    // 发送瞬间：输入框待发送条清空（图片已与文字同帧上屏）。
    expect(find.byKey(const Key('composer_image_strip')), findsNothing);

    await waitSendDone(tester, rp);
    // 生成结束：用户气泡带图片（缩略条存在于气泡内）。
    expect(find.byType(ImagePreviewStrip), findsOneWidget);
  });

  testWidgets('生成过程中：用户气泡即显示图片（无需等生成结束）', (tester) async {
    final settings = AiSettingsProvider();
    settings.setSelectedModel(
      AiPlatforms.defaultPlatformId,
      'deepseek-v4-flash-vision-exp',
    );
    final imageImport = FakeImageImportService(
      results: [const ImageImportResult(paths: ['img/aaa.png'])],
    );
    final ai = FakeStreamingAiService();
    final rp = await pumpChatScreen(
      tester,
      settings: settings,
      imageImport: imageImport,
      ai: ai,
    );

    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导入图片'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('composer_image_strip')), findsOneWidget);

    await tester.enterText(composerField(), '看图');
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();

    // 生成中：输入卡待发送条清空，用户气泡（含文字与图片）已上屏。
    expect(find.byKey(const Key('composer_image_strip')), findsNothing);
    expect(find.byType(ImagePreviewStrip), findsOneWidget);
    expect(find.text('看图'), findsOneWidget);

    // 流式进行中，气泡持续带图片。
    ai.emit('第一句');
    await tester.pump();
    expect(find.byType(ImagePreviewStrip), findsOneWidget);

    ai.complete();
    for (var i = 0; i < 20 && rp.isSending; i++) {
      await tester.pump();
    }
    await tester.pumpAndSettle();
  });
}
