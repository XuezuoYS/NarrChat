import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/config/ai_platforms.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/providers/ai_settings_provider.dart';
import 'package:narrchat/services/image_import_service.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/char_count_indicator.dart';
import 'package:narrchat/widgets/image_preview.dart';

import 'helpers/chat_harness.dart';
import 'helpers/fakes.dart';

/// 搜索 BETA 标黄的警告色（取自浅色主题，与 UI 实现一致）。
final Color _kWarningYellow = NarrChatColors.light.warning;

/// 全部选项关闭的设置（用于「无」摘要用例，Chat 协议无 AGENT 徽标）。
class _AllDisabledSettings extends ChatCompatibleSettings {
  @override
  bool get thinking => false;
  @override
  bool get streaming => false;
  @override
  bool get lastSearch => false;
}

/// 记录生成完成回调的测试记录器（参数 = 书籍 uuid + 书名）。
class _RecordingCompletion {
  final List<({String bookUuid, String bookTitle})> calls = [];

  void call(String bookUuid, String bookTitle) {
    calls.add((bookUuid: bookUuid, bookTitle: bookTitle));
  }
}

void main() {
  const book = Book(uuid: kHarnessBookUuid, title: '测试书');

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

  testWidgets('输入框：预设 2 行起步，最高 8 行（超出内滚）', (tester) async {
    await pumpChatScreen(tester, bookDao: FakeBookDao(books: [book]));

    final field = tester.widget<TextField>(composerField());
    expect(field.minLines, 2);
    expect(field.maxLines, 8);
  });

  // —— 输入卡布局：文本区 ↔ 底部控件行 ——

  /// 输入卡底部控件行（承载选项下拉 / 模型选择 / 发送按钮的那一行）。
  Finder controlRow() => find
      .ancestor(
        of: find.byIcon(Icons.arrow_upward),
        matching: find.byType(Row),
      )
      .first;

  /// 输入卡底部控件行的顶端 y 坐标。
  double controlRowTop(WidgetTester tester) =>
      tester.getTopLeft(controlRow()).dy;

  /// 输入卡文本区的底端 y 坐标。
  double textAreaBottom(WidgetTester tester) =>
      tester.getBottomLeft(composerField()).dy;

  /// 输入卡文本区高度。
  double textAreaHeight(WidgetTester tester) =>
      tester.getSize(composerField()).height;

  testWidgets('输入框：第 3 行起才向上顶高（默认高度只按 2 行起算）', (tester) async {
    await pumpChatScreen(tester, bookDao: FakeBookDao(books: [book]));

    final defaultHeight = textAreaHeight(tester);

    await tester.enterText(composerField(), '第一行');
    await tester.pump();
    expect(textAreaHeight(tester), defaultHeight, reason: '第 1 行不顶高');

    await tester.enterText(composerField(), '第一行\n第二行');
    await tester.pump();
    expect(textAreaHeight(tester), defaultHeight, reason: '第 2 行仍保持默认高度');

    await tester.enterText(composerField(), '第一行\n第二行\n第三行');
    await tester.pump();
    // 第 3 行起卡片向上顶高，步长恰为一行（fontSize 15 × height 1.5 = 22.5px）。
    expect(textAreaHeight(tester), closeTo(defaultHeight + 22.5, 0.5));
  });

  testWidgets('输入卡：文本区与底部控件行之间保留间隙（不再无间隙贴合）', (tester) async {
    await pumpChatScreen(tester, bookDao: FakeBookDao(books: [book]));

    expect(controlRowTop(tester) - textAreaBottom(tester), closeTo(8, 0.01));
  });

  testWidgets('输入卡：填满三行（已被顶高）时底部间隙依旧保留', (tester) async {
    await pumpChatScreen(tester, bookDao: FakeBookDao(books: [book]));

    await tester.enterText(composerField(), '第一行\n第二行\n第三行');
    await tester.pump();

    // 顶高由文本区行数承担，不压缩文本区与控件行之间的间隙。
    expect(controlRowTop(tester) - textAreaBottom(tester), closeTo(8, 0.01));
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
    await tester.pump(); // 让发送按钮随输入文本重建（空输入时按钮为禁用态）。
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await waitSendDone(tester, roundProvider);

    expect(completion.calls, hasLength(1));
    expect(completion.calls.single.bookUuid, book.uuid);
    expect(completion.calls.single.bookTitle, book.title);
  });

  testWidgets('Ctrl+Enter 快捷发送：发送并清空输入框', (tester) async {
    final roundProvider = await pumpChatScreen(
      tester,
      bookDao: FakeBookDao(books: [book]),
    );

    await tester.enterText(composerField(), '快捷键发送');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    await waitSendDone(tester, roundProvider);

    // 已发送：用户气泡出现，且输入框被清空。
    expect(find.text('快捷键发送'), findsOneWidget);
    expect(
      tester.widget<TextField>(composerField()).controller!.text,
      isEmpty,
    );
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
    await tester.pump(); // 让发送按钮随输入文本重建（空输入时按钮为禁用态）。
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

    // 当前模型（默认预置首位 deepseek-flash，有简写标识时显示简写名称）。
    expect(find.text('DeepSeek V4.1 Flash'), findsWidgets);

    // 打开模型菜单。
    await tester.tap(find.text('DeepSeek V4.1 Flash').first);
    await tester.pumpAndSettle();

    // 菜单含另一模型（无简写标识时显示模型名）。
    expect(find.text('deepseek-v4-pro'), findsWidgets);

    // 切换到 V4 Pro。
    await tester.tap(find.text('deepseek-v4-pro').last);
    await tester.pumpAndSettle();
    expect(settings.selectedModelId, 'deepseek-v4-pro');
    // 选择器当前模型随之显示模型名。
    expect(find.text('deepseek-v4-pro'), findsOneWidget);
  });

  testWidgets('识图模型：功能菜单出现「导入图片」', (tester) async {
    final settings = AiSettingsProvider();
    // 不 await：FakeAsync 下真实文件 I/O 的 Future 不会完成，但内存态同步生效。
    settings.setSelectedModel(
      AiPlatforms.defaultPlatformId,
      'deepseek-flash',
    );
    await pumpChatScreen(tester, settings: settings);

    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();

    expect(find.text('导入图片'), findsOneWidget);
  });

  testWidgets('非识图模型：功能菜单不出现「导入图片」', (tester) async {
    // 显式选 v4 Pro（supportsVision=false）；默认预置首位的 Flash 识图全开。
    final settings = AiSettingsProvider();
    settings.setSelectedModel(
      AiPlatforms.defaultPlatformId,
      'deepseek-v4-pro',
    );
    await pumpChatScreen(tester, settings: settings);

    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();

    expect(find.text('导入图片'), findsNothing);
  });

  testWidgets('识图模型：点击「导入图片」调用导入服务（默认 16MB）', (tester) async {
    final settings = AiSettingsProvider();
    settings.setSelectedModel(
      AiPlatforms.defaultPlatformId,
      'deepseek-flash',
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
      'deepseek-flash',
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
      'deepseek-flash',
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
    await tester.pump(); // 让发送按钮随输入文本重建（空输入时按钮为禁用态）。
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
      'deepseek-flash',
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
    await tester.pump(); // 让发送按钮随输入文本重建（空输入时按钮为禁用态）。
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

  // —— 发送按钮置灰（无输入与可点状态区分） ——

  /// 输入卡内的发送/停止 IconButton（按 tooltip 定位，全局唯一）。
  Finder sendButton() => find.byWidgetPredicate(
        (w) =>
            w is IconButton &&
            (w.tooltip == '发送' || w.tooltip == '停止生成'),
      );

  /// 发送按钮的实际底色（ButtonStyleButton 把 background 解析到 Material.color）。
  Color sendButtonBackground(WidgetTester tester) {
    final material = tester.widget<Material>(
      find
          .descendant(of: sendButton(), matching: find.byType(Material))
          .first,
    );
    return material.color!;
  }

  testWidgets('发送按钮：输入为空时禁用，底色为浅色（区分可点态）', (tester) async {
    await pumpChatScreen(tester, bookDao: FakeBookDao(books: [book]));

    expect(tester.widget<IconButton>(sendButton()).onPressed, isNull);
    expect(
      sendButtonBackground(tester),
      NarrChatTheme.light.colorScheme.surfaceContainerHighest,
      reason: '浅色主题下禁用底色应为浅灰而非品牌蓝',
    );
  });

  testWidgets('发送按钮：输入文本后恢复可点且底色为品牌蓝', (tester) async {
    await pumpChatScreen(tester, bookDao: FakeBookDao(books: [book]));

    await tester.enterText(composerField(), '有内容');
    await tester.pump();

    expect(tester.widget<IconButton>(sendButton()).onPressed, isNotNull);
    expect(sendButtonBackground(tester), NarrChatTheme.primary);
  });

  testWidgets('发送按钮：仅空白字符仍禁用，清空后回到禁用', (tester) async {
    await pumpChatScreen(tester, bookDao: FakeBookDao(books: [book]));

    await tester.enterText(composerField(), '   ');
    await tester.pump();
    expect(tester.widget<IconButton>(sendButton()).onPressed, isNull);

    await tester.enterText(composerField(), 'x');
    await tester.pump();
    expect(tester.widget<IconButton>(sendButton()).onPressed, isNotNull);

    await tester.enterText(composerField(), '');
    await tester.pump();
    expect(tester.widget<IconButton>(sendButton()).onPressed, isNull);
    expect(
      sendButtonBackground(tester),
      NarrChatTheme.light.colorScheme.surfaceContainerHighest,
    );
  });

  testWidgets('发送按钮：深色主题下禁用底色为深色', (tester) async {
    await pumpChatScreen(
      tester,
      bookDao: FakeBookDao(books: [book]),
      theme: NarrChatTheme.dark,
    );

    final bg = sendButtonBackground(tester);
    expect(bg, NarrChatTheme.dark.colorScheme.surfaceContainerHighest);
    expect(
      bg.computeLuminance(),
      lessThan(0.2),
      reason: '深色主题下禁用底色应为深色',
    );
  });

  testWidgets('发送按钮：生成中（输入已清空）仍可点击作为停止', (tester) async {
    final ai = FakeStreamingAiService();
    final rp = await pumpChatScreen(
      tester,
      bookDao: FakeBookDao(books: [book]),
      ai: ai,
    );

    await tester.enterText(composerField(), '继续剧情');
    await tester.pump(); // 让发送按钮随输入文本重建后再点击。
    await tester.tap(sendButton());
    await tester.pump();

    // 发送后输入框已清空，但生成期间按钮转为「停止生成」，仍可点击且保持主色底。
    expect(tester.widget<IconButton>(sendButton()).tooltip, '停止生成');
    expect(tester.widget<IconButton>(sendButton()).onPressed, isNotNull);
    expect(sendButtonBackground(tester), NarrChatTheme.primary);

    ai.complete();
    await waitSendDone(tester, rp);
  });

  // —— 实时字数指示器（中英文字 / 标点 / 空格 / 表情各计 1） ——

  /// 字数指示器内的文本（按 label 定位，避免与页面上其它数字混淆）。
  Finder charCount(String label) =>
      find.descendant(of: find.byType(CharCountIndicator), matching: find.text(label));

  /// 字数指示器内部的 Text（读样式用）。
  Finder charCountText() => find.descendant(
    of: find.byType(CharCountIndicator),
    matching: find.byType(Text),
  );

  /// 模型选择器触发区里的模型名文本（模型菜单未打开时全局唯一）。
  Finder modelLabel() => find.text('DeepSeek V4.1 Flash');

  /// 字数文本当前的颜色。
  Color charCountColor(WidgetTester tester) =>
      tester.widget<Text>(charCountText()).style!.color!;

  testWidgets('实时字数：空输入显示 0 字（弱化色），随键入实时更新', (tester) async {
    await pumpChatScreen(tester, bookDao: FakeBookDao(books: [book]));

    expect(charCount('0 字'), findsOneWidget);
    expect(charCountColor(tester), NarrChatColors.light.placeholder);

    await tester.enterText(composerField(), '你好，world!');
    await tester.pump();
    expect(charCount('9 字'), findsOneWidget);
    expect(charCountColor(tester), NarrChatColors.light.textSecondary);

    // 清空后回到 0 字（不残留上一次统计），并重新弱化。
    await tester.enterText(composerField(), '');
    await tester.pump();
    expect(charCount('0 字'), findsOneWidget);
    expect(charCountColor(tester), NarrChatColors.light.placeholder);
  });

  testWidgets('实时字数：空格与换行计入，表情按 1 个字符计', (tester) async {
    await pumpChatScreen(tester, bookDao: FakeBookDao(books: [book]));

    await tester.enterText(composerField(), 'a b\nc');
    await tester.pump();
    expect(charCount('5 字'), findsOneWidget);

    await tester.enterText(composerField(), '好的👍');
    await tester.pump();
    expect(charCount('3 字'), findsOneWidget);
  });

  testWidgets('实时字数：位于模型名正下方、右边界与模型名对齐，字号更小', (tester) async {
    await pumpChatScreen(tester, bookDao: FakeBookDao(books: [book]));

    final labelRect = tester.getRect(modelLabel());
    final countRect = tester.getRect(find.byType(CharCountIndicator));

    // 竖向两行：模型名在上、字数在下，两行贴合（不做「隔一行」的松间距）。
    expect(countRect.top - labelRect.bottom, lessThanOrEqualTo(4));
    // 右边界与模型名严格对齐（不再对齐到 ▾ 图标或热区外沿）。
    expect(countRect.right, closeTo(labelRect.right, 0.01));
    // 不越到发送按钮上（与按钮保持 8px 间距）。
    expect(tester.getRect(sendButton()).left - countRect.right, greaterThanOrEqualTo(8));

    // 字号层级：字数小于模型名。
    final labelSize = tester.widget<Text>(modelLabel()).style!.fontSize!;
    final countSize = tester.widget<Text>(charCountText()).style!.fontSize!;
    expect(countSize, lessThan(labelSize));
  });

  testWidgets('实时字数：点击字数即展开模型选择器下拉菜单', (tester) async {
    await pumpChatScreen(tester, bookDao: FakeBookDao(books: [book]));

    // 字数属于模型选择器热区：点它应弹出模型菜单（而非无响应）。
    await tester.tap(find.byType(CharCountIndicator));
    await tester.pumpAndSettle();

    expect(find.text('deepseek-v4-pro'), findsWidgets);
  });

  testWidgets('实时字数：位数增长既不推动控件行，也不挤占模型名', (tester) async {
    await pumpChatScreen(tester, bookDao: FakeBookDao(books: [book]));

    final sendLeft = tester.getTopLeft(sendButton()).dx;
    final labelWidth = tester.getSize(modelLabel()).width;

    await tester.enterText(composerField(), 'x' * 1234);
    await tester.pump();
    expect(charCount('1,234 字'), findsOneWidget);

    // 千分位长数字出现后：发送按钮不位移，模型名宽度不被挤占。
    expect(tester.getTopLeft(sendButton()).dx, sendLeft);
    expect(tester.getSize(modelLabel()).width, labelWidth);
  });

  testWidgets('实时字数：两行小字不额外撑高底部控件行', (tester) async {
    await pumpChatScreen(tester, bookDao: FakeBookDao(books: [book]));

    await tester.enterText(composerField(), 'x' * 1234);
    await tester.pump();

    // 控件行高度与 36px 的发送按钮持平（两行文字靠紧行高塞进原有一行的高度）。
    final rowHeight = tester.getSize(controlRow()).height;
    final sendHeight = tester.getSize(sendButton()).height;
    expect(sendHeight, 36);
    expect(rowHeight - sendHeight, lessThan(2));
  });

  testWidgets('实时字数：窄屏（360 宽）下不挤占模型名且不溢出', (tester) async {
    await pumpChatScreen(
      tester,
      bookDao: FakeBookDao(books: [book]),
      size: const Size(360, 740),
    );

    // 窄屏正是此前「模型名被字数挤死」的场景：先记录无输入时的模型名宽度。
    expect(modelLabel(), findsOneWidget);
    final labelWidth = tester.getSize(modelLabel()).width;

    await tester.enterText(composerField(), 'x' * 1234);
    await tester.pump();

    expect(charCount('1,234 字'), findsOneWidget);
    // 字数另起一行后，模型名宽度不随字数位数变化（不再被横向争抢）。
    expect(tester.getSize(modelLabel()).width, labelWidth);
    expect(tester.takeException(), isNull);
  });
}
