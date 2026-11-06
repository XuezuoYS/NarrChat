import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/chat/chat_rail_motion.dart';

/// 速度模型是纯函数，所以这些用例全是毫秒级的 `test()`。
void main() {
  const motion = ChatRailMotion();
  const viewport = 600.0;

  double velocity(double deltaY) =>
      motion.velocityFor(originY: 300, pointerY: 300 + deltaY, viewportHeight: viewport);

  group('速度映射（规格 §7.5）', () {
    test('不动时为 0', () {
      expect(velocity(0), 0);
    });

    test('死区内为 0（防抖）', () {
      // 0.02 视口 = 12px，小于死区 0.03。
      expect(velocity(-12), 0);
      expect(velocity(12), 0);
    });

    test('刚好越过死区就开始有速度', () {
      // 0.031 视口 ≈ 18.6px
      expect(velocity(-19), greaterThan(0));
      expect(velocity(19), lessThan(0));
    });

    test('向上拖 = 正速度（往历史翻）', () {
      expect(velocity(-300), greaterThan(0));
    });

    test('向下拖 = 负速度（往最新翻）', () {
      expect(velocity(300), lessThan(0));
    });

    test('满量程（1 个视口）等于 maxVelocity', () {
      expect(velocity(-viewport), closeTo(motion.maxVelocity, 1e-9));
      expect(velocity(viewport), closeTo(-motion.maxVelocity, 1e-9));
    });

    test('超出满量程被夹取，不会更快', () {
      expect(velocity(-viewport * 5), closeTo(motion.maxVelocity, 1e-9));
    });

    test('幂律：半量程按指数衰减', () {
      final expected = math.pow(0.5, motion.exponent) * motion.maxVelocity;
      expect(velocity(-viewport / 2), closeTo(expected.toDouble(), 1e-9));
    });

    test('中心附近比线性更精细（指数 > 1）', () {
      final linear = 0.1 * motion.maxVelocity;
      expect(velocity(-viewport * 0.1), lessThan(linear));
    });

    test('视口高度非法时返回 0，不抛', () {
      expect(
        motion.velocityFor(originY: 0, pointerY: -100, viewportHeight: 0),
        0,
      );
      expect(
        motion.velocityFor(originY: 0, pointerY: -100, viewportHeight: double.infinity),
        0,
      );
    });

    test('可调参数：自定义 VMAX / 死区 / 指数', () {
      const custom = ChatRailMotion(maxVelocity: 3, deadZone: 0.5, exponent: 1);
      expect(custom.velocityFor(originY: 0, pointerY: -100, viewportHeight: 600), 0);
      expect(
        custom.velocityFor(originY: 0, pointerY: -600, viewportHeight: 600),
        closeTo(3, 1e-9),
      );
    });
  });

  group('拇指几何', () {
    test('高度按视口占比缩放', () {
      expect(
        ChatRailMotion.thumbHeight(trackHeight: 400, visibleFraction: 0.5),
        200,
      );
    });

    test('有最小高度，短内容不会变成一根线', () {
      expect(
        ChatRailMotion.thumbHeight(trackHeight: 400, visibleFraction: 0.01),
        24,
      );
    });

    test('占比夹取到 [0,1]', () {
      expect(
        ChatRailMotion.thumbHeight(trackHeight: 400, visibleFraction: 5),
        400,
      );
    });

    test('轨道高度为 0 时返回 0', () {
      expect(
        ChatRailMotion.thumbHeight(trackHeight: 0, visibleFraction: 0.5),
        0,
      );
    });

    test('拇指顶边：progress 1（顶部）贴轨道顶，progress 0（底部）贴轨道底', () {
      expect(
        ChatRailMotion.thumbTop(trackHeight: 400, thumbHeight: 100, progress: 1),
        0,
      );
      expect(
        ChatRailMotion.thumbTop(trackHeight: 400, thumbHeight: 100, progress: 0),
        300,
      );
    });

    test('拇指顶边：中间进度落在中间，且夹取越界', () {
      expect(
        ChatRailMotion.thumbTop(trackHeight: 400, thumbHeight: 100, progress: 0.5),
        150,
      );
      expect(
        ChatRailMotion.thumbTop(trackHeight: 400, thumbHeight: 100, progress: -1),
        300,
      );
      expect(
        ChatRailMotion.thumbTop(trackHeight: 400, thumbHeight: 100, progress: 2),
        0,
      );
    });

    test('拇指比轨道还高时顶边为 0（不出现负位移）', () {
      expect(
        ChatRailMotion.thumbTop(trackHeight: 30, thumbHeight: 40, progress: 0.3),
        0,
      );
    });
  });
}
