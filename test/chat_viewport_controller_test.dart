import 'dart:async';

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

/// 可控窗口宿主：记录「准备定点跳转窗口」的调用，并可按需卡住重建。
class _FakeWindowHost implements ChatWindowHost {
  _FakeWindowHost({this.contains = true, this.visibleRound});

  bool contains;

  /// `visibleRoundIndex` 的替身值；null = 交给几何兜底。
  int? visibleRound;

  final List<int> jumpRequests = [];

  /// 非 null 时 `rebuildWindowForJump` 等待它放行，用来模拟重建期间用户接管。
  Completer<void>? jumpGate;

  @override
  bool windowContainsRound(int roundIndex) => contains;

  @override
  bool get windowIncludesTail => true;

  @override
  double get windowBookOffsetBase => 0;

  @override
  double get windowLeadingInset => 0;

  @override
  int? get visibleRoundIndex => visibleRound;

  @override
  Future<void> rebuildWindowAround(int roundIndex) async {}

  @override
  Future<void> rebuildWindowForJump(int roundIndex) async {
    jumpRequests.add(roundIndex);
    final gate = jumpGate;
    if (gate != null) await gate.future;
  }

  @override
  void ensureWindowExpanded() {}
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
    test('当前轮 = 视口**顶部**那一轮（规格 §6.4）', () {
      // 3 轮 ×（96 + 320），视口 400：贴底时视口顶落在第 3 轮的气泡里。
      expect(controller.currentRoundIndex, 3);
    });

    test('往上翻到顶时 currentRoundIndex 变成第一轮', () {
      viewport.drag(geometry.total - viewport.viewportDimension);
      expect(controller.currentRoundIndex, 1);
    });

    test('progress：贴底 0、顶格 1', () {
      expect(controller.progress, 0.0);
      viewport.drag(geometry.total - viewport.viewportDimension);
      expect(controller.progress, 1.0);
    });

    test('visibleFraction = 视口高 / 全书总高', () {
      expect(controller.visibleFraction, closeTo(400 / geometry.total, 1e-9));
    });

    test('isPinnedToBottom：贴底为真，翻走为假', () {
      expect(controller.isPinnedToBottom, isTrue);
      viewport.drag(200);
      expect(controller.isPinnedToBottom, isFalse);
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

    test('当前轮优先读真实渲染行，不被几何估算带偏', () {
      final host = _FakeWindowHost(visibleRound: 2);
      final precise = ChatViewportController(
        viewport: viewport,
        geometry: geometry,
        window: host,
      );
      addTearDown(precise.dispose);

      expect(controller.currentRoundIndex, 3, reason: '无宿主的几何口径仍是 3');
      expect(
        precise.currentRoundIndex,
        2,
        reason: '页面顶部真实压着第 2 轮时，页码不得按估算高度报 3',
      );

      host.visibleRound = null;
      expect(precise.currentRoundIndex, 3, reason: '首帧未布局时回退几何');
    });
  });

  group('跳转', () {
    test('jumpToRound 落到该轮起点，且轮号自洽', () async {
      expect(await controller.jumpToRound(1), isTrue);
      expect(controller.currentRoundIndex, 1);
      final index = geometry.indexOfRound(1)!;
      expect(
        viewport.pixels,
        geometry.topEdgeOf(index) - viewport.viewportDimension,
        reason: '`pixels` 是视口底边：顶边贴视口顶 = 顶边距底 − 视口高',
      );
    });

    test('jumpToRound 超出最大轮号：夹到最后一轮（落点因此被夹到 16px）', () async {
      expect(await controller.jumpToRound(99), isTrue);
      expect(controller.maxRoundIndex, 3);
      expect(controller.currentRoundIndex, 3, reason: '最后一轮仍在视口顶部');
      expect(
        viewport.pixels,
        lessThan(controller.geometry.topEdgeOf(geometry.indexOfRound(3)!)),
        reason: '贴不到视口顶，只能到它自身的最大偏移',
      );
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

    test('目标轮号有缺口时向下就近取整', () async {
      final gapped = ChatGeometry();
      gapped.rebuild([
        ChatItem(
            roundUuid: 'r1', roundIndex: 1, kind: ChatItemKind.user),
        ChatItem(roundUuid: 'r1', roundIndex: 1, kind: ChatItemKind.ai),
        ChatItem(
            roundUuid: 'r4', roundIndex: 4, kind: ChatItemKind.user),
        ChatItem(roundUuid: 'r4', roundIndex: 4, kind: ChatItemKind.ai),
      ]);
      controller.geometry = gapped;
      expect(await controller.jumpToRound(3), isTrue);
      expect(controller.currentRoundIndex, 1, reason: '第 3 轮不存在 → 落在第 1 轮');
    });

    test('定点跳转总是请求精确定位窗口（目标已在窗口内也不例外）', () async {
      final host = _FakeWindowHost(contains: true);
      final precise = ChatViewportController(
        viewport: viewport,
        geometry: geometry,
        window: host,
      );
      addTearDown(precise.dispose);

      expect(await precise.jumpToRound(1), isTrue);
      expect(host.jumpRequests, [1], reason: '旧窗口可能仍把未构建行累计进落点');
      expect(precise.hasPendingJump, isTrue, reason: '移动后等待帧末复核');
      precise.cancelPendingJump();
      expect(precise.hasPendingJump, isFalse);
    });

    test('等待跳转窗口期间用户接管：放行后不再把视图拽回目标', () async {
      final host = _FakeWindowHost()..jumpGate = Completer<void>();
      final precise = ChatViewportController(
        viewport: viewport,
        geometry: geometry,
        window: host,
      );
      addTearDown(precise.dispose);

      final jumping = precise.jumpToRound(1);
      await Future<void>.delayed(Duration.zero);
      expect(precise.hasPendingJump, isTrue);

      precise.cancelPendingJump();
      host.jumpGate!.complete();
      expect(await jumping, isTrue);
      expect(viewport.jumps, isEmpty, reason: '用户已接管，落点不应再被应用');
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
