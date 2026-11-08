import 'dart:math' as math;
import 'dart:ui' show Offset, Size;

/// 封面目标比例（宽 : 高 = 2 : 3）。
const double kCoverAspectRatio = 2 / 3;

/// 封面导出宽度（像素）。高度 = 宽 × 3 / 2 = 900。
///
/// 首页最大显示宽度约 148 逻辑像素（手机两列卡片），600 宽在 2× / 3× 屏上都够清晰，
/// 同时把落盘体积控制在合理范围（`dart:ui` 只编得出 PNG）。
const int kCoverOutputWidth = 600;

/// 封面导出高度（像素），与 [kCoverOutputWidth] 严格保持 2 : 3。
const int kCoverOutputHeight = 900;

/// 封面裁剪的几何状态：纯数据 + 纯函数，不碰界面也不碰文件。
///
/// 坐标约定：
/// - 取景框（viewport）与图片（image）都以**自身中心**为变换基准——界面把图片
///   居中摆进取景框，导出时也以输出画布中心为基准，两边用的是同一套数字，
///   不会出现「预览对、导出偏」；
/// - [angle] 弧度、顺时针为正；[zoom] 是叠在 cover 适配之上的缩放倍率
///   （1 = 不旋转时刚好铺满取景框）；[offset] 是取景框坐标系里的平移量。
///
/// 覆盖不变量分两段：
/// - **手势 / 滑块进行中**：允许 `zoom < minZoom`（旋转时四角可以先露白），
///   画面不会一边转一边自己放大；
/// - **停下来之后**：调 [settle] 把缩放补到 [minZoom]，重新铺满取景框再导出。
///
/// [offset] 始终按「取景框四角投影到图片局部轴」精确夹取（不是包围盒近似），
/// 所以只要没有漏白，拖动就不会拖出空边。
class CoverCropGeometry {
  const CoverCropGeometry._({
    required this.imageSize,
    required this.viewportSize,
    required this.zoom,
    required this.angle,
    required this.offset,
  });

  /// 初始状态：cover 适配 + 居中，不额外缩放、不旋转。
  factory CoverCropGeometry({
    required Size imageSize,
    required Size viewportSize,
  }) {
    return CoverCropGeometry._(
      imageSize: imageSize,
      viewportSize: viewportSize,
      zoom: 1,
      angle: 0,
      offset: Offset.zero,
    )._normalized();
  }

  /// 图片原始尺寸（像素）。
  final Size imageSize;

  /// 取景框尺寸（逻辑像素）。
  final Size viewportSize;

  /// 缩放倍率（相对 cover 适配；1 = 不旋转时刚好铺满取景框）。
  ///
  /// 旋转过程中它**可以低于 [minZoom]**（也就是四角暂时漏白），等手势 / 滑块
  /// 停下来再调 [settle] 补回正确缩放——这样旋转时画面不会一边转一边自动放大。
  final double zoom;

  /// 旋转弧度（顺时针为正）。
  final double angle;

  /// 取景框坐标系里的平移（像素，相对中心）。
  final Offset offset;

  /// 最大放大倍率（避免放大到只剩几个像素、糊成一片）。
  static const double maxZoom = 8;

  /// 尺寸合法（图片与取景框都有面积）时才谈得上布局与裁剪。
  bool get isUsable =>
      imageSize.width > 0 &&
      imageSize.height > 0 &&
      viewportSize.width > 0 &&
      viewportSize.height > 0;

  /// cover 适配倍率：不旋转、不额外缩放时刚好铺满取景框的比例。
  double get baseScale => math.max(
    viewportSize.width / imageSize.width,
    viewportSize.height / imageSize.height,
  );

  /// 当前实际生效的缩放倍率（cover 适配 × 缩放）。
  double get displayScale => baseScale * zoom;

  /// 图片当前显示尺寸（像素）。
  Size get displaySize => Size(
    imageSize.width * displayScale,
    imageSize.height * displayScale,
  );

  /// 当前角度下「不露白边」的最小缩放倍率。
  ///
  /// 取景框四角旋到图片局部坐标后，要求图片半宽 / 半高分别盖住它们：
  /// `iw·k ≥ vw·|cosθ| + vh·|sinθ|`、`ih·k ≥ vw·|sinθ| + vh·|cosθ|`。
  /// 角度为 0 时恰好等于 1（cover 适配本来就铺满）。
  double get minZoom {
    if (!isUsable) return 1;
    final cos = math.cos(angle).abs();
    final sin = math.sin(angle).abs();
    final viewW = viewportSize.width;
    final viewH = viewportSize.height;
    final needWidth = viewW * cos + viewH * sin;
    final needHeight = viewW * sin + viewH * cos;
    final factor = math.max(
      needWidth / (imageSize.width * baseScale),
      needHeight / (imageSize.height * baseScale),
    );
    return factor <= 1 ? 1 : factor;
  }

  /// 手势 / 滑块**停下来**之后的收尾：若当前缩放盖不住取景框（旋转时允许的
  /// 四角漏白），就把画面放大到刚好铺满，并把位移重新夹进合法范围。
  ///
  /// 返回新实例（不可变）；本来就铺满时原样返回（`identical`）。
  CoverCropGeometry settle() {
    if (!isUsable) return this;
    final required = minZoom;
    if (zoom >= required) return this;
    return _copy(zoom: required);
  }

  /// 把任意平移夹进「图片仍铺满取景框」的范围。
  Offset clampOffset(Offset raw) {
    if (!isUsable) return Offset.zero;
    final cos = math.cos(angle);
    final sin = math.sin(angle);
    final halfViewW = viewportSize.width / 2;
    final halfViewH = viewportSize.height / 2;
    // 取景框四角在图片局部坐标里的最大投影。
    final localHalfW = halfViewW * cos.abs() + halfViewH * sin.abs();
    final localHalfH = halfViewW * sin.abs() + halfViewH * cos.abs();
    final scale = displayScale;
    final slackX = math.max(0.0, imageSize.width * scale / 2 - localHalfW);
    final slackY = math.max(0.0, imageSize.height * scale / 2 - localHalfH);
    // 平移到图片局部坐标 → 逐轴夹取 → 转回取景框坐标。
    final localX = raw.dx * cos + raw.dy * sin;
    final localY = -raw.dx * sin + raw.dy * cos;
    final clampedX = localX.clamp(-slackX, slackX).toDouble();
    final clampedY = localY.clamp(-slackY, slackY).toDouble();
    return Offset(
      clampedX * cos - clampedY * sin,
      clampedX * sin + clampedY * cos,
    );
  }

  /// 单指拖动：按看到的方向平移（越界部分自动夹住）。
  CoverCropGeometry pan(Offset delta) =>
      _copy(offset: offset + delta);

  /// 缩放到指定倍率（相对 cover 适配）。
  ///
  /// 低于 [minZoom] 时允许（旋转过程中四角可以暂时露白），
  /// 手势 / 滑块结束后由 [settle] 补回正确缩放。
  CoverCropGeometry zoomTo(double value) => _copy(zoom: value);

  /// 按倍率相对缩放（捏合手势用）。
  CoverCropGeometry scaleBy(double factor) =>
      _copy(zoom: zoom * factor);

  /// 旋转到指定弧度（`0 = 不旋转`）。
  CoverCropGeometry rotateTo(double radians) => _copy(angle: radians);

  /// 相对旋转（捏合手势 / 90° 按钮用）。
  CoverCropGeometry rotateBy(double radians) =>
      _copy(angle: angle + radians);

  /// 回到初始状态（重新 cover 居中）。
  CoverCropGeometry reset() =>
      CoverCropGeometry(imageSize: imageSize, viewportSize: viewportSize);

  /// 取景框尺寸变化（窗口缩放 / 首帧布局）：按同比例换算位移后重新夹取。
  CoverCropGeometry withViewport(Size newViewport) {
    if (newViewport == viewportSize) return this;
    final oldViewW = viewportSize.width <= 0 ? 1 : viewportSize.width;
    final oldViewH = viewportSize.height <= 0 ? 1 : viewportSize.height;
    return CoverCropGeometry._(
      imageSize: imageSize,
      viewportSize: newViewport,
      zoom: zoom,
      angle: angle,
      offset: Offset(
        offset.dx * newViewport.width / oldViewW,
        offset.dy * newViewport.height / oldViewH,
      ),
    )._normalized();
  }

  /// 以「当前字段」派生出新状态，并统一过一遍夹取。
  CoverCropGeometry _copy({double? zoom, double? angle, Offset? offset}) {
    return CoverCropGeometry._(
      imageSize: imageSize,
      viewportSize: viewportSize,
      zoom: zoom ?? this.zoom,
      angle: angle ?? this.angle,
      offset: offset ?? this.offset,
    )._normalized();
  }

  /// 归一化：角度收敛到 `(-π, π]`、缩放夹到 `[1, maxZoom]`、位移夹到位。
  ///
  /// `zoom` 不按 [minZoom] 抬高：旋转后画面由 [displayScale] 自动放大补角，
  /// 缩放倍数保持用户设定值，滑块因此不会随旋转自己跳。
  CoverCropGeometry _normalized() {
    if (!isUsable) {
      return CoverCropGeometry._(
        imageSize: imageSize,
        viewportSize: viewportSize,
        zoom: 1,
        angle: 0,
        offset: Offset.zero,
      );
    }
    final wrapped = _wrapAngle(angle);
    final rawZoom = zoom.isFinite ? zoom : 1.0;
    final clampedZoom = rawZoom.clamp(1.0, maxZoom).toDouble();
    final withDefaults = CoverCropGeometry._(
      imageSize: imageSize,
      viewportSize: viewportSize,
      zoom: clampedZoom,
      angle: wrapped,
      offset: offset,
    );
    return CoverCropGeometry._(
      imageSize: imageSize,
      viewportSize: viewportSize,
      zoom: clampedZoom,
      angle: wrapped,
      offset: withDefaults.clampOffset(offset),
    );
  }

  /// 角度收敛到 `(-π, π]`，避免连续旋转后数字无限增长。
  static double _wrapAngle(double radians) {
    if (!radians.isFinite) return 0;
    const twoPi = math.pi * 2;
    var value = radians % twoPi;
    if (value > math.pi) value -= twoPi;
    if (value <= -math.pi) value += twoPi;
    return value;
  }

  @override
  bool operator ==(Object other) =>
      other is CoverCropGeometry &&
      other.imageSize == imageSize &&
      other.viewportSize == viewportSize &&
      other.zoom == zoom &&
      other.angle == angle &&
      other.offset == offset;

  @override
  int get hashCode =>
      Object.hash(imageSize, viewportSize, zoom, angle, offset);

  @override
  String toString() =>
      'CoverCropGeometry(image: $imageSize, viewport: $viewportSize, '
      'zoom: $zoom, angle: $angle, offset: $offset)';
}
