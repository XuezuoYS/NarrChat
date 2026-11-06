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

  group('轮数变少', () {
    test('链变短时按尾部重建窗口，绝不产生倒置窗', () {
      final controller = ChatWindowController()..initialize(totalRounds: 120);
      expect(controller.window, const ChatWindow(firstRoundIndex: 91, lastRoundIndex: 120));

      // 换书 / 切早期短分支：新链只有 10 轮。
      controller.setTotalRounds(10);

      final window = controller.window!;
      expect(window.firstRoundIndex, lessThanOrEqualTo(window.lastRoundIndex),
          reason: '倒置窗（如 91..10）会让窗口里一层轮次都查不到，整页空白');
      expect(window, const ChatWindow(firstRoundIndex: 1, lastRoundIndex: 10));
      expect(window.contains(5), isTrue);
      expect(controller.totalRounds, 10);
    });

    test('链变短但仍长于初始窗口：窗口留在尾部', () {
      final controller = ChatWindowController()..initialize(totalRounds: 100);
      controller.setTotalRounds(40);
      expect(controller.window, const ChatWindow(firstRoundIndex: 11, lastRoundIndex: 40));
      expect(controller.window!.includesTail(40), isTrue);
    });

    test('链变长为 0 时窗口消失', () {
      final controller = ChatWindowController()..initialize(totalRounds: 30);
      controller.setTotalRounds(0);
      expect(controller.window, isNull);
      expect(controller.isInitialized, isFalse);
    });
  });

  group('换书 / 换分支重置', () {
    test('reset 后窗口与总数一起清空', () {
      final controller = ChatWindowController()..initialize(totalRounds: 50);
      controller.reset();
      expect(controller.window, isNull);
      expect(controller.isInitialized, isFalse);
      expect(controller.totalRounds, 0);
    });

    test('reset 后按新链重新建窗', () {
      final controller = ChatWindowController()..initialize(totalRounds: 200);
      controller.rebuildAround(40);
      controller.reset();
      controller.initialize(totalRounds: 6);
      expect(controller.window, const ChatWindow(firstRoundIndex: 1, lastRoundIndex: 6));
    });
  });

  group('首屏补足高度', () {
    test('首帧量不到视口高：布局后补做，一直扩到撑满两屏', () {
      final controller = ChatWindowController()..initialize(totalRounds: 200);
      expect(controller.window!.firstRoundIndex, 171, reason: '首帧只按轮数建窗');

      final grew = controller.satisfyMinimumHeight(
        heightOfWindow: (_) => 300,
        viewportDimension: 600,
      );

      expect(grew, isTrue);
      expect(controller.window!.firstRoundIndex, 1);
      expect(controller.window!.lastRoundIndex, 200);
    });

    test('高度已经够两屏就不白扩', () {
      final controller = ChatWindowController()..initialize(totalRounds: 200);
      final grew = controller.satisfyMinimumHeight(
        heightOfWindow: (_) => 5000,
        viewportDimension: 600,
      );
      expect(grew, isFalse);
      expect(controller.window, const ChatWindow(firstRoundIndex: 171, lastRoundIndex: 200));
    });

    test('窗口已不在末端（用户跳去历史）时不补', () {
      final controller = ChatWindowController()..initialize(totalRounds: 200);
      controller.rebuildAround(40);
      final before = controller.window;
      final grew = controller.satisfyMinimumHeight(
        heightOfWindow: (_) => 100,
        viewportDimension: 600,
      );
      expect(grew, isFalse);
      expect(controller.window, before);
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
