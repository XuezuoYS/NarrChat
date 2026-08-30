import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/markdown_collapsible_editor.dart';

/// 生成包含 [count] 个人物、每人 2 行属性的角色状态文本。
String _peopleText(int count) {
  final sb = StringBuffer('# 女主角\n');
  for (var i = 0; i < count; i++) {
    sb.writeln('## 角色$i');
    sb.writeln('- 属性A：值$i');
    sb.writeln('- 属性B：值$i');
  }
  return sb.toString();
}

/// 模拟真实点击（按下→停顿→抬起）。
///
/// 编辑器外层 GestureDetector 带有 onDoubleTap，若用 tester.tap 的
/// 瞬时「按下+抬起」事件，DoubleTap 识别器会在手势竞技场中抢占胜利，
/// 导致子级按钮/卡片的点击不触发（真实应用中时序正常，无此问题）。
/// 需在按下后停顿（超过双击判定间隔）再抬起，随后补一帧 + 推进动画时间，
/// 最后再 pumpAndSettle。
Future<void> realTap(WidgetTester tester, Finder finder) async {
  final gesture = await tester.startGesture(tester.getCenter(finder));
  await tester.pump(const Duration(milliseconds: 400));
  await gesture.up();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// 用于模拟父级重建（如流式更新触发侧栏重建）的宿主。
class _RebuildHost extends StatefulWidget {
  final TextEditingController controller;

  const _RebuildHost({required this.controller});

  @override
  State<_RebuildHost> createState() => _RebuildHostState();
}

class _RebuildHostState extends State<_RebuildHost> {
  int _epoch = 0;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TextButton(
          onPressed: () => setState(() => _epoch++),
          child: const Text('重建'),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: MarkdownCollapsibleEditor(controller: widget.controller),
          ),
        ),
      ],
    );
  }
}

void main() {
  testWidgets('角色卡片展开状态在父级重建后保持（不被重置回默认展开）', (tester) async {
    final controller = TextEditingController(text: _peopleText(3));
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: NarrChatTheme.light,
        home: Scaffold(body: _RebuildHost(controller: controller)),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 默认全部展开：属性内容可见。
    expect(find.textContaining('属性A：值0'), findsOneWidget);

    // 手动收起“角色0”卡片。
    await realTap(tester, find.text('角色0'));
    await tester.pumpAndSettle();
    expect(find.textContaining('属性A：值0'), findsNothing);

    // 父级重建（模拟流式更新等导致的侧栏重建）。
    await realTap(tester, find.text('重建'));
    await tester.pumpAndSettle();

    // 应保持收起，而不是被重置回展开。
    expect(find.textContaining('属性A：值0'), findsNothing);
    // 其它未手动操作的卡片仍保持展开。
    expect(find.textContaining('属性A：值1'), findsOneWidget);
  });

  testWidgets('一键展开 / 全部折叠 切换所有卡片', (tester) async {
    final controller = TextEditingController(text: _peopleText(3));
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: NarrChatTheme.light,
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: MarkdownCollapsibleEditor(controller: controller),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 初始：全部展开，按钮为「全部折叠」。
    expect(find.textContaining('属性A：值0'), findsOneWidget);
    expect(find.text('全部折叠'), findsOneWidget);

    // 全部折叠。
    await realTap(tester, find.text('全部折叠'));
    await tester.pumpAndSettle();
    expect(find.textContaining('属性A：值0'), findsNothing);
    expect(find.textContaining('属性A：值2'), findsNothing);
    expect(find.text('一键展开'), findsOneWidget);

    // 一键展开。
    await realTap(tester, find.text('一键展开'));
    await tester.pumpAndSettle();
    expect(find.textContaining('属性A：值0'), findsOneWidget);
    expect(find.textContaining('属性A：值2'), findsOneWidget);
    expect(find.text('全部折叠'), findsOneWidget);
  });

  testWidgets('showToolbar=false：编辑模式无内置「取消/完成」，取消丢弃修改', (tester) async {
    final controller = TextEditingController(text: '## 女主角\n### 苏清月\n- 心情：平静');
    addTearDown(controller.dispose);
    String? saved;
    final editingLog = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: NarrChatTheme.light,
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: MarkdownCollapsibleEditor(
              controller: controller,
              showToolbar: false,
              onSave: (v) => saved = v,
              onEditingChanged: editingLog.add,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final state = tester.state<MarkdownCollapsibleEditorState>(
      find.byType(MarkdownCollapsibleEditor),
    );
    state.enterEdit();
    await tester.pump();
    // 无工具栏时编辑框内不出现内置「取消/完成」（由外部标题栏驱动）。
    expect(find.text('取消'), findsNothing);
    expect(find.text('完成'), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
    await tester.enterText(
      find.byType(TextField),
      '## 女主角\n### 苏清月\n- 心情：愤怒',
    );
    state.cancel();
    await tester.pumpAndSettle();
    expect(saved, isNull);
    expect(controller.text, '## 女主角\n### 苏清月\n- 心情：平静');
    expect(editingLog, [true, false]);
  });

  testWidgets('全部折叠时滚动位置平滑跟随，不瞬移', (tester) async {
    final scrollController = ScrollController();
    final editorController = TextEditingController(text: _peopleText(12));
    addTearDown(scrollController.dispose);
    addTearDown(editorController.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: NarrChatTheme.light,
        home: Scaffold(
          body: SizedBox(
            width: 320,
            height: 500,
            child: ListView(
              controller: scrollController,
              padding: const EdgeInsets.all(12),
              children: [
                MarkdownCollapsibleEditor(controller: editorController),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 内容应足够高（可滚动）。
    expect(scrollController.position.maxScrollExtent, greaterThan(0));

    // 滚动到底部附近（模拟阅读全展开的角色信息深处）。
    scrollController.jumpTo(scrollController.position.maxScrollExtent);
    await tester.pump();
    final before = scrollController.offset;

    // 真实点击底部可见的最后一张人物卡片，将其收起。
    // （停顿须超过双击判定间隔，否则 DoubleTap 识别器会在竞技场中延迟/抢占点击）
    final gesture =
        await tester.startGesture(tester.getCenter(find.text('角色11')));
    await tester.pump(const Duration(milliseconds: 400));
    await gesture.up();

    // 动画首帧：内容高度尚未骤变，滚动偏移不应被瞬间钳制（否则即为“瞬移”）。
    await tester.pump();
    final afterTap = scrollController.offset;
    expect((afterTap - before).abs(), lessThan(50));

    // 动画完成后：偏移稳定在合法范围内（随内容平滑回落到底部）。
    await tester.pumpAndSettle();
    expect(
      scrollController.offset,
      lessThanOrEqualTo(scrollController.position.maxScrollExtent),
    );
    expect(find.textContaining('属性A：值11'), findsNothing);
  });
}
