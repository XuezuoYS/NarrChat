import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/screens/chat_screen.dart';
import 'package:narrchat/widgets/quick_scroll_rail.dart';
import 'package:narrchat/widgets/sidebar_panel.dart';

import 'helpers/chat_harness.dart';
import 'helpers/fakes.dart';

/// 对话页右侧栏 快速定位滚动导轨（QuickScrollRail）集成测试。
///
/// 覆盖：侧栏原生滚动条被替换 / 目录条目（区块 + 分组 + 角色名）/
/// 角色状态折叠后角色名条目消失 / 拖动拇指滚动到底且当前标题 = 末条。
///
/// 测试数据让角色状态占据可观的文档长度（而非被超长的世界状态压成末尾
/// 一小簇）：目录条目沿文档均匀分布，便于断言可见带与当前条目。
String _charState() {
  final attrs = List.generate(14, (i) => '- 属性$i：值$i').join('\n');
  return '# 主角\n- 类别说明段落\n## 陆尘\n$attrs\n## 苏清月\n$attrs\n';
}

/// 多角色真机形态：两个一级类别 + 10 名角色（各 14 行属性），
/// 用于验证「拖动到中部/任意位置时完整目录可见」与钳制。
String _manyCharState() {
  final attrs = List.generate(12, (i) => '- 属性$i：值$i').join('\n');
  const chars = [
    '唐小棠', '苏浅浅', '冷逍', '明千言', '林小优',
    '周银', '王浩', '林语柔', '陈雨桐', '鬼影',
  ];
  final buf = StringBuffer('# 主角\n- 类别说明\n');
  for (final c in chars) {
    buf.writeln('## $c');
    buf.writeln(attrs);
  }
  buf.writeln('# NPC\n- 类别说明\n## 路人甲\n$attrs');
  return buf.toString();
}

Finder _overlay() => find.byKey(const Key('quick_scroll_rail_overlay'));

Finder _strip() => find.byKey(const Key('quick_scroll_rail_strip'));

Finder _inOverlay(String text) =>
    find.descendant(of: _overlay(), matching: find.text(text));

Future<void> _pumpSidebar(WidgetTester tester) async {
  final dao = FakeRoundDao();
  await dao.insertRound(
    Round(
      bookUuid: kHarnessBookUuid,
      roundIndex: 1,
      userInput: '开始',
      aiNarrative: '正文。',
      currentTime: '第一天 午时',
      worldState: '世界状态详情描述。\n\n' * 40,
      characterState: _charState(),
      memorySummary: '- 第1轮｜第一天｜开局',
      createdAt: DateTime.now(),
    ),
  );
  await pumpChatScreen(tester, roundDao: dao, seedRounds: 0);
}

/// 侧栏 CustomScrollView 的控制器（与导轨共用，私有持有但经 widget 暴露）。
ScrollController _sidebarController(WidgetTester tester) {
  final csv = tester.widget<CustomScrollView>(
    find.descendant(
      of: find.byType(SidebarPanel),
      matching: find.byType(CustomScrollView),
    ),
  );
  return csv.controller!;
}

/// 在导轨上按住一次「拖动态」（可传 [move] 在按住期间移动），执行 [body] 后松开。
Future<void> _dragSession(
  WidgetTester tester, {
  Offset? move,
  required Future<void> Function(TestGesture gesture) body,
}) async {
  final strip = _strip();
  final size = tester.getSize(strip);
  final topLeft = tester.getTopLeft(strip);
  final gesture = await tester.startGesture(
    topLeft + Offset(size.width / 2, 80),
    kind: PointerDeviceKind.mouse,
  );
  await tester.pump();
  if (move != null) {
    await gesture.moveTo(topLeft + Offset(size.width / 2, move.dy));
    await tester.pump();
  }
  await body(gesture);
  await gesture.up();
  await tester.pump();
}

void main() {
  testWidgets('侧栏子树无原生滚动条，快速定位导轨接管', (tester) async {
    await _pumpSidebar(tester);
    expect(find.byType(SidebarPanel), findsOneWidget);
    expect(find.byType(QuickScrollRail), findsOneWidget);
    final sidebar = find.byType(SidebarPanel);
    expect(
      find.descendant(of: sidebar, matching: find.byType(Scrollbar)),
      findsNothing,
    );
    expect(
      find.descendant(of: sidebar, matching: find.byType(RawScrollbar)),
      findsNothing,
    );
  });

  testWidgets('目录条目：4 区块 + 角色状态内 分组/角色名（最低级别 = 角色名）', (tester) async {
    await _pumpSidebar(tester);
    // 目录浮层仅在拖动中存在：按住导轨检查条目（地图模式 → 全高可见）。
    await _dragSession(tester, body: (gesture) async {
      expect(_inOverlay('当前时间'), findsOneWidget);
      expect(_inOverlay('世界状态'), findsOneWidget);
      expect(_inOverlay('角色状态'), findsOneWidget);
      expect(_inOverlay('记忆总结'), findsOneWidget);
      // 角色状态树（# 主角 为包装层被剥除）：角色名卡片即是目录最低级别。
      expect(_inOverlay('陆尘'), findsOneWidget);
      expect(_inOverlay('苏清月'), findsOneWidget);
    });
  });

  testWidgets('角色状态折叠 → 其内部角色名条目同步消失', (tester) async {
    await _pumpSidebar(tester);
    // 顶部可见带内：角色名条目在列。
    await _dragSession(tester, body: (gesture) async {
      expect(_inOverlay('陆尘'), findsOneWidget);
    });
    // 拖到底：角色状态标题栏进入视口顶部（吸顶标题栏是懒构建，视口外
    // 不会挂载元素，必须先滚到可见区才能点击）。
    await _dragSession(tester, move: const Offset(0, 1000000), body: (g) async {});
    await tester.tap(
      find
          .descendant(
            of: find.byType(SidebarPanel),
            matching: find.text('角色状态'),
          )
          .first,
    );
    await tester.pumpAndSettle();
    // 折叠后：角色名条目同步消失（未折叠时同为在列位置）。
    await _dragSession(tester, move: const Offset(0, 1000000), body: (g) async {
      expect(_inOverlay('陆尘'), findsNothing);
      expect(_inOverlay('苏清月'), findsNothing);
      // 区块本身仍是条目（折叠后仍可定位到区块头）。
      expect(_inOverlay('角色状态'), findsOneWidget);
    });
  });

  testWidgets('鼠标拖动拇指至底部：侧栏滚动到底，当前标题 = 最后条目（记忆总结）', (tester) async {
    await _pumpSidebar(tester);
    final controller = _sidebarController(tester);
    final maxExtent = controller.position.maxScrollExtent;
    expect(maxExtent, greaterThan(1000));

    await _dragSession(
      tester,
      move: const Offset(0, 1000000), // 超出轨道底 → 钳制到底
      body: (gesture) async {
        expect(controller.offset, closeTo(maxExtent, 1));
        final current = tester.widget<Text>(_inOverlay('记忆总结'));
        expect(current.style?.fontWeight, FontWeight.w700);
      },
    );
    // 松手：目录浮层立即移除。
    expect(_overlay(), findsNothing);
  });

  testWidgets('多角色真机形态：任意拖动位置完整目录都在浮层中', (tester) async {
    final dao = FakeRoundDao();
    await dao.insertRound(
      Round(
        bookUuid: kHarnessBookUuid,
        roundIndex: 18,
        userInput: '继续',
        aiNarrative: '正文。',
        currentTime: '第二天 午时',
        worldState: '世界状态大段描述。\n\n' * 80,
        characterState: _manyCharState(),
        memorySummary: '- 第18轮｜第二天｜推进剧情',
        createdAt: DateTime.now(),
      ),
    );
    await pumpChatScreen(tester, roundDao: dao, seedRounds: 0);

    // 拖到中部：目录（4 区块 + 类别 + 全部角色名）完整可见。
    const names = ['当前时间', '世界状态', '角色状态', '主角', 'NPC', '唐小棠',
      '苏浅浅', '明千言', '林小优', '周银', '王浩', '鬼影', '记忆总结'];
    await _dragSession(
      tester,
      move: const Offset(0, 400),
      body: (gesture) async {
        for (final n in names) {
          expect(_inOverlay(n), findsOneWidget, reason: '拖到中部应看到「$n」');
        }
      },
    );
  });

  testWidgets('拖动大幅度越出轨道边界仍钳制在 maxScrollExtent', (tester) async {
    final dao = FakeRoundDao();
    await dao.insertRound(
      Round(
        bookUuid: kHarnessBookUuid,
        roundIndex: 18,
        userInput: '继续',
        aiNarrative: '正文。',
        currentTime: '第二天 午时',
        worldState: '世界状态大段描述。\n\n' * 80,
        characterState: _manyCharState(),
        memorySummary: '- 第18轮｜第二天｜推进剧情',
        createdAt: DateTime.now(),
      ),
    );
    await pumpChatScreen(tester, roundDao: dao, seedRounds: 0);

    final controller = _sidebarController(tester);
    final maxExtent = controller.position.maxScrollExtent;
    final strip = _strip();
    final size = tester.getSize(strip);
    final topLeft = tester.getTopLeft(strip);
    final gesture = await tester.startGesture(
      topLeft + Offset(size.width / 2, 60),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveBy(const Offset(0, 5000)); // 远超出面板底部
    await tester.pump();

    expect(controller.offset, lessThanOrEqualTo(maxExtent + 0.001));
    expect(controller.offset, closeTo(maxExtent, 1));
    await gesture.up();
    await tester.pump();
  });

  testWidgets('窄屏（移动抽屉）同样接入导轨', (tester) async {
    final dao = FakeRoundDao();
    await dao.insertRound(
      Round(
        bookUuid: kHarnessBookUuid,
        roundIndex: 1,
        userInput: '开始',
        aiNarrative: '正文。',
        currentTime: '第一天 午时',
        worldState: '世界状态详情描述。\n\n' * 40,
        characterState: _charState(),
        memorySummary: '- 第1轮｜第一天｜开局',
        createdAt: DateTime.now(),
      ),
    );
    await pumpChatScreen(
      tester,
      roundDao: dao,
      seedRounds: 0,
      size: const Size(600, 900),
    );
    // 窄屏抽屉默认收起：导轨随侧栏（抽屉内）一并挂载但位于屏幕外。
    expect(find.byType(QuickScrollRail), findsOneWidget);
    // 打开抽屉（聊天区左滑）。
    await tester.fling(
      find.byType(ChatScreen),
      const Offset(-400, 0),
      1200,
    );
    await tester.pumpAndSettle();
    expect(find.byType(SidebarPanel), findsOneWidget);
    // 抽屉展开后导轨仍可用（宽度归抽屉右缘）。
    final railRect = tester.getRect(find.byType(QuickScrollRail));
    expect(railRect.right, closeTo(600, 1));
  });
}
