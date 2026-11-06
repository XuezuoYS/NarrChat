import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/chat/chat_rail.dart';
import 'package:narrchat/widgets/narr_chat_scrollbar.dart';

import 'helpers/chat_harness.dart';

/// 对话页集成：右侧定位轨**真的接在页面上**。
///
/// 组件本身的行为见 `chat_rail_test.dart`（手工喂参数）；这里守接线：
/// - 比例口径没算反（历史 bug：`总高/视口` 是反比，所有超过一屏的书都不显示轨道）；
/// - 内容不足一屏时不渲染；
/// - 胶囊读得到最大轮号；
/// - 收起入口（Esc / 点消息区）真的接到轨道；
/// - chat 列表对全局滚动条豁免（否则和轨道抢右缘命中带）。
void main() {
  testWidgets('内容超过一屏：轨道可见，点开出现面板与胶囊', (tester) async {
    await pumpChatScreen(tester, seedRounds: 10, seedBodyRepeats: 1);
    await settle(tester);

    expect(find.byKey(const Key('chat_rail_area')), findsOneWidget);
    expect(find.byKey(ChatRail.trackKey), findsOneWidget,
        reason: '10 轮内容远高于一屏，轨道必须可见（反比口径会让它整条消失）');

    await tester.tap(find.byKey(ChatRail.trackKey));
    await tester.pumpAndSettle();

    expect(find.byTooltip('顶部'), findsOneWidget);
    expect(find.byTooltip('底部'), findsOneWidget);
    expect(
      find.textContaining('/ 10', findRichText: true),
      findsOneWidget,
      reason: '胶囊显示「当前轮 / 最大轮号」',
    );
  });

  testWidgets('内容不足一屏：不渲染轨道', (tester) async {
    await pumpChatScreen(tester, seedRounds: 1, seedBodyRepeats: 1);
    await settle(tester);

    expect(find.byKey(ChatRail.trackKey), findsNothing,
        reason: '一屏装得下就不需要定位轨');
  });

  testWidgets('只有一轮：不渲染轨道（没有可跳转的目标）', (tester) async {
    await pumpChatScreen(tester, seedRounds: 1, seedBodyRepeats: 200);
    await settle(tester);

    expect(find.byKey(ChatRail.trackKey), findsNothing);
  });

  testWidgets('Esc 收起已展开的面板', (tester) async {
    await pumpChatScreen(tester, seedRounds: 10, seedBodyRepeats: 1);
    await settle(tester);

    await tester.tap(find.byKey(ChatRail.trackKey));
    await tester.pumpAndSettle();
    expect(find.byTooltip('顶部'), findsOneWidget);

    // 真实使用中焦点通常落在输入框；Esc 从那里冒泡到页面级快捷键。
    await tester.tap(find.byType(TextField).first);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.byTooltip('顶部'), findsNothing, reason: 'Esc 收起面板');
  });

  testWidgets('点消息区任意处收起面板', (tester) async {
    await pumpChatScreen(tester, seedRounds: 10, seedBodyRepeats: 1);
    await settle(tester);

    await tester.tap(find.byKey(ChatRail.trackKey));
    await tester.pumpAndSettle();
    expect(find.byTooltip('顶部'), findsOneWidget);

    final area = tester.getRect(find.byKey(const Key('chat_messages_area')));
    await tester.tapAt(area.center);
    await tester.pumpAndSettle();

    expect(find.byTooltip('顶部'), findsNothing, reason: '点消息区收起面板');
  });

  testWidgets('轨道跳「顶部」：第 1 轮滚到视口顶附近', (tester) async {
    await pumpChatScreen(tester, seedRounds: 10, seedBodyRepeats: 2);
    await settle(tester);

    final first = find.text('第 1 轮的用户输入');
    expect(first, findsNothing, reason: '贴底时第 1 轮远在视口上方（未构建）');

    await tester.tap(find.byKey(ChatRail.trackKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('顶部'));
    await settle(tester);

    expect(first, findsOneWidget, reason: '跳到顶部后第 1 轮被建出来');
    final gap = tester.getTopLeft(first).dy -
        tester.getTopLeft(find.byType(ListView)).dy;
    expect(gap, greaterThanOrEqualTo(-1));
    expect(gap, lessThanOrEqualTo(24 + 15),
        reason: '顶部留白 24dp 是条目，第 1 轮顶边落在它下面');
  });

  testWidgets('窄屏：输入面板最右按钮不被轨道命中带压住', (tester) async {
    await pumpChatScreen(
      tester,
      seedRounds: 10,
      seedBodyRepeats: 1,
      size: const Size(600, 900),
    );
    await settle(tester);

    final rail = find.byKey(ChatRail.trackKey);
    expect(rail, findsOneWidget);
    final band = tester.getRect(rail);
    final sidebarButton = tester.getRect(find.byTooltip('打开右侧边栏'));
    expect(
      sidebarButton.right,
      lessThanOrEqualTo(band.left + 0.5),
      reason: '轨道命中带在触控端贴右缘 20..44dp，按钮行必须让开它',
    );
  });

  testWidgets('chat 列表对全局滚动条豁免（其它页面照旧）', (tester) async {
    await pumpChatScreen(tester, seedRounds: 10, seedBodyRepeats: 1);
    await settle(tester);

    // 其它页面在 Windows 上确实会被加上自绘滚动条（这是全局行为）。
    expect(
      NarrChatScrollBehavior.shouldShowScrollbar(
        direction: AxisDirection.up,
        platform: TargetPlatform.windows,
      ),
      isTrue,
    );

    // chat 列表自己关掉了滚动条：装上的行为必须原样返回子节点。
    final listContext = tester.element(find.byType(ListView));
    final behavior = ScrollConfiguration.of(listContext);
    final probe = const SizedBox.shrink(key: Key('scrollbar-probe'));
    const details = ScrollableDetails(direction: AxisDirection.up);
    expect(
      behavior.buildScrollbar(listContext, probe, details),
      same(probe),
      reason: '对话列表的滚动条就是右侧定位轨，不能两条同时出现',
    );
  });
}
