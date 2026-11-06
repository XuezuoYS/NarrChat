import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/chat/chat_locator.dart';
import 'package:narrchat/chat/chat_rail.dart';

/// 记录调用的定位器替身。
class _FakeLocator extends ChangeNotifier implements ChatLocator {
  _FakeLocator({this.currentRoundIndex = 3});

  @override
  int? currentRoundIndex;

  @override
  double? progress = 0;

  final List<int> jumpedRounds = [];
  final List<double> velocities = [];
  int topCalls = 0;
  int bottomCalls = 0;
  int stopCalls = 0;

  @override
  Future<void> jumpToRound(int roundIndex) async => jumpedRounds.add(roundIndex);

  @override
  Future<void> jumpToTop() async => topCalls++;

  @override
  Future<void> jumpToBottom() async => bottomCalls++;

  @override
  void scrollByVelocity(double viewportsPerSecond) =>
      velocities.add(viewportsPerSecond);

  @override
  void stopVelocity() => stopCalls++;
}

/// 把轨道放进一个固定尺寸的盒子里（轨道按父级高度算拇指）。
Future<_FakeLocator> _pumpRail(
  WidgetTester tester, {
  int totalRounds = 10,
  double visibleFraction = 0.2,
  int currentRound = 3,
  double viewportHeight = 600,
  bool isTouch = false,
}) async {
  final locator = _FakeLocator(currentRoundIndex: currentRound);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.centerRight,
          child: SizedBox(
            width: 180,
            height: 600,
            child: ChatRail(
              locator: locator,
              totalRounds: totalRounds,
              viewportHeight: viewportHeight,
              visibleFraction: visibleFraction,
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

    testWidgets('可滚动时显示轨道与拇指', (tester) async {
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
      expect(find.text('3 / 10'), findsOneWidget);
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
      await tester.tap(find.text('3 / 10'));
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
      await tester.tap(find.text('3 / 10'));
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
      await tester.tap(find.text('3 / 10'));
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
