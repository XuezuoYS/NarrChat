import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/chat/chat_locator.dart';
import 'package:narrchat/chat/chat_rail.dart';
import 'package:narrchat/chat/chat_rail_handle.dart';

/// 记录调用的定位器替身。
class _FakeLocator extends ChangeNotifier implements ChatLocator {
  _FakeLocator({
    this.currentRoundIndex = 3,
    this.maxRoundIndex = 10,
    this.visibleFraction = 0.2,
    this.viewportDimension = 600,
  });

  @override
  int? currentRoundIndex;

  @override
  double? progress = 0;

  @override
  double? visibleFraction;

  @override
  int? maxRoundIndex;

  @override
  double? viewportDimension;

  @override
  bool get isPinnedToBottom => true;

  final List<int> jumpedRounds = [];
  final List<double> velocities = [];
  int topCalls = 0;
  int bottomCalls = 0;
  int stopCalls = 0;
  int cancelJumpCalls = 0;

  @override
  Future<bool> jumpToRound(int roundIndex) async {
    jumpedRounds.add(roundIndex);
    return true;
  }

  @override
  Future<bool> jumpToTop() async {
    topCalls++;
    return true;
  }

  @override
  Future<bool> jumpToBottom() async {
    bottomCalls++;
    return true;
  }

  @override
  void scrollByVelocity(double viewportsPerSecond) =>
      velocities.add(viewportsPerSecond);

  @override
  void stopVelocity() => stopCalls++;

  @override
  void cancelPendingJump() => cancelJumpCalls++;

  @override
  void notifyGeometryChanged() => notifyListeners();
}

/// 把轨道放进一个固定尺寸的盒子里（滑块按父级高度居中）。
Future<_FakeLocator> _pumpRail(
  WidgetTester tester, {
  int totalRounds = 10,
  double visibleFraction = 0.2,
  int currentRound = 3,
  double viewportHeight = 600,
  bool isTouch = false,
  ChatRailHandle? handle,
}) async {
  final locator = _FakeLocator(
    currentRoundIndex: currentRound,
    maxRoundIndex: totalRounds,
    visibleFraction: visibleFraction,
    viewportDimension: viewportHeight,
  );
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.centerRight,
          child: SizedBox(
            width: 200,
            height: 600,
            child: ChatRail(
              locator: locator,
              handle: handle,
              isTouchPlatform: isTouch,
            ),
          ),
        ),
      ),
    ),
  );
  return locator;
}

void main() {
  group('可见性', () {
    testWidgets('内容不足一屏时不显示轨道', (tester) async {
      await _pumpRail(tester, visibleFraction: 1);
      expect(find.byKey(ChatRail.trackKey), findsNothing);
    });

    testWidgets('只有一轮时不显示轨道', (tester) async {
      await _pumpRail(tester, totalRounds: 1);
      expect(find.byKey(ChatRail.trackKey), findsNothing);
    });

    testWidgets('可滚动时显示滑块', (tester) async {
      await _pumpRail(tester);
      expect(find.byKey(ChatRail.trackKey), findsOneWidget);
    });
  });

  group('面板', () {
    testWidgets('默认收起：点轨道才展开', (tester) async {
      await _pumpRail(tester);
      expect(find.byTooltip('顶部'), findsNothing);
      await tester.tap(find.byKey(ChatRail.trackKey));
      await tester.pumpAndSettle();
      expect(find.byTooltip('顶部'), findsOneWidget);
      expect(find.byTooltip('底部'), findsOneWidget);
      expect(find.byTooltip('上一轮'), findsOneWidget);
      expect(find.byTooltip('下一轮'), findsOneWidget);
    });

    testWidgets('再点轨道收起', (tester) async {
      await _pumpRail(tester);
      await tester.tap(find.byKey(ChatRail.trackKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ChatRail.trackKey));
      await tester.pumpAndSettle();
      expect(find.byTooltip('顶部'), findsNothing);
    });

    testWidgets('胶囊显示 当前轮 / 总轮数', (tester) async {
      await _pumpRail(tester, currentRound: 3, totalRounds: 10);
      await tester.tap(find.byKey(ChatRail.trackKey));
      await tester.pumpAndSettle();
      expect(find.textContaining('3 / 10', findRichText: true), findsOneWidget);
    });

    testWidgets('外部开关可收起（点消息区 / Esc 走这个入口）', (tester) async {
      final handle = ChatRailHandle();
      addTearDown(handle.dispose);
      await _pumpRail(tester, handle: handle);

      await tester.tap(find.byKey(ChatRail.trackKey));
      await tester.pumpAndSettle();
      expect(find.byTooltip('顶部'), findsOneWidget);
      expect(handle.expanded, isTrue, reason: '轨道自己的开合也要回写同一个开关');

      handle.collapse();
      await tester.pumpAndSettle();
      expect(find.byTooltip('顶部'), findsNothing);
    });

    testWidgets('外部开关可展开', (tester) async {
      final handle = ChatRailHandle();
      addTearDown(handle.dispose);
      await _pumpRail(tester, handle: handle);
      expect(find.byTooltip('顶部'), findsNothing);

      handle.expand();
      await tester.pumpAndSettle();
      expect(find.byTooltip('顶部'), findsOneWidget);
    });

    testWidgets('五个部件各自成形：右缘对齐滑块侧、纵向居中', (tester) async {
      await _pumpRail(tester);
      await tester.tap(find.byKey(ChatRail.trackKey));
      await tester.pumpAndSettle();

      final railBox = tester.getRect(find.byType(ChatRail));
      final top = tester.getRect(find.byTooltip('顶部'));
      final capsule = tester.getRect(
        find.ancestor(
          of: find.textContaining('3 / 10', findRichText: true),
          matching: find.byType(SizedBox),
        ).first,
      );

      // 部件右缘 = 父级右缘 -（内缩 + 命中带 + 间隙）；桌面内缩 8。
      final chipRight = railBox.right -
          (ChatRail.gutterDesktop + ChatRail.hitWidth + ChatRail.panelGap);
      expect(top.right, closeTo(chipRight, 0.5));
      expect(capsule.right, closeTo(chipRight, 0.5));

      // 圆形按钮 40、胶囊 120（页码要放得开）。
      expect(top.width, ChatRail.itemHeight);
      expect(capsule.width, ChatRail.capsuleWidth);
      expect(capsule.width, greaterThan(top.width * 2));

      // 五个部件总高 = 4 按钮 + 1 胶囊 + 4 间距，在 600 高的父级里居中。
      expect(top.top, closeTo((600 - ChatRail.panelHeight) / 2, 0.5));
    });

    testWidgets('没有包裹五个部件的大面板（每个部件自带 Material）', (tester) async {
      await _pumpRail(tester);
      await tester.tap(find.byKey(ChatRail.trackKey));
      await tester.pumpAndSettle();

      for (final tooltip in ['顶部', '上一轮', '下一轮', '底部']) {
        expect(
          find.descendant(
            of: find.byTooltip(tooltip),
            matching: find.byType(Material),
          ),
          findsOneWidget,
          reason: '$tooltip 自己有一层 Material（底色 + 形状 + 阴影）',
        );
      }
    });
  });

  group('滑块', () {
    testWidgets('滑块钉在垂直中央，且是小胶囊（不是整条滚动条）', (tester) async {
      await _pumpRail(tester);

      final knob = tester.getRect(find.byKey(ChatRail.knobKey));
      expect(knob.center.dy, closeTo(300, 0.5), reason: '垂直居中');
      expect(knob.width, greaterThanOrEqualTo(ChatRail.knobWidth));
      expect(knob.height, ChatRail.knobHeight);
      // 不再是"整条竖条"：高度远小于父级高度。
      expect(knob.height, lessThan(600 / 4));
    });

    testWidgets('拖动时滑块跟着手指走', (tester) async {
      final locator = await _pumpRail(tester);
      final knob = find.byKey(ChatRail.knobKey);
      final start = tester.getCenter(knob);

      final gesture = await tester.startGesture(start);
      await tester.pump();
      // 第一段位移用于越过拖拽判定阈值（框架把它算进"起点"），之后才是跟手。
      await gesture.moveBy(const Offset(0, -40));
      await tester.pump();
      await gesture.moveBy(const Offset(0, -40));
      await tester.pump();

      expect(
        tester.getRect(knob).center.dy,
        closeTo(start.dy - 80, 0.5),
        reason: '滑块跟手（按绝对位置算，不丢前半段位移）',
      );
      expect(locator.velocities, isNotEmpty);
      expect(locator.velocities.last, greaterThan(0), reason: '往上拖 = 往历史翻');

      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('松手弹回中央并停止滚动', (tester) async {
      final locator = await _pumpRail(tester);
      final knob = find.byKey(ChatRail.knobKey);
      final start = tester.getCenter(knob);

      final gesture = await tester.startGesture(start);
      await gesture.moveBy(const Offset(0, 45));
      await tester.pump();
      await gesture.moveBy(const Offset(0, 45));
      await tester.pump();
      expect(tester.getRect(knob).center.dy, closeTo(start.dy + 90, 0.5));

      await gesture.up();
      await tester.pumpAndSettle();

      expect(
        tester.getRect(knob).center.dy,
        closeTo(start.dy, 0.5),
        reason: '松手回中',
      );
      expect(locator.stopCalls, greaterThan(0));
    });

    testWidgets('拖动超出行程被夹住（不会跑到屏幕外）', (tester) async {
      await _pumpRail(tester);
      final knob = find.byKey(ChatRail.knobKey);
      final start = tester.getCenter(knob);

      final gesture = await tester.startGesture(start);
      await gesture.moveBy(const Offset(0, -300));
      await tester.pump();
      await gesture.moveBy(const Offset(0, -300));
      await tester.pump();

      expect(
        tester.getRect(knob).center.dy,
        closeTo(start.dy - ChatRail.knobMaxTravel, 0.5),
      );

      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('收起态拖动弹出跟随滑块的页码胶囊', (tester) async {
      await _pumpRail(tester);
      expect(find.textContaining('3 / 10', findRichText: true), findsNothing);

      final gesture =
          await tester.startGesture(tester.getCenter(find.byKey(ChatRail.knobKey)));
      await gesture.moveBy(const Offset(0, -30));
      await tester.pump();
      await gesture.moveBy(const Offset(0, -30));
      await tester.pump();

      expect(
        find.textContaining('3 / 10', findRichText: true),
        findsOneWidget,
        reason: '收起态拖动时只弹中间胶囊',
      );
      expect(find.byTooltip('顶部'), findsNothing, reason: '不展开五个部件');

      await gesture.up();
      // 胶囊停留 1.2s 后淡出（计时器收敛，避免测试结束残留）。
      await tester.pump(const Duration(milliseconds: 1500));
      await tester.pumpAndSettle();
      expect(find.textContaining('3 / 10', findRichText: true), findsNothing);
    });
  });

  group('跳转按钮', () {
    testWidgets('顶部 / 底部', (tester) async {
      final locator = await _pumpRail(tester);
      await tester.tap(find.byKey(ChatRail.trackKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('顶部'));
      await tester.tap(find.byTooltip('底部'));
      expect(locator.topCalls, 1);
      expect(locator.bottomCalls, 1);
    });

    testWidgets('上一轮 / 下一轮跳到相邻轮', (tester) async {
      final locator = await _pumpRail(tester, currentRound: 5);
      await tester.tap(find.byKey(ChatRail.trackKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('上一轮'));
      await tester.tap(find.byTooltip('下一轮'));
      expect(locator.jumpedRounds, [4, 6]);
    });

    testWidgets('第一轮的上一轮 = 顶部', (tester) async {
      final locator = await _pumpRail(tester, currentRound: 1);
      await tester.tap(find.byKey(ChatRail.trackKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('上一轮'));
      expect(locator.topCalls, 1);
      expect(locator.jumpedRounds, isEmpty);
    });

    testWidgets('最后一轮的下一轮 = 底部', (tester) async {
      final locator = await _pumpRail(tester, currentRound: 10, totalRounds: 10);
      await tester.tap(find.byKey(ChatRail.trackKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('下一轮'));
      expect(locator.bottomCalls, 1);
    });
  });

  group('数字跳转', () {
    testWidgets('点数字进内联输入，回车跳到该轮', (tester) async {
      final locator = await _pumpRail(tester);
      await tester.tap(find.byKey(ChatRail.trackKey));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('3 / 10', findRichText: true));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(find.byType(TextField), '7');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(locator.jumpedRounds, [7]);
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('越界输入被夹取到上限，不报错', (tester) async {
      final locator = await _pumpRail(tester);
      await tester.tap(find.byKey(ChatRail.trackKey));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('3 / 10', findRichText: true));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '99');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(locator.jumpedRounds, [10]);
    });

    testWidgets('非法输入（非数字）不跳转', (tester) async {
      final locator = await _pumpRail(tester);
      await tester.tap(find.byKey(ChatRail.trackKey));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('3 / 10', findRichText: true));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'abc');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(locator.jumpedRounds, isEmpty);
      expect(find.byType(TextField), findsNothing);
    });
  });

  group('拖动 → 速度', () {
    testWidgets('向上拖产生正速度（往历史翻），松手立即停', (tester) async {
      final locator = await _pumpRail(tester);
      await tester.drag(find.byKey(ChatRail.trackKey), const Offset(0, -120));
      await tester.pumpAndSettle();
      expect(locator.velocities, isNotEmpty);
      expect(locator.velocities.last, isNot(0));
      expect(locator.velocities.every((v) => v >= 0), isTrue);
      expect(locator.stopCalls, greaterThan(0));
    });

    testWidgets('向下拖产生负速度（往最新翻）', (tester) async {
      final locator = await _pumpRail(tester);
      await tester.drag(find.byKey(ChatRail.trackKey), const Offset(0, 120));
      await tester.pumpAndSettle();
      expect(locator.velocities, isNotEmpty);
      expect(locator.velocities.every((v) => v <= 0), isTrue);
    });

    testWidgets('拖动后收缩，不再继续调用速度', (tester) async {
      final locator = await _pumpRail(tester);
      await tester.drag(find.byKey(ChatRail.trackKey), const Offset(0, -120));
      await tester.pumpAndSettle();
      final count = locator.velocities.length;
      expect(count, greaterThan(0));
      expect(locator.stopCalls, greaterThan(0));
    });
  });
}
