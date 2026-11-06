import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/chat/chat_geometry.dart';
import 'package:narrchat/chat/chat_item.dart';
import 'package:narrchat/chat/chat_locator.dart';
import 'package:narrchat/chat/chat_viewport.dart';

/// 可控的视口替身：像素/视口高/上限都由用例给，`jumpTo` 只记录并夹取。
class _FakeViewport implements ChatViewport {
  _FakeViewport();

  @override
  double pixels = 0;

  @override
  double viewportDimension = 400;

  @override
  double maxOffset = 2000;

  @override
  bool hasClients = true;

  final List<double> jumps = [];
  final List<VoidCallback> _listeners = [];

  @override
  void jumpTo(double offset) {
    final next = offset.clamp(0.0, maxOffset).toDouble();
    jumps.add(next);
    pixels = next;
    for (final listener in List.of(_listeners)) {
      listener();
    }
  }

  @override
  void addListener(VoidCallback listener) => _listeners.add(listener);

  @override
  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  /// 模拟用户手势/物理滚动直接改像素。
  void drag(double delta) {
    pixels = (pixels + delta).clamp(0.0, maxOffset).toDouble();
    for (final listener in List.of(_listeners)) {
      listener();
    }
  }
}

/// 3 轮 × (用户 96 + AI 320) 的固定几何。
ChatGeometry buildGeometry({int rounds = 3}) {
  final geometry = ChatGeometry();
  geometry.rebuild([
    for (var i = 1; i <= rounds; i++) ...[
      ChatItem(roundUuid: 'r$i', roundIndex: i, kind: ChatItemKind.user),
      ChatItem(roundUuid: 'r$i', roundIndex: i, kind: ChatItemKind.ai),
    ],
  ]);
  return geometry;
}

void main() {
  late _FakeViewport viewport;
  late ChatGeometry geometry;
  late ChatViewportController controller;

  setUp(() {
    viewport = _FakeViewport();
    geometry = buildGeometry();
    controller = ChatViewportController(viewport: viewport, geometry: geometry);
  });

  tearDown(() => controller.dispose());

  group('当前轮与进度', () {
    test('贴底时 currentRoundIndex 是最新轮', () {
      expect(controller.currentRoundIndex, 3);
    });

    test('往上翻到中间时 currentRoundIndex 跟着变', () {
      viewport.drag(geometry.total - 400);
      expect(controller.currentRoundIndex, 1);
    });

    test('progress：贴底 0、顶格 1', () {
      expect(controller.progress, 0.0);
      viewport.drag(geometry.total - viewport.viewportDimension);
      expect(controller.progress, 1.0);
    });

    test('未挂上滚动位置时 progress 为 null，轮号仍可算', () {
      viewport.hasClients = false;
      expect(controller.progress, isNull);
      expect(controller.currentRoundIndex, 3);
    });

    test('几何为空时 currentRoundIndex 为 null', () {
      controller.geometry = ChatGeometry();
      expect(controller.currentRoundIndex, isNull);
    });
  });

  group('跳转', () {
    test('jumpToRound 落到该轮起点，且轮号自洽', () async {
      await controller.jumpToRound(1);
      expect(controller.currentRoundIndex, 1);
      final index = geometry.indexOfRound(1)!;
      expect(
        viewport.pixels,
        geometry.offsetOf(index) + geometry.heightOf(index),
        reason: '落点是目标条目顶边贴视口顶，不是底边',
      );
    });

    test('jumpToRound 未知轮号不动', () async {
      viewport.drag(120);
      final before = viewport.pixels;
      await controller.jumpToRound(99);
      expect(viewport.pixels, before);
      expect(viewport.jumps, isEmpty);
    });

    test('jumpToTop 到最早一轮', () async {
      await controller.jumpToTop();
      expect(controller.currentRoundIndex, 1);
      expect(viewport.pixels, viewport.maxOffset);
    });

    test('jumpToBottom 回到底部', () async {
      viewport.drag(900);
      await controller.jumpToBottom();
      expect(viewport.pixels, 0);
      expect(controller.currentRoundIndex, 3);
    });
  });

  group('速度驱动', () {
    test('按 视口/秒 推进：1 视口/秒 × 0.5 秒 = 半个视口', () {
      controller.scrollByVelocity(1);
      controller.stepVelocity(0.5);
      expect(viewport.pixels, viewport.viewportDimension * 0.5);
    });

    test('速度被夹到 maxVelocity', () {
      controller.scrollByVelocity(10);
      controller.stepVelocity(0.1);
      expect(
        viewport.pixels,
        closeTo(controller.maxVelocity * viewport.viewportDimension * 0.1, 0.001),
      );
    });

    test('负速度往底部走，并在 0 处停住不越界', () {
      viewport.drag(50);
      controller.scrollByVelocity(-1);
      controller.stepVelocity(1);
      expect(viewport.pixels, 0);
      controller.stepVelocity(1);
      expect(viewport.pixels, 0);
    });

    test('撞到上限后继续推进也不越界', () {
      viewport.drag(viewport.maxOffset - 10);
      controller.scrollByVelocity(1.6);
      controller.stepVelocity(1);
      expect(viewport.pixels, viewport.maxOffset);
    });

    test('stopVelocity 之后不再移动，isScrolling 复位', () {
      controller.scrollByVelocity(1);
      expect(controller.isScrolling, isTrue);
      controller.stopVelocity();
      expect(controller.isScrolling, isFalse);
      final before = viewport.pixels;
      controller.stepVelocity(1);
      expect(viewport.pixels, before);
    });

    test('速度为 0 等价于停止', () {
      controller.scrollByVelocity(0);
      expect(controller.isScrolling, isFalse);
      controller.stepVelocity(1);
      expect(viewport.pixels, 0);
    });

    test('未挂上滚动位置时速度驱动为空操作', () {
      viewport.hasClients = false;
      controller.scrollByVelocity(1);
      controller.stepVelocity(1);
      expect(viewport.jumps, isEmpty);
    });

    test('advance 第一次只记时间，第二次按时间差推进', () {
      controller.scrollByVelocity(1);
      controller.advance(const Duration(milliseconds: 100));
      expect(viewport.pixels, 0, reason: '起步帧没有参照点，不该位移');
      controller.advance(const Duration(milliseconds: 350));
      expect(
        viewport.pixels,
        closeTo(viewport.viewportDimension * 0.25, 0.001),
        reason: '100ms → 350ms 是 0.25 秒',
      );
    });
  });

  group('通知', () {
    test('几何替换会通知监听者', () {
      var notified = 0;
      controller.addListener(() => notified++);
      controller.geometry = buildGeometry(rounds: 5);
      expect(notified, 1);
      expect(controller.currentRoundIndex, 5);
    });

    test('同一几何实例不重复通知', () {
      var notified = 0;
      controller.addListener(() => notified++);
      controller.geometry = geometry;
      expect(notified, 0);
    });

    test('视口像素变化会通知（轨道据此刷新拇指）', () {
      var notified = 0;
      controller.addListener(() => notified++);
      viewport.drag(100);
      expect(notified, 1);
    });
  });
}
