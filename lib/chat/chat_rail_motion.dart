import 'dart:math' as math;

/// 轨道把「手指位移」翻译成「滚动速度」的纯函数部分。
///
/// 为什么是速度而不是位置：拖轨道时内容要跟着动，但拇指**不跟手**
/// （拇指始终等于真实进度）。"位置映射"做不到这点——手指一动拇指就得跳，
/// 而内容还没滚到那儿。用速度驱动就没有这个矛盾。
///
/// 规格（`.agents/2026-11-06_chat_rail_spec.md` §7.5）：
/// ```
/// Δ = clamp((originY − pointerY) / 视口高, −1, +1)
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

  /// 死区：手抖这几分之一屏不该让内容动。
  final double deadZone;

  /// 曲线指数：>1 时中心附近更精细（小位移慢、大位移快）。
  final double exponent;

  /// 计算当前速度（视口/秒）。正 = 往历史翻。
  ///
  /// [originY] 按下时的指针纵坐标，[pointerY] 当前纵坐标，
  /// [viewportHeight] 消息区可视高度（"满量程 = 1 个视口高"）。
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
