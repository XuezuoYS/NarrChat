import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/utils/memory_entry_format.dart';
import 'package:narrchat/widgets/sidebar_panel.dart';

import 'helpers/chat_harness.dart';
import 'helpers/fakes.dart';
import 'helpers/notice_harness.dart';

/// 对话页集成：侧栏记忆条目菜单「跳转至对应条目」真的把对话区滚到该轮起点。
///
/// 隔离层的菜单内容 / 复制行为 / 回调参数见 `memory_entry_menu_test.dart`；
/// 本文件只覆盖**跨层接线**（侧栏卡片 → ChatScreen 楼层跳转）与落点口径。
///
/// 侧栏默认展示**最新轮**的记忆总结，所以「跳到更早的轮次」的两条路径各测一条：
/// - 条目轮次早于当前轮（合并条目覆盖区间即属此列）；
/// - 先看历史轮次，再跳它自己的条目。

/// 三个长轮次：每轮正文都高于视口，保证前面轮次的起点在初始（贴底）状态下
/// 必然不在视口顶——跳转对齐断言才有意义。
const int _roundCount = 3;
const int _bodyRepeats = 200;

Future<void> _seedRounds(FakeRoundDao dao, {Map<int, String> memory = const {}}) async {
  for (var i = 1; i <= _roundCount; i++) {
    await dao.insertRound(
      Round(
        bookUuid: kHarnessBookUuid,
        roundIndex: i,
        userInput: '第 $i 轮的用户输入',
        aiNarrative: '第 $i 轮的剧情正文。' * _bodyRepeats,
        currentTime: '第 $i 天 午时',
        memorySummary: memory[i] ?? '- $i | 第 $i 天 午时 | 第 $i 轮概括。',
        createdAt: DateTime.now(),
      ),
    );
  }
}

/// 指定轮次用户气泡相对消息列表视口顶的偏差；该轮未构建时返回 null。
double? _roundTopGap(WidgetTester tester, int roundIndex) {
  final finder = find.text('第 $roundIndex 轮的用户输入');
  if (finder.evaluate().isEmpty) return null;
  return tester.getTopLeft(finder).dy -
      tester.getTopLeft(find.byType(ListView)).dy;
}

/// 断言「跳转发生前，[roundIndex] 的起点不在视口顶」。跳转生效后，
/// [_expectRoundStartAligned] 的对齐断言才真正证明是**跳转**把它带到了顶部。
void _expectNotAtTopBeforeJump(WidgetTester tester, int roundIndex) {
  final gap = _roundTopGap(tester, roundIndex);
  expect(gap == null || gap > 500, isTrue,
      reason: '跳转前第 $roundIndex 轮不应已在视口顶附近（实际 $gap）');
}

/// 断言 [roundIndex] 的起点已对齐视口顶（与楼层跳转同一判据）。
void _expectRoundStartAligned(WidgetTester tester, int roundIndex) {
  final top = tester.getTopLeft(find.text('第 $roundIndex 轮的用户输入')).dy;
  final listTop = tester.getTopLeft(find.byType(ListView)).dy;
  expect(top, greaterThanOrEqualTo(listTop - 1));
  expect(
    top,
    lessThanOrEqualTo(listTop + 15),
    reason: '第 $roundIndex 轮起点应对齐视口顶（实际偏差 ${top - listTop}px）',
  );
}

/// 长按侧栏记忆条目卡片的徽标 → 弹出菜单 → 选「跳转至对应条目」。
Future<void> _jumpFromEntry(WidgetTester tester, String badge) async {
  await tester.longPress(find.text(badge));
  await tester.pumpAndSettle();
  await tester.tap(find.text(kMemoryEntryJumpLabel));
  await tester.pumpAndSettle();
}

/// 侧栏顶栏【查看上一轮】按钮。
Finder _prevRoundButton() => find.descendant(
      of: find.byTooltip('查看上一轮'),
      matching: find.byType(IconButton),
    );

/// 窄屏：侧边栏抽屉当前是否已完全移出视口（抽屉宽 = 窗口宽 × 0.88）。
bool _drawerHidden(WidgetTester tester, double windowWidth) =>
    tester.getTopLeft(find.byType(SidebarPanel)).dx >= windowWidth - 1;

void main() {
  testWidgets('长按条目选「跳转至对应条目」：对话区滚到该轮起点', (tester) async {
    final dao = FakeRoundDao();
    // 最新轮（第 3 轮）的记忆总结里有合并条目 1~2。
    await _seedRounds(dao, memory: {
      3: '- 1~2 | 第一天 午时 ~ 第二天 午时 | 这两天的事。\n'
          '- 3 | 第三天 午时 | 第3轮概括。',
    });
    await pumpChatScreen(tester, roundDao: dao, seedRounds: 0);

    // 侧栏默认展示最新轮（第 3 轮）的记忆总结。
    expect(find.text('当前轮次（第 3 轮）'), findsOneWidget);
    _expectNotAtTopBeforeJump(tester, 1);

    // 该总结里的合并条目 1~2 覆盖更早的轮次：跳转落点 = 区间起始轮 1。
    await _jumpFromEntry(tester, '第1~2轮');

    _expectRoundStartAligned(tester, 1);
    await flushNotices(tester);
  });

  testWidgets('先看历史轮次再跳它的条目：定位到该轮起点，且侧栏仍在原轮次', (tester) async {
    final dao = FakeRoundDao();
    await _seedRounds(dao);
    await pumpChatScreen(tester, roundDao: dao, seedRounds: 0);

    // 侧栏从最新轮（第 3 轮）逐轮退回第 1 轮：此时显示第 1 轮自己的条目。
    await tester.tap(_prevRoundButton());
    await tester.pumpAndSettle();
    await tester.tap(_prevRoundButton());
    await tester.pumpAndSettle();
    expect(find.text('历史轮次（第 1 轮）'), findsOneWidget);

    _expectNotAtTopBeforeJump(tester, 1);

    await _jumpFromEntry(tester, '第1轮');

    _expectRoundStartAligned(tester, 1);
    // 跳转只动对话区：侧栏查看的轮次不受影响（仍是第 1 轮历史视图）。
    expect(find.text('历史轮次（第 1 轮）'), findsOneWidget);
    await flushNotices(tester);
  });

  testWidgets('条目轮次在对话中不存在时按「向下就近取整」落在前一轮', (tester) async {
    final dao = FakeRoundDao();
    await _seedRounds(dao, memory: {
      // 最新轮的条目轮次写成 5（对话里只有 1、2 轮）。
      2: '- 5 | 第五天 午时 | 第五轮概括。\n- 2 | 第二天 午时 | 第2轮概括。',
    });
    // 去掉第 3 轮：最新轮 = 第 2 轮，「第5轮」向下就近取整恰落在它身上。
    dao.rounds.removeWhere((r) => r.roundIndex == 3);
    await pumpChatScreen(tester, roundDao: dao, seedRounds: 0);

    expect(find.text('当前轮次（第 2 轮）'), findsOneWidget);
    _expectNotAtTopBeforeJump(tester, 1);

    await _jumpFromEntry(tester, '第5轮');

    // 没有第 5 轮 → 落在其前一轮（第 2 轮），不无声失败。
    _expectRoundStartAligned(tester, 2);
    await flushNotices(tester);
  });

  testWidgets('窄屏抽屉里跳转：对话区对齐该轮起点，且抽屉自动收起', (tester) async {
    const windowWidth = 600.0;
    final dao = FakeRoundDao();
    await _seedRounds(dao, memory: {
      1: '- 1 | 第一天 午时 | 第1轮概括。',
    });
    await pumpChatScreen(
      tester,
      roundDao: dao,
      seedRounds: 0,
      size: const Size(windowWidth, 900),
    );

    // 抽屉默认关闭：侧栏整体在视口右侧之外。
    expect(_drawerHidden(tester, windowWidth), isTrue, reason: '初始抽屉应为收起态');

    // 打开抽屉（输入面板上方的方形按钮），侧栏滑入。
    // 用 tooltip 定位：AI 气泡操作条上也有一枚同名图标（「查看侧边栏」）。
    await tester.tap(find.byTooltip('打开右侧边栏'));
    await tester.pumpAndSettle();
    expect(_drawerHidden(tester, windowWidth), isFalse);

    // 侧栏退到第 1 轮（历史视图），显示它自己的条目。
    await tester.tap(_prevRoundButton());
    await tester.pumpAndSettle();
    await tester.tap(_prevRoundButton());
    await tester.pumpAndSettle();
    expect(find.text('历史轮次（第 1 轮）'), findsOneWidget);
    _expectNotAtTopBeforeJump(tester, 1);

    await _jumpFromEntry(tester, '第1轮');

    // 跳转既对齐了对话区，也把抽屉收了起来（否则跳过去也被抽屉盖住）。
    _expectRoundStartAligned(tester, 1);
    expect(_drawerHidden(tester, windowWidth), isTrue, reason: '跳转后抽屉应收起');
    await flushNotices(tester);
  });
}
