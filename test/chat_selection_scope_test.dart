import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/widgets/chat_bubble.dart';

import 'helpers/chat_harness.dart';
import 'helpers/selection_harness.dart';

/// 对话页「统一选中作用域」契约：整个消息列只有**一个** [SelectionArea]，
/// 且它建在列表**外**（气泡内不再自建区域）。
///
/// 为什么必须这样：框架里两个 `SelectableRegion` 互为硬边界
/// （`widgets/selectable_region.dart:189-192`：父区域选不进子区域、子区域也
/// 选不出去），而改造前**每个气泡自带 2 个区域**（正文 + 推荐行动），浏览器
/// 语义上「跨气泡连续选中」永远不可能。收敛为列表外一个之后：
/// - 拖动选区可以跨气泡延续（见下方跨气泡用例）；
/// - 气泡 / 思考框 / 推荐行动等子组件无需感知作用域（`SelectableTextArea`
///   作用域内自动让位）。
///
/// 选中结果以系统剪贴板为外部锚点读取（见 `helpers/selection_harness.dart`）。

/// 预置两轮（正文各 1 段，保证四条气泡同屏可见）。
Future<void> pumpTwoRounds(WidgetTester tester) async {
  await pumpChatScreen(tester, seedRounds: 2, seedBodyRepeats: 1);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('消息列只有一个选中区域，且不在气泡 / 输入面板内', (tester) async {
    await pumpTwoRounds(tester);

    expect(find.byType(ChatBubble), findsNWidgets(4), reason: '两轮 = 四条气泡');
    expect(find.byType(SelectionArea), findsOneWidget);
    expect(find.byType(SelectableRegion), findsOneWidget);
    // 唯一区域位于消息列内（而非输入面板或侧边栏）。
    expect(
      find.descendant(
        of: find.byKey(const Key('chat_messages_area')),
        matching: find.byType(SelectableRegion),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('chat_composer_area')),
        matching: find.byType(SelectableRegion),
      ),
      findsNothing,
      reason: '输入面板不在作用域内（TextField 自带一套选区）',
    );
    // 子项不再自建区域（改造前每个气泡 2 个）。
    expect(
      find.descendant(
        of: find.byType(ChatBubble),
        matching: find.byType(SelectableRegion),
      ),
      findsNothing,
    );
  });

  testWidgets('唯一区域是各气泡正文的共同祖先（跨气泡选中的前提）', (tester) async {
    await pumpTwoRounds(tester);

    for (final text in const [
      '第 1 轮的用户输入',
      '第 1 轮的剧情正文。',
      '第 2 轮的用户输入',
      '第 2 轮的剧情正文。',
    ]) {
      expect(
        find.ancestor(
          of: find.text(text),
          matching: find.byType(SelectableRegion),
        ),
        findsOneWidget,
        reason: '$text 应位于统一区域内',
      );
    }
  });

  testWidgets('鼠标拖动可跨气泡连续选中并复制（改造前选区止于气泡边界）', (tester) async {
    final copied = mockClipboard(tester);
    await pumpTwoRounds(tester);

    // 第 1 轮用户气泡 → 同轮 AI 气泡正文（相邻两条；终点取正文「正文」二字
    // 之后，保证选区确实跨进了下一条气泡的正文）。
    final start = textOffsetToPosition(tester, '第 1 轮的用户输入', 2);
    final end = textOffsetToPosition(tester, '第 1 轮的剧情正文。', 10);
    final gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    addTearDown(gesture.removePointer);
    await tester.pump();
    await gesture.moveTo(end);
    await tester.pump();
    await gesture.up();
    await tester.pump();

    copySelection(tester, find.text('第 1 轮的用户输入'));
    await tester.pump();

    expect(copied, hasLength(1), reason: '拖动应产生可复制的选中内容');
    expect(copied.single, contains('用户输入'));
    expect(
      copied.single,
      contains('剧情正文'),
      reason: '同一区域内可直接选进下一条气泡（改造前被区域边界截断）',
    );
  });

  testWidgets('窄屏：鼠标横向拖动仍能选中正文（抽屉滑动只认触屏）', (tester) async {
    // 窄屏布局由「聊天区左滑」打开右侧抽屉；该识别器若把鼠标也纳入，就会
    // 「什么都不做」地吃掉横向鼠标拖动——而横向拖动正是拖选正文的天然手势
    // （选中区域同样监听横向拖动）。故抽屉滑动限定触屏。
    final copied = mockClipboard(tester);
    await pumpChatScreen(
      tester,
      seedRounds: 1,
      seedBodyRepeats: 1,
      size: const Size(600, 900),
    );
    await tester.pumpAndSettle();

    final start = textOffsetToPosition(tester, '第 1 轮的用户输入', 2);
    final end = textOffsetToPosition(tester, '第 1 轮的用户输入', 8);
    expect(end.dy, start.dy, reason: '两点同行：这是一次纯横向拖动');
    final gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    addTearDown(gesture.removePointer);
    await tester.pump();
    await gesture.moveTo(end);
    await tester.pump();
    await gesture.up();
    await tester.pump();

    copySelection(tester, find.text('第 1 轮的用户输入'));
    await tester.pump();

    expect(copied, hasLength(1));
    expect(copied.single, contains('轮的用户'));
  });
}
