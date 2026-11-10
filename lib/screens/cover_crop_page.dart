import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/cover_image_renderer.dart';
import '../theme/app_theme.dart';
import '../utils/cover_crop_geometry.dart';
import '../widgets/app_notice_overlay.dart';

/// 画布底色：取景框里漏白（旋转中四角没盖住）时看到的就是它。
///
/// 刻意比纯黑浅一点，漏白才看得出来，也避免「框外纯黑一片」的观感。
const Color _kCanvasBackground = Color(0xFF23262C);

/// 打开封面裁剪页。
///
/// [image] 由调用方负责 `dispose()`（本页只读，不接管所有权）。
/// 确认 → 返回裁剪后的 PNG 字节；取消 / 返回 → null。
Future<Uint8List?> showCoverCropPage(
  BuildContext context, {
  required ui.Image image,
  CoverRenderer renderer = const UiCoverRenderer(),
}) {
  return Navigator.of(context).push<Uint8List>(
    MaterialPageRoute<Uint8List>(
      fullscreenDialog: true,
      builder: (_) => CoverCropPage(image: image, renderer: renderer),
    ),
  );
}

/// 封面裁剪页：**取景框固定 2 : 3**，图片在框里自由缩放 / 旋转 / 平移。
///
/// 交互（现代图片编辑器手感）：
/// - 双指捏合：同时缩放 + 旋转（`onScaleUpdate` 的 scale / rotation）；
/// - 单指拖动：平移；
/// - 桌面：滚轮缩放，另配「左转 / 右转 90°」「重置」按钮（触控板没有旋转手势）。
///
/// 所有变换都经过 [CoverCropGeometry] 归一化：任何角度、任何缩放下图片都铺满
/// 取景框，不会露出底色。确认时用同一份几何渲染 2 : 3 的 PNG。
class CoverCropPage extends StatefulWidget {
  /// 已解码的原图（调用方负责释放）。
  final ui.Image image;

  /// 结果渲染器（测试可注入替身）。
  final CoverRenderer renderer;

  const CoverCropPage({
    super.key,
    required this.image,
    this.renderer = const UiCoverRenderer(),
  });

  @override
  State<CoverCropPage> createState() => _CoverCropPageState();
}

class _CoverCropPageState extends State<CoverCropPage> {
  /// 取景框宽度上限：再宽会在桌面上把高度顶出视口（2:3 的关系，高 = 宽 × 1.5）。
  static const double _maxViewportWidth = 420;

  /// 当前几何状态（首帧布局后就一直非空）。
  CoverCropGeometry? _geometry;

  /// 手势开始时的几何快照：缩放 / 旋转按「相对起点的倍数 / 角度增量」计算，
  /// 避免逐帧累加带来的漂移。
  CoverCropGeometry? _gestureStart;

  /// 手势开始时的焦点位置：平移按「当前焦点 − 起点焦点」算累计位移。
  Offset? _gestureStartFocal;

  bool _saving = false;

  Size get _imageSize =>
      Size(widget.image.width.toDouble(), widget.image.height.toDouble());

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      // 整页深色底：状态栏图标固定浅色。否则从亮色主题的顶栏进来后会沿用
      // 深色图标，在黑底上看不见。
      value: NarrChatTheme.systemOverlayStyle(Brightness.dark),
      child: Scaffold(
        backgroundColor: const Color(0xFF121316),
        body: SafeArea(
          child: Column(
            children: [
              _buildTopBar(context),
              Expanded(child: _buildViewport(context)),
              _buildTools(context),
              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    );
  }

  /// 顶栏：取消 / 标题 / 确定（保存中显示进度并禁用按钮）。
  Widget _buildTopBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 4, 10, 0),
      child: Row(
        children: [
          TextButton(
            key: const Key('cover_crop_cancel'),
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
            style: TextButton.styleFrom(foregroundColor: Colors.white70),
            child: const Text('取消'),
          ),
          const Expanded(
            child: Text(
              '编辑封面',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          FilledButton(
            key: const Key('cover_crop_confirm'),
            onPressed: _saving ? null : _confirm,
            child: Text(_saving ? '处理中…' : '确定'),
          ),
        ],
      ),
    );
  }

  /// 画布：整块可用区域都画图，取景框只是画布中央一个固定的 2:3 框。
  ///
  /// 这样旋转 / 放大时能看见**取景框外**被裁掉的画面（用半透明遮罩压暗），
  /// 而不是一圈纯黑的墙；只有框内被裁出来（导出也只看框内）。
  Widget _buildViewport(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final canvasSize = constraints.biggest;
        if (canvasSize.isEmpty) return const SizedBox.shrink();
        final frameSize = _frameSizeFor(canvasSize);
        if (frameSize.isEmpty) return const SizedBox.shrink();
        final geometry = _syncGeometry(frameSize);
        final frameRect = Rect.fromCenter(
          center: canvasSize.center(Offset.zero),
          width: frameSize.width,
          height: frameSize.height,
        );
        return ClipRect(
          child: Listener(
            onPointerSignal: _onPointerSignal,
            child: GestureDetector(
              key: const Key('cover_crop_canvas'),
              behavior: HitTestBehavior.opaque,
              onScaleStart: _onScaleStart,
              onScaleUpdate: _onScaleUpdate,
              onScaleEnd: _onScaleEnd,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // 画布底色：旋转中四角漏白时看到的就是它（比纯黑浅，看得清漏白）。
                  const ColoredBox(color: _kCanvasBackground),
                  // 图片按真实尺寸铺满整块画布。`Center` + `SizedBox(displaySize)`
                  // 会被画布约束夹扁（比例被破坏、缩放/拖动看不出变化），
                  // 必须用 `OverflowBox` 把约束放开，框外的部分交给遮罩压暗。
                  OverflowBox(
                    alignment: Alignment.center,
                    minWidth: 0,
                    minHeight: 0,
                    maxWidth: double.infinity,
                    maxHeight: double.infinity,
                    child: Transform.translate(
                      offset: geometry.offset,
                      child: Transform.rotate(
                        angle: geometry.angle,
                        child: SizedBox(
                          width: geometry.displaySize.width,
                          height: geometry.displaySize.height,
                          // 盒子宽高与图片严格同比例（同一个 displayScale 换算），
                          // cover 在这里就是刚好铺满；万一比例算歪了，宁可裁边也不拉伸。
                          child: RawImage(
                            image: widget.image,
                            fit: BoxFit.cover,
                            alignment: Alignment.center,
                            filterQuality: FilterQuality.medium,
                          ),
                        ),
                      ),
                    ),
                  ),
                  // 取景框 + 框外压暗遮罩（纯装饰，不参与手势）。
                  IgnorePointer(
                    child: CustomPaint(
                      painter: _CropFramePainter(frame: frameRect),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 底部工具条：旋转 / 缩放滑块 + 90° 旋转与重置（手势之外的桌面兜底）。
  ///
  /// 滑块与手势共用同一份 [CoverCropGeometry]：捏合转过的角度、滚轮缩放的倍率
  /// 会立刻反映到滑块上；拖滑块也等价于做手势。
  Widget _buildTools(BuildContext context) {
    final geometry = _geometry;
    final rotationDeg = geometry == null ? 0.0 : geometry.angle * 180 / math.pi;
    // 缩放条显示的是「相对刚好铺满」的倍数：旋转时它会自动补角放大画面，
    // 但这个倍数不变，所以指针不会跟着旋转乱跳。
    final zoom = geometry?.zoom ?? 1.0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _sliderRow(
            context,
            icon: Icons.rotate_right,
            valueText: '${rotationDeg.round()}°',
            onDoubleTap: _resetRotation,
            slider: Slider(
              key: const Key('cover_crop_rotation_slider'),
              min: -180,
              max: 180,
              divisions: 360,
              value: rotationDeg.clamp(-180.0, 180.0),
              activeColor: Colors.white70,
              inactiveColor: Colors.white24,
              thumbColor: Colors.white,
              onChanged: _saving
                  ? null
                  : (value) => _rotateTo(value * math.pi / 180),
              // 松手后补角：旋转过程中允许四角漏白，停稳了再放大到铺满。
              onChangeEnd: _saving ? null : (_) => _settle(),
            ),
          ),
          _sliderRow(
            context,
            icon: Icons.zoom_in,
            valueText: '${zoom.toStringAsFixed(1)}×',
            onDoubleTap: _resetZoom,
            slider: Slider(
              key: const Key('cover_crop_zoom_slider'),
              min: 1,
              max: CoverCropGeometry.maxZoom,
              value: zoom.clamp(1.0, CoverCropGeometry.maxZoom),
              activeColor: Colors.white70,
              inactiveColor: Colors.white24,
              thumbColor: Colors.white,
              onChanged: _saving ? null : _zoomTo,
              onChangeEnd: _saving ? null : (_) => _settle(),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _toolButton(
                key: const Key('cover_crop_rotate_left'),
                icon: Icons.rotate_left,
                label: '左转 90°',
                onTap: () => _rotateBy(-math.pi / 2),
              ),
              _toolButton(
                key: const Key('cover_crop_rotate_right'),
                icon: Icons.rotate_right,
                label: '右转 90°',
                onTap: () => _rotateBy(math.pi / 2),
              ),
              _toolButton(
                key: const Key('cover_crop_reset'),
                icon: Icons.restart_alt,
                label: '重置',
                onTap: _reset,
              ),
            ],
          ),
          const SizedBox(height: 2),
          const Text(
            '双击滑块还原 · 取景框 2:3（导出 600×900）· 双指缩放 / 旋转 · 单指拖动 · 滚轮缩放',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white38, fontSize: 11.5),
          ),
        ],
      ),
    );
  }

  /// 一行「图标 + 滑块 + 当前值」；滑块压扁到 32 高，给取景框省面积。
  ///
  /// 整行支持**双击还原**：双击旋转条回到 0°，双击缩放条回到「刚好铺满」。
  Widget _sliderRow(
    BuildContext context, {
    required IconData icon,
    required String valueText,
    required Widget slider,
    required VoidCallback onDoubleTap,
  }) {
    return _DoubleTapDetector(
      onDoubleTap: onDoubleTap,
      child: SizedBox(
        height: 32,
        child: Row(
          children: [
            Icon(icon, size: 16, color: Colors.white54),
            const SizedBox(width: 4),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  overlayShape: SliderComponentShape.noOverlay,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 6,
                  ),
                ),
                child: slider,
              ),
            ),
            const SizedBox(width: 4),
            SizedBox(
              width: 48,
              child: Text(
                valueText,
                textAlign: TextAlign.right,
                style: const TextStyle(color: Colors.white70, fontSize: 11.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _toolButton({
    required Key key,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return TextButton.icon(
      key: key,
      onPressed: _saving ? null : onTap,
      style: TextButton.styleFrom(foregroundColor: Colors.white70),
      icon: Icon(icon, size: 18),
      label: Text(label, style: const TextStyle(fontSize: 12.5)),
    );
  }

  /// 取景框尺寸：固定 2 : 3，在可用区域里尽量大，宽度不超过 [_maxViewportWidth]。
  Size _frameSizeFor(Size available) {
    if (available.width <= 0 || available.height <= 0) return Size.zero;
    var width = math.min(available.width, _maxViewportWidth);
    var height = width / kCoverAspectRatio;
    if (height > available.height) {
      height = available.height;
      width = height * kCoverAspectRatio;
    }
    return Size(width, height);
  }

  /// 让几何状态对齐当前取景框（首次布局 / 窗口尺寸变化）。
  ///
  /// 这里直接赋值而非 `setState`：值完全由本次布局约束派生，本帧紧接着就会用它
  /// 渲染，重建一次没有意义（在 build 里 setState 反而会触发断言）。
  CoverCropGeometry _syncGeometry(Size viewport) {
    final current = _geometry;
    final next = current == null
        ? CoverCropGeometry(imageSize: _imageSize, viewportSize: viewport)
        : (current.viewportSize == viewport
              ? current
              : current.withViewport(viewport));
    _geometry = next;
    return next;
  }

  void _onScaleStart(ScaleStartDetails details) {
    _gestureStart = _geometry;
    _gestureStartFocal = details.focalPoint;
  }

  /// 双指：同时缩放 + 旋转；单指：`scale = 1 / rotation = 0`，只剩平移。
  ///
  /// 平移必须用「当前焦点 - 手势起点焦点」的**累计位移**。
  /// 每次都从手势起点的几何出发、只加最后那一帧的 `focalPointDelta` 的话，
  /// 鼠标一动一帧、画面就只挪一帧的距离然后原地不动（现象：一直锁在中心）。
  void _onScaleUpdate(ScaleUpdateDetails details) {
    final start = _gestureStart;
    final startFocal = _gestureStartFocal;
    if (start == null || startFocal == null || _saving) return;
    var next = start
        .zoomTo(start.zoom * details.scale)
        .rotateTo(start.angle + details.rotation);
    final panDelta = details.focalPoint - startFocal;
    if (panDelta != Offset.zero) {
      next = next.pan(panDelta);
    }
    setState(() => _geometry = next);
  }

  void _onScaleEnd(ScaleEndDetails details) {
    _gestureStart = null;
    _gestureStartFocal = null;
    // 捏合 / 旋转松手：旋转时允许的四角漏白在这里补回来。
    _settle();
  }

  /// 桌面滚轮缩放：向上滚放大、向下滚缩小。
  ///
  /// 滚轮没有「松手」事件，每一次滚动都是最终状态，所以滚完立刻补角，
  /// 保证不会停在漏白的画面上。
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final current = _geometry;
    if (current == null || _saving) return;
    final factor = math.exp(-event.scrollDelta.dy / 320);
    setState(() => _geometry = current.scaleBy(factor).settle());
  }

  /// 旋转到指定弧度（滑块拖动中；超出可视范围时会被归一化到 `(-π, π]`）。
  ///
  /// 拖动过程中**不做**补角，允许四角暂时漏白；松手时 [Slider.onChangeEnd]
  /// 会调 [_settle] 补回来。
  void _rotateTo(double radians) {
    final current = _geometry;
    if (current == null || _saving) return;
    setState(() => _geometry = current.rotateTo(radians));
  }

  /// 缩放到指定倍率（滑块拖动中；低于补角所需时会暂时漏白）。
  void _zoomTo(double value) {
    final current = _geometry;
    if (current == null || _saving) return;
    setState(() => _geometry = current.zoomTo(value));
  }

  /// 手势 / 滑块停下来后的收尾：漏白就放大到刚好铺满（并重新夹位移）。
  void _settle() {
    final current = _geometry;
    if (current == null || _saving) return;
    final settled = current.settle();
    if (identical(settled, current)) return;
    setState(() => _geometry = settled);
  }

  /// 双击旋转条：角度回到 0°（缩放保持用户设的值）。
  void _resetRotation() {
    final current = _geometry;
    if (current == null || _saving) return;
    setState(() => _geometry = current.rotateTo(0).settle());
  }

  /// 双击缩放条：回到「当前角度下刚好铺满」（角度为 0 时就是 1.0×）。
  void _resetZoom() {
    final current = _geometry;
    if (current == null || _saving) return;
    setState(() => _geometry = current.zoomTo(current.minZoom));
  }

  /// 90° 按钮：离散操作，转完立刻补角（不像滑块那样允许中途漏白）。
  void _rotateBy(double radians) {
    final current = _geometry;
    if (current == null || _saving) return;
    setState(() => _geometry = current.rotateBy(radians).settle());
  }

  void _reset() {
    final current = _geometry;
    if (current == null || _saving) return;
    setState(() => _geometry = current.reset());
  }

  /// 确认：先补角（保险，正常情况下松手时已经补过），再渲染 2 : 3 PNG 退出。
  Future<void> _confirm() async {
    final raw = _geometry;
    if (raw == null || _saving) return;
    final geometry = raw.settle();
    setState(() {
      _saving = true;
      _geometry = geometry;
    });
    try {
      final bytes = await widget.renderer.render(
        image: widget.image,
        geometry: geometry,
      );
      if (!mounted) return;
      Navigator.of(context).pop(bytes);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      context.notices.error('封面裁剪失败：$e', copyable: true);
    }
  }
}

/// 取景框装饰 + 框外压暗遮罩（纯装饰，不参与手势）。
///
/// 框外那层是**半透明黑**而不是纯黑：旋转 / 放大时框外被裁掉的画面还能看见，
/// 只是明显变暗，一眼能分清「留下」和「裁掉」。
class _CropFramePainter extends CustomPainter {
  const _CropFramePainter({required this.frame});

  /// 取景框在画布坐标系里的矩形（画布中央、固定 2:3）。
  final Rect frame;

  /// 取景框外的压暗遮罩色（能看见框外画面，只是变暗）。
  static const Color scrimColor = Color(0x99000000);

  @override
  void paint(Canvas canvas, Size size) {
    // 框外压暗：整块画布挖掉取景框（evenOdd 天生就是「回」字形）。
    final scrim = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(frame);
    canvas.drawPath(scrim, Paint()..color = scrimColor);

    final border = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = Colors.white24;
    canvas.drawRect(frame.deflate(0.5), border);

    final grid = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.7
      ..color = Colors.white.withValues(alpha: 0.12);
    for (var i = 1; i <= 2; i++) {
      final dx = frame.left + frame.width * i / 3;
      final dy = frame.top + frame.height * i / 3;
      canvas.drawLine(Offset(dx, frame.top), Offset(dx, frame.bottom), grid);
      canvas.drawLine(Offset(frame.left, dy), Offset(frame.right, dy), grid);
    }

    // 四角标记：让取景框边界在深色底上看得清。
    final corner = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round
      ..color = Colors.white70;
    final length = math.min(frame.width, frame.height) * 0.08;
    const inset = 1.2;
    final left = frame.left + inset;
    final top = frame.top + inset;
    final right = frame.right - inset;
    final bottom = frame.bottom - inset;
    final corners = <(Offset, Offset, Offset)>[
      (Offset(left, top), Offset(left + length, top), Offset(left, top + length)),
      (
        Offset(right, top),
        Offset(right - length, top),
        Offset(right, top + length),
      ),
      (
        Offset(left, bottom),
        Offset(left + length, bottom),
        Offset(left, bottom - length),
      ),
      (
        Offset(right, bottom),
        Offset(right - length, bottom),
        Offset(right, bottom - length),
      ),
    ];
    for (final (point, horizontal, vertical) in corners) {
      canvas.drawLine(point, horizontal, corner);
      canvas.drawLine(point, vertical, corner);
    }
  }

  @override
  bool shouldRepaint(_CropFramePainter oldDelegate) =>
      oldDelegate.frame != frame;
}

/// 双击检测：用原始 pointer 事件，不和 [Slider] 抢手势竞技场。
///
/// 为什么不用 `GestureDetector.onDoubleTap`：它一旦挂上就会把「点轨道跳值」一起
/// 吞掉（单点也会被双击识别器扣住），滑块体验反而变差。这里只旁听 pointer 抬起，
/// 第二次抬起时把回调排进**微任务**——它一定晚于 Slider 自己的值更新，
/// 所以「双击还原」不会被滑块随后那次赋值盖回去。
class _DoubleTapDetector extends StatefulWidget {
  final VoidCallback onDoubleTap;
  final Widget child;

  const _DoubleTapDetector({required this.onDoubleTap, required this.child});

  @override
  State<_DoubleTapDetector> createState() => _DoubleTapDetectorState();
}

class _DoubleTapDetectorState extends State<_DoubleTapDetector> {
  /// 两次点击允许的最大间隔。
  static const Duration _window = Duration(milliseconds: 320);

  /// 两次点击允许的最大位置偏差（同一根滑块范围内）。
  static const double _slop = 36;

  DateTime? _lastUpAt;
  Offset? _lastUpPosition;

  @override
  Widget build(BuildContext context) {
    return Listener(onPointerUp: _onPointerUp, child: widget.child);
  }

  void _onPointerUp(PointerUpEvent event) {
    final now = DateTime.now();
    final lastAt = _lastUpAt;
    final lastPosition = _lastUpPosition;
    final isDoubleTap =
        lastAt != null &&
        lastPosition != null &&
        now.difference(lastAt) <= _window &&
        (event.position - lastPosition).distance <= _slop;
    if (!isDoubleTap) {
      _lastUpAt = now;
      _lastUpPosition = event.position;
      return;
    }
    _lastUpAt = null;
    _lastUpPosition = null;
    Future.microtask(() {
      if (mounted) widget.onDoubleTap();
    });
  }
}
