import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/plain_text_field_editor.dart';
import 'package:narrchat/widgets/sidebar_panel.dart';

import 'helpers/chat_harness.dart';
import 'helpers/fakes.dart';

/// 侧边栏顶栏轮次导航测试（模块：SidebarPanel 顶栏 + 跳转保持位置）。
///
/// 覆盖：
/// - 三个方形按钮（上一轮 / 下一轮 / 回到最新轮）常驻、几何一致、左→右顺序；
/// - 可用性由回调是否为空决定（无目标 → 置灰不响应）；
/// - 切换轮次：内容重置为新轮次快照、退出进行中的编辑、折叠状态与滚动位置保留；
/// - 对话页集成：点按钮跳转轮次后侧栏滚动位置不变（便于跨轮次对比）。

/// 三个导航按钮的 tooltip（左→右顺序）。
const List<String> _navTooltips = ['查看上一轮', '查看下一轮', '回到最新轮'];

/// 长内容轮次：世界状态足够长，保证侧栏可滚动。
///
/// [worldStateRepeats] 可调小（如 1），让四个子模块标题栏都留在视口内
/// （吸顶标题栏是懒构建，视口外不挂载）。
Round _round(int index, {int worldStateRepeats = 30}) => Round(
      id: index,
      bookUuid: kHarnessBookUuid,
      roundIndex: index,
      userInput: '第 $index 轮输入',
      aiNarrative: '第 $index 轮正文。',
      worldState: '第 $index 轮世界状态。\n\n' * worldStateRepeats,
      characterState: '## 角色$index\n- 属性：值$index',
      memorySummary: '- 第$index轮｜第$index天｜概括$index',
      currentTime: '第 $index 天 午时',
    );

/// 定位指定 tooltip 的导航按钮（[IconButton]）。
Finder _navButton(String tooltip) => find.descendant(
      of: find.byTooltip(tooltip),
      matching: find.byType(IconButton),
    );

/// 指定子模块的吸顶标题栏（【编辑】/【保存】/【取消】所在处）。
Finder _sectionHeader(String label) => find.ancestor(
      of: find.text(label),
      matching: find.byType(SliverPersistentHeader),
    );

/// 以 [round] 为初始轮次 pump 一个独立侧栏面板，返回可切换轮次的 notifier
/// （变更 value 即模拟父级换用另一轮次、复用同一 State）。
Future<ValueNotifier<Round?>> _pumpPanel(
  WidgetTester tester, {
  required Round? round,
  VoidCallback? onPreviousRound,
  VoidCallback? onNextRound,
  VoidCallback? onBackToCurrent,
  Future<bool> Function(Round round, String field, String value)? onSaveField,
}) async {
  final current = ValueNotifier<Round?>(round);
  await tester.pumpWidget(
    MaterialApp(
      theme: NarrChatTheme.light,
      home: Scaffold(
        body: SizedBox(
          width: 380,
          height: 500,
          child: ValueListenableBuilder<Round?>(
            valueListenable: current,
            builder: (context, value, _) => SidebarPanel(
              round: value,
              isHistoryView: false,
              onSaveField: onSaveField ?? (r, f, v) async => true,
              onPreviousRound: onPreviousRound,
              onNextRound: onNextRound,
              onBackToCurrent: onBackToCurrent,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return current;
}

void main() {
  testWidgets('顶栏常驻三个方形导航按钮：几何一致且左→右为上一轮/下一轮/回到最新轮', (tester) async {
    // 全部回调为空（无对应目标）时仍必须常驻。
    await _pumpPanel(tester, round: _round(1));

    for (final tooltip in _navTooltips) {
      expect(_navButton(tooltip), findsOneWidget, reason: '「$tooltip」应常驻');
    }
    // 方形：三个按钮宽高一致。
    final sizes = [for (final t in _navTooltips) tester.getSize(_navButton(t))];
    expect(sizes[0].width, sizes[0].height);
    expect(sizes.toSet().length, 1, reason: '三个按钮尺寸应完全一致');

    // 左→右顺序：上一轮 → 下一轮 → 回到最新轮。
    final lefts = [
      for (final t in _navTooltips) tester.getTopLeft(_navButton(t)).dx,
    ];
    expect(lefts[0], lessThan(lefts[1]));
    expect(lefts[1], lessThan(lefts[2]));

    // 无目标 → 三个按钮均置灰。
    for (final tooltip in _navTooltips) {
      expect(
        tester.widget<IconButton>(_navButton(tooltip)).onPressed,
        isNull,
        reason: '「$tooltip」无对应目标时应置灰',
      );
    }
  });

  testWidgets('按钮可用性由回调决定：可用时点击触发对应回调', (tester) async {
    var prev = 0;
    var next = 0;
    var back = 0;
    await _pumpPanel(
      tester,
      round: _round(1),
      onPreviousRound: () => prev++,
      onNextRound: () => next++,
      onBackToCurrent: () => back++,
    );

    for (final tooltip in _navTooltips) {
      expect(
        tester.widget<IconButton>(_navButton(tooltip)).onPressed,
        isNotNull,
      );
    }

    for (final tooltip in _navTooltips) {
      await tester.tap(_navButton(tooltip));
      await tester.pump();
    }
    expect([prev, next, back], [1, 1, 1]);
  });

  testWidgets('无目标（回调为空）的按钮置灰且不响应点击', (tester) async {
    var prev = 0;
    await _pumpPanel(tester, round: _round(1), onPreviousRound: () => prev++);

    expect(
      tester.widget<IconButton>(_navButton('查看上一轮')).onPressed,
      isNotNull,
    );
    expect(
      tester.widget<IconButton>(_navButton('查看下一轮')).onPressed,
      isNull,
    );
    expect(
      tester.widget<IconButton>(_navButton('回到最新轮')).onPressed,
      isNull,
    );

    await tester.tap(_navButton('查看下一轮'), warnIfMissed: false);
    await tester.pump();
    expect(prev, 0, reason: '置灰按钮不得触发任何导航');
  });

  testWidgets('切换轮次：内容重置为新轮次快照，折叠状态保留', (tester) async {
    // 短内容：四个吸顶标题栏（含「记忆总结」）都在视口内，可直接点击。
    final current = await _pumpPanel(
      tester,
      round: _round(1, worldStateRepeats: 1),
    );
    expect(find.text('第 1 天 午时'), findsOneWidget);

    // 折叠「记忆总结」。
    await tester.tap(find.text('记忆总结'));
    await tester.pumpAndSettle();
    expect(find.text('已折叠'), findsOneWidget);

    current.value = _round(2, worldStateRepeats: 1);
    await tester.pumpAndSettle();

    expect(find.text('第 1 天 午时'), findsNothing);
    expect(find.text('第 2 天 午时'), findsOneWidget);
    // 折叠状态跨轮次保留（同一 State 复用），便于在同一位置对比。
    expect(find.text('已折叠'), findsOneWidget);
  });

  testWidgets('编辑中切换轮次：退出编辑并丢弃未保存修改，不残留旧轮次内容', (tester) async {
    final saves = <(String, String)>[];
    final current = await _pumpPanel(
      tester,
      round: _round(1),
      onSaveField: (r, f, v) async {
        saves.add((f, v));
        return true;
      },
    );

    await tester.tap(
      find.descendant(
        of: _sectionHeader('当前时间'),
        matching: find.text('编辑'),
      ),
    );
    await tester.pumpAndSettle();
    final timeField = find.descendant(
      of: find.byType(PlainTextFieldEditor),
      matching: find.byType(TextField),
    );
    expect(timeField, findsOneWidget);
    await tester.enterText(timeField, '被丢弃的修改');

    current.value = _round(2);
    await tester.pumpAndSettle();

    // 未保存修改被丢弃：不写库、退出编辑、显示新轮次内容。
    expect(saves, isEmpty);
    expect(timeField, findsNothing);
    expect(find.text('被丢弃的修改'), findsNothing);
    expect(find.text('第 2 天 午时'), findsOneWidget);
    // 标题栏回到未编辑态（仅【编辑】）。
    expect(
      find.descendant(
        of: _sectionHeader('当前时间'),
        matching: find.text('取消'),
      ),
      findsNothing,
    );
  });

  testWidgets('切换轮次保留侧栏滚动位置（不回到顶部）', (tester) async {
    final current = await _pumpPanel(tester, round: _round(1));
    final controller = sidebarScrollController(tester);
    expect(controller.position.maxScrollExtent, greaterThan(300));

    controller.jumpTo(300);
    await tester.pump();
    expect(controller.offset, 300);

    current.value = _round(2);
    await tester.pumpAndSettle();
    expect(controller.offset, 300, reason: '跳转轮次后不得回到顶部');
  });

  testWidgets('大字号档位（+45%）下顶栏标题仍单行：自动缩放而非折行', (tester) async {
    final dao = FakeRoundDao();
    for (var i = 1; i <= 12; i++) {
      await dao.insertRound(_round(i));
    }
    await pumpChatScreen(
      tester,
      roundDao: dao,
      seedRounds: 0,
      textScale: 1.45,
    );

    // 标题段落按固有尺寸布局（高度 == 单行固有高度 → 未折行；宽度 == 固有
    // 宽度 → 轮次号未被截断），再由 FittedBox 整体缩放适配可用宽度。
    final title = find.text('当前轮次（第 12 轮）');
    final paragraph = tester.renderObject<RenderParagraph>(title);
    expect(
      paragraph.size.height,
      closeTo(paragraph.getMaxIntrinsicHeight(double.infinity), 0.01),
      reason: '大字号 + 三个导航按钮下标题不得折行',
    );
    expect(
      paragraph.size.width,
      closeTo(paragraph.getMaxIntrinsicWidth(double.infinity), 0.01),
      reason: '标题不得被截断（轮次号必须完整可见）',
    );
  });

  testWidgets('对话页集成：按钮跳转轮次并全程保持侧栏滚动位置', (tester) async {
    final dao = FakeRoundDao();
    for (var i = 1; i <= 3; i++) {
      await dao.insertRound(_round(i));
    }
    await pumpChatScreen(tester, roundDao: dao, seedRounds: 0);
    expect(find.text('当前轮次（第 3 轮）'), findsOneWidget);

    final controller = sidebarScrollController(tester);
    controller.jumpTo(300);
    await tester.pump();
    expect(controller.offset, 300);

    // 查看上一轮 → 第 2 轮（历史视图）。
    await tester.tap(_navButton('查看上一轮'));
    await tester.pumpAndSettle();
    expect(find.text('历史轮次（第 2 轮）'), findsOneWidget);
    expect(controller.offset, 300);

    // 再上一轮 → 第 1 轮；上一轮此时无目标（置灰）。
    await tester.tap(_navButton('查看上一轮'));
    await tester.pumpAndSettle();
    expect(find.text('历史轮次（第 1 轮）'), findsOneWidget);
    expect(controller.offset, 300);
    expect(
      tester.widget<IconButton>(_navButton('查看上一轮')).onPressed,
      isNull,
    );

    // 查看下一轮 → 第 2 轮。
    await tester.tap(_navButton('查看下一轮'));
    await tester.pumpAndSettle();
    expect(find.text('历史轮次（第 2 轮）'), findsOneWidget);
    expect(controller.offset, 300);

    // 回到最新轮 → 当前轮次（第 3 轮），位置仍保持。
    await tester.tap(_navButton('回到最新轮'));
    await tester.pumpAndSettle();
    expect(find.text('当前轮次（第 3 轮）'), findsOneWidget);
    expect(controller.offset, 300);
    expect(
      tester.widget<IconButton>(_navButton('查看下一轮')).onPressed,
      isNull,
    );
    expect(
      tester.widget<IconButton>(_navButton('回到最新轮')).onPressed,
      isNull,
    );

    // 另一条回到最新轮的路径：历史轮次下点「下一轮」逐轮前进，
    // 走到最后一轮即回到「当前轮次」视图。
    await tester.tap(_navButton('查看上一轮'));
    await tester.pumpAndSettle();
    expect(find.text('历史轮次（第 2 轮）'), findsOneWidget);
    await tester.tap(_navButton('查看下一轮'));
    await tester.pumpAndSettle();
    expect(find.text('当前轮次（第 3 轮）'), findsOneWidget);
    expect(controller.offset, 300, reason: '逐轮前进同样保持位置');
  });
}
