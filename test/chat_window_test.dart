import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/chat/chat_window.dart';

/// 窗口层只做轮号范围决策，不认识几何/滚动，所以纯 `test()` 就能测。
void main() {
  group('首屏建窗', () {
    test('轮数足够时取最近 30 轮', () {
      final controller = ChatWindowController()
        ..initialize(totalRounds: 100);
      expect(controller.window, const ChatWindow(firstRoundIndex: 71, lastRoundIndex: 100));
      expect(controller.window!.roundCount, 30);
    });

    test('总轮数少于初始轮数时覆盖全书', () {
      final controller = ChatWindowController()
        ..initialize(totalRounds: 5);
      expect(controller.window, const ChatWindow(firstRoundIndex: 1, lastRoundIndex: 5));
      expect(controller.window!.includesHead(), isTrue);
      expect(controller.window!.includesTail(5), isTrue);
    });

    test('空书没有窗口', () {
      final controller = ChatWindowController()..initialize(totalRounds: 0);
      expect(controller.window, isNull);
      expect(controller.isInitialized, isFalse);
    });

    test('估算高度不足两个视口时继续往前扩', () {
      // 高度回调故意只报 1 个视口高：应当一直扩到轮数用尽。
      final controller = ChatWindowController()
        ..initialize(
          totalRounds: 200,
          viewportDimension: 600,
          heightOfWindow: (_) => 300,
        );
      expect(controller.window!.firstRoundIndex, 1);
      expect(controller.window!.lastRoundIndex, 200);
    });

    test('高度够了就停在初始窗口，不白扩', () {
      final controller = ChatWindowController()
        ..initialize(
          totalRounds: 200,
          viewportDimension: 600,
          heightOfWindow: (_) => 5000,
        );
      expect(controller.window, const ChatWindow(firstRoundIndex: 171, lastRoundIndex: 200));
    });
  });

  group('全书轮数变化', () {
    test('窗口贴着末端时尾随扩展', () {
      final controller = ChatWindowController()..initialize(totalRounds: 100);
      controller.setTotalRounds(101);
      expect(controller.window, const ChatWindow(firstRoundIndex: 71, lastRoundIndex: 101));
    });

    test('用户在翻历史时不跟着跑', () {
      final controller = ChatWindowController()..initialize(totalRounds: 100);
      controller.rebuildAround(40);
      final before = controller.window;
      controller.setTotalRounds(101);
      expect(controller.window, before);
      expect(controller.totalRounds, 101);
    });

    test('从 0 到有轮：自动建窗', () {
      final controller = ChatWindowController()..initialize(totalRounds: 0);
      controller.setTotalRounds(3);
      expect(controller.window, const ChatWindow(firstRoundIndex: 1, lastRoundIndex: 3));
    });

    test('清空书：窗口消失', () {
      final controller = ChatWindowController()..initialize(totalRounds: 10);
      controller.setTotalRounds(0);
      expect(controller.window, isNull);
    });
  });

  group('预取扩展', () {
    test('距窗口顶不足 1.5 视口时向上扩 20 轮', () {
      final controller = ChatWindowController()..initialize(totalRounds: 200);
      final expanded = controller.expandUp(
        distanceToWindowTop: 600,
        viewportDimension: 600,
      );
      expect(expanded, isTrue);
      expect(controller.window, const ChatWindow(firstRoundIndex: 151, lastRoundIndex: 200));
    });

    test('离得远就不扩', () {
      final controller = ChatWindowController()..initialize(totalRounds: 200);
      final expanded = controller.expandUp(
        distanceToWindowTop: 1200,
        viewportDimension: 600,
      );
      expect(expanded, isFalse);
      expect(controller.window!.firstRoundIndex, 171);
    });

    test('已经到最早一轮就不再扩（不越界成 0 轮）', () {
      final controller = ChatWindowController()..initialize(totalRounds: 5);
      expect(
        controller.expandUp(distanceToWindowTop: 0, viewportDimension: 600),
        isFalse,
      );
      expect(controller.window!.firstRoundIndex, 1);
    });

    test('向下回看同样按阈值扩', () {
      final controller = ChatWindowController()..initialize(totalRounds: 200);
      expect(
        controller.expandDown(distanceToWindowBottom: 100, viewportDimension: 600),
        isFalse,
        reason: '窗口已贴末端',
      );
      controller.rebuildAround(100);
      expect(
        controller.expandDown(distanceToWindowBottom: 100, viewportDimension: 600),
        isTrue,
      );
    });
  });

  group('跳转重建', () {
    test('目标两侧各留 15 轮', () {
      final controller = ChatWindowController()..initialize(totalRounds: 200);
      controller.rebuildAround(100);
      expect(controller.window, const ChatWindow(firstRoundIndex: 85, lastRoundIndex: 115));
    });

    test('靠头靠尾都夹取到合法范围', () {
      final controller = ChatWindowController()..initialize(totalRounds: 200);
      controller.rebuildAround(1);
      expect(controller.window, const ChatWindow(firstRoundIndex: 1, lastRoundIndex: 16));
      controller.rebuildAround(200);
      expect(controller.window, const ChatWindow(firstRoundIndex: 185, lastRoundIndex: 200));
    });

    test('跳转目标仍落在窗口内', () {
      final controller = ChatWindowController()..initialize(totalRounds: 200);
      controller.rebuildAround(123);
      expect(controller.window!.contains(123), isTrue);
    });
  });

  group('裁剪', () {
    test('轮数没超上限时不裁', () {
      final controller = ChatWindowController(maxRounds: 40)
        ..initialize(totalRounds: 60);
      expect(
        controller.trimIfNeeded(
          distanceToWindowTop: 99999,
          distanceToWindowBottom: 99999,
          viewportDimension: 600,
        ),
        isFalse,
      );
    });

    test('超上限且顶端离得远：从头部裁掉一页', () {
      final controller = ChatWindowController(maxRounds: 20, minRounds: 5)
        ..initialize(totalRounds: 400, heightOfWindow: (_) => 99999);
      controller.rebuildAround(200);
      // 窗口 185..215 共 31 轮，超上限 20。
      expect(controller.window!.roundCount, greaterThan(20));
      final trimmed = controller.trimIfNeeded(
        distanceToWindowTop: 6000,
        distanceToWindowBottom: 10,
        viewportDimension: 600,
        keepRoundIndex: 200,
      );
      expect(trimmed, isTrue);
      expect(controller.window!.firstRoundIndex, greaterThan(185));
      expect(controller.window!.contains(200), isTrue, reason: '不该把正在看的轮裁掉');
    });

    test('两端都近时不裁（避免手势中重建）', () {
      final controller = ChatWindowController(maxRounds: 20)
        ..initialize(totalRounds: 400, heightOfWindow: (_) => 99999);
      controller.rebuildAround(200);
      expect(
        controller.trimIfNeeded(
          distanceToWindowTop: 10,
          distanceToWindowBottom: 10,
          viewportDimension: 600,
        ),
        isFalse,
      );
    });
  });

  group('窗口性质', () {
    test('contains / includesHead / includesTail 口径', () {
      const window = ChatWindow(firstRoundIndex: 3, lastRoundIndex: 7);
      expect(window.contains(2), isFalse);
      expect(window.contains(3), isTrue);
      expect(window.contains(7), isTrue);
      expect(window.contains(8), isFalse);
      expect(window.includesHead(), isFalse);
      expect(window.includesTail(7), isTrue);
      expect(window.includesTail(8), isFalse);
      expect(window.roundCount, 5);
    });

    test('相等性与 toString', () {
      expect(
        const ChatWindow(firstRoundIndex: 1, lastRoundIndex: 2),
        const ChatWindow(firstRoundIndex: 1, lastRoundIndex: 2),
      );
      expect(
        const ChatWindow(firstRoundIndex: 1, lastRoundIndex: 2).toString(),
        'ChatWindow(1..2)',
      );
    });
  });
}
