import 'dart:math' as math;

/// 小滑块把「手指位移」翻译成「滚动速度」的纯函数部分。
///
/// 为什么是速度而不是位置：滑块拖动时内容要跟着滚，但**手指到哪不等于内容到哪**
/// （尤其窗口化之后一窗内容的 extent 会变）。"位置映射"在拖动中就会撒谎；
/// 用速度驱动没有这个矛盾 —— 滑块只反馈"推了多远"，松手弹回中央。
///
/// 用法：`originY = 0`、`pointerY = 滑块相对中央的位移`、
/// `viewportHeight = 滑块行程`（满量程 = 推到行程尽头）。
///
/// 规格（`.agents/2026-11-06_chat_rail_spec.md` §7.5）：
/// ```
/// Δ = clamp((originY − pointerY) / 满量程, −1, +1)
/// |Δ| < 死区 → v = 0
/// s = sign(Δ) × |Δ|^指数
/// v = s × VMAX
/// ```
class ChatRailMotion {
  const ChatRailMotion({
    this.maxVelocity = 1.6,
    this.deadZone = 0.03,
    this.exponent = 1.3,
  });

  /// 满位移速度（视口/秒）。
  final double maxVelocity;

  /// 死区：手抖这几分之一行程不该让内容动。
  final double deadZone;

  /// 曲线指数：>1 时中心附近更精细（小位移慢、大位移快）。
  final double exponent;

  /// 计算当前速度（视口/秒）。正 = 往历史翻。
  ///
  /// [originY] 起点纵坐标，[pointerY] 当前纵坐标，
  /// [viewportHeight] 满量程对应的距离（对话页传滑块行程）。
  double velocityFor({
    required double originY,
    required double pointerY,
    required double viewportHeight,
  }) {
    if (viewportHeight <= 0 || !viewportHeight.isFinite) return 0;
    final raw = ((originY - pointerY) / viewportHeight).clamp(-1.0, 1.0);
    final magnitude = raw.abs();
    if (magnitude < deadZone) return 0;
    final shaped = math.pow(magnitude, exponent).toDouble();
    return raw.isNegative ? -shaped * maxVelocity : shaped * maxVelocity;
  }

  /// 拇指高度：内容占比越小，拇指越短；但不低于 [minThumbHeight]。
  static double thumbHeight({
    required double trackHeight,
    required double visibleFraction,
    double minThumbHeight = 24,
  }) {
    if (trackHeight <= 0) return 0;
    final fraction = visibleFraction.clamp(0.0, 1.0);
    final height = trackHeight * fraction;
    return height < minThumbHeight ? math.min(minThumbHeight, trackHeight) : height;
  }

  /// 拇指顶边相对轨道顶的位置（0 = 顶部/最早，1 = 底部/最新）。
  ///
  /// 注意这里把 [progress]（0 = 贴底）翻转成"从上往下"的坐标：
  /// 轨道的视觉方向是上=旧、下=新。
  static double thumbTop({
    required double trackHeight,
    required double thumbHeight,
    required double progress,
  }) {
    final travel = trackHeight - thumbHeight;
    if (travel <= 0) return 0;
    return (1 - progress.clamp(0.0, 1.0)) * travel;
  }
}
