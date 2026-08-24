import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../services/image_store.dart';
import 'image_preview.dart';

// ---------------------------------------------------------------------------
// 子窗口入参（跨窗口传递的图片数据，经 WindowController 的 arguments 字符串传递）
// ---------------------------------------------------------------------------

/// desktop_multi_window 子窗口（图片查看器）的入参。
class ImageWindowArgs {
  final List<String> images;
  final int index;

  const ImageWindowArgs({required this.images, required this.index});

  String encode() => jsonEncode({'images': images, 'index': index});

  /// 从 JSON 字符串解析；格式不符返回 null。
  static ImageWindowArgs? tryDecode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final images = (decoded['images'] as List<dynamic>?)?.cast<String>();
      if (images == null || images.isEmpty) return null;
      final index = (decoded['index'] as num?)?.toInt() ?? 0;
      return ImageWindowArgs(images: images, index: index);
    } catch (_) {
      return null;
    }
  }
}

/// 子窗口入口：设置窗口尺寸/居中后运行查看器 App。
///
/// 由主窗口 `main()` 检侧到本窗口是「图片查看器子窗口」时调用。
Future<void> runImageViewerWindowApp(ImageWindowArgs args) async {
  windowManager.waitUntilReadyToShow(
    const WindowOptions(
      title: 'NarrChat 图像查看器',
      size: Size(960, 720),
      center: true,
      backgroundColor: Colors.black,
      titleBarStyle: TitleBarStyle.hidden,
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
    },
  );
  runApp(ImageViewerWindowApp(args: args));
}

/// 图片查看器子窗口应用（最小化，仅查看器，不初始化业务数据）。
class ImageViewerWindowApp extends StatelessWidget {
  final ImageWindowArgs args;

  const ImageViewerWindowApp({super.key, required this.args});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'NarrChat - 图片查看',
      theme: ThemeData(brightness: Brightness.dark),
      home: DesktopImageViewer(images: args.images, initialIndex: args.index),
    );
  }
}

// ---------------------------------------------------------------------------
// 缩放数学（纯函数，可单测）
// ---------------------------------------------------------------------------

/// 计算把 `imgW×imgH` 的图片完整放入 `viewW×viewH` 视口所需的比例（contain）。
double fitScale(double viewW, double viewH, double imgW, double imgH) {
  if (imgW <= 0 || imgH <= 0 || viewW <= 0 || viewH <= 0) return 1;
  return math.min(viewW / imgW, viewH / imgH);
}

/// 计算缩放所用的实际 2D 缩放值（X/Y 基向量长度的平均）。
///
/// ⚠️ 不要用 `Matrix4.getMaxScaleOnAxis()`：它包含 Z 轴（恒为 1），
/// 当图片被缩小到 fit（scale < 1）时会错误地返回 1，导致无法正确居中/钳制、可无限缩小。
double imageScale(Matrix4 matrix) {
  final sx = math.sqrt(
    matrix.storage[0] * matrix.storage[0] +
        matrix.storage[1] * matrix.storage[1] +
        matrix.storage[2] * matrix.storage[2],
  );
  final sy = math.sqrt(
    matrix.storage[4] * matrix.storage[4] +
        matrix.storage[5] * matrix.storage[5] +
        matrix.storage[6] * matrix.storage[6],
  );
  return (sx + sy) / 2;
}

/// 以 [focalPoint]（视图坐标系）为中心的缩放，把 [matrix] 按 [factor] 缩放，
/// 结果 clamp 到 [minScale, maxScale]。用于鼠标滚轮在光标处缩放。返回缩放后的矩阵。
Matrix4 zoomAt(
  Matrix4 matrix,
  Offset focalPoint,
  double factor, {
  required double minScale,
  required double maxScale,
}) {
  final m = matrix.clone();
  final currentScale = imageScale(m);
  final newScale = (currentScale * factor).clamp(minScale, maxScale);
  final scaleChange = newScale / currentScale;
  if (scaleChange == 1.0) return m;
  // 把光标点换算到子坐标，围绕该点缩放，保证光标下的内容不动。
  final focalInChild = MatrixUtils.transformPoint(Matrix4.inverted(m), focalPoint);
  final zoom = Matrix4.identity()
    ..translateByDouble(focalInChild.dx, focalInChild.dy, 0, 1)
    ..scaleByDouble(scaleChange, scaleChange, 1, 1)
    ..translateByDouble(-focalInChild.dx, -focalInChild.dy, 0, 1);
  return m.multiplied(zoom);
}

/// 把矩阵的平移钳制在「图片内容不脱离视口」的范围内：
/// - 某轴内容尺寸 ≤ 视口 → 在该轴居中（缩小到适配时的居中黑边）；
/// - 某轴内容尺寸 > 视口 → 平移限制在 [viewLen - contentLen, 0]，避免放大后拖出黑边。
Matrix4 clampTransform(Matrix4 matrix, Size viewport, Size image) {
  final scale = imageScale(matrix);
  final result = matrix.clone();
  result.storage[12] = _clampAxis(
    result.storage[12],
    image.width * scale,
    viewport.width,
  );
  result.storage[13] = _clampAxis(
    result.storage[13],
    image.height * scale,
    viewport.height,
  );
  return result;
}

double _clampAxis(double t, double contentLen, double viewLen) {
  if (contentLen <= viewLen) return (viewLen - contentLen) / 2;
  return t.clamp(viewLen - contentLen, 0.0);
}

// ---------------------------------------------------------------------------
// 桌面端图片查看器（独立窗口内）：左右箭头 + 鼠标滚轮缩放 + 鼠标拖动平移
// ---------------------------------------------------------------------------

class DesktopImageViewer extends StatefulWidget {
  final List<String> images;
  final int initialIndex;

  const DesktopImageViewer({
    super.key,
    required this.images,
    required this.initialIndex,
  });

  @override
  State<DesktopImageViewer> createState() => _DesktopImageViewerState();
}

class _DesktopImageViewerState extends State<DesktopImageViewer> {
  static const double _maxScale = 6.0;

  late int _index = widget.initialIndex;
  final TransformationController _transform = TransformationController();

  String? _absPath;
  bool _missing = false;
  String _title = 'NarrChat 图像查看器';

  @override
  void initState() {
    super.initState();
    _loadCurrent();
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  /// 更新窗口标题为「NarrChat 图像查看器 - {当前图片文件名}」。
  void _updateTitle() {
    final name = ImageStore.fileNameOf(widget.images[_index]);
    _title = 'NarrChat 图像查看器 - $name';
    try {
      windowManager.setTitle(_title);
    } catch (_) {
      // 窗口管理器尚未就绪时忽略，不阻塞查看器。
    }
  }

  Future<void> _loadCurrent() async {
    _updateTitle();
    setState(() {
      _absPath = null;
      _missing = false;
      _transform.value = Matrix4.identity();
    });
    String abs;
    try {
      abs = await ImageStore.resolveAbsolute(widget.images[_index]);
    } catch (_) {
      abs = widget.images[_index];
    }
    if (!mounted) return;
    setState(() => _absPath = abs);
  }

  void _prev() {
    if (_index <= 0) return;
    setState(() {
      _index--;
      _absPath = null;
      _missing = false;
      _transform.value = Matrix4.identity();
    });
    _loadCurrent();
  }

  void _next() {
    if (_index >= widget.images.length - 1) return;
    setState(() {
      _index++;
      _absPath = null;
      _missing = false;
      _transform.value = Matrix4.identity();
    });
    _loadCurrent();
  }

  /// 鼠标滚轮缩放（围绕光标），最小到 1.0（即 FittedBox/自适配态，不缩到更小）。
  void _onWheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final factor = event.scrollDelta.dy < 0 ? 1.15 : 0.87;
    _transform.value = zoomAt(
      _transform.value,
      event.localPosition,
      factor,
      minScale: 1.0,
      maxScale: _maxScale,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            // 自定义黑色标题栏（可拖动窗口），保证标题/按钮与背景对比。
            _WindowTitleBar(
              title: _title,
              onMinimize: () => windowManager.minimize(),
              onClose: () => windowManager.close(),
            ),
            Expanded(
              child: Stack(
                children: [
                  // 图片：InteractiveViewer(constrained:true) + Image(fit:contain)：
                  // Flutter 自带「适配视口并居中」，初始视图不会出现缩小/偏移；
                  // 滚轮缩放/拖动平移由 InteractiveViewer 处理。
                  Positioned.fill(
                    child: Listener(
                      onPointerSignal: _onWheel,
                      child: _missing
                          ? const Center(
                              child: Icon(
                                Icons.image_outlined,
                                color: Colors.white24,
                                size: 48,
                              ),
                            )
                          : _absPath == null
                              ? const Center(
                                  child: CircularProgressIndicator(
                                    color: Colors.white38,
                                  ),
                                )
                              : InteractiveViewer(
                                  transformationController: _transform,
                                  constrained: true,
                                  minScale: 1.0,
                                  maxScale: _maxScale,
                                  child: Image.file(
                                    File(_absPath!),
                                    fit: BoxFit.contain,
                                    errorBuilder: (_, _, _) => MissingImage(
                                      widget.images[_index],
                                    ),
                                  ),
                                ),
                    ),
                  ),
                  // 左右方向箭头。
                  _ArrowButton(
                    icon: Icons.chevron_left,
                    enabled: _index > 0,
                    tooltip: '上一张',
                    onPressed: _prev,
                  ),
                  _ArrowButton(
                    icon: Icons.chevron_right,
                    enabled: _index < widget.images.length - 1,
                    tooltip: '下一张',
                    onPressed: _next,
                  ),
                  // 页码指示。
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            '${_index + 1}/${widget.images.length}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  // 底部「保存到本地」按钮。
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            backgroundColor: Colors.white24,
                            foregroundColor: Colors.white,
                            side: BorderSide.none,
                          ),
                          icon: const Icon(Icons.download_outlined),
                          label: const Text('保存到本地'),
                          onPressed: _absPath == null
                              ? null
                              : () => saveImageFile(
                                    context,
                                    relPath: widget.images[_index],
                                    absPath: _absPath!,
                                  ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 自定义黑色窗口标题栏：可拖动窗口，展示标题 + 最小化/关闭按钮（白字白钮，对比清晰）。
class _WindowTitleBar extends StatelessWidget {
  final String title;
  final VoidCallback onMinimize;
  final VoidCallback onClose;

  const _WindowTitleBar({
    required this.title,
    required this.onMinimize,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onPanStart: (_) => windowManager.startDragging(),
      child: Container(
        height: 40,
        color: Colors.black,
        padding: const EdgeInsets.only(left: 16),
        child: Row(
          children: [
            const Icon(Icons.image_outlined, color: Colors.white70, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.remove, color: Colors.white),
              tooltip: '最小化',
              onPressed: onMinimize,
            ),
            IconButton(
              icon: const Icon(Icons.close, color: Colors.white70),
              tooltip: '关闭',
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }
}

/// 左右两侧的半透明箭头按钮。
class _ArrowButton extends StatelessWidget {
  final IconData icon;
  final bool enabled;
  final String tooltip;
  final VoidCallback onPressed;

  const _ArrowButton({
    required this.icon,
    required this.enabled,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 0,
      bottom: 0,
      left: icon == Icons.chevron_left ? 0 : null,
      right: icon == Icons.chevron_right ? 0 : null,
      child: Center(
        child: IconButton(
          icon: Icon(icon, color: Colors.white),
          tooltip: tooltip,
          visualDensity: VisualDensity.comfortable,
          style: IconButton.styleFrom(
            backgroundColor: Colors.black38,
          ),
          onPressed: enabled ? onPressed : null,
          disabledColor: Colors.white24,
        ),
      ),
    );
  }
}
