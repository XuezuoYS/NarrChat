import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:desktop_multi_window/desktop_multi_window.dart';
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

  /// 是否为「预热常驻」查看器窗口：`true` 时子窗口进入常驻监听模式，
  /// 等待主窗口通过命令通道送入图片组（此时 [images] 可为空）。
  final bool warm;

  const ImageWindowArgs({
    required this.images,
    required this.index,
    this.warm = false,
  });

  String encode() =>
      jsonEncode({'images': images, 'index': index, if (warm) 'warm': true});

  /// 从 JSON 字符串解析；格式不符返回 null。
  static ImageWindowArgs? tryDecode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final images = (decoded['images'] as List<dynamic>?)?.cast<String>();
      final warm = decoded['warm'] == true;
      // 非预热窗口必须携带非空图片；预热窗口允许空列表（等待后续 load 命令）。
      if (images == null || (images.isEmpty && !warm)) return null;
      final index = (decoded['index'] as num?)?.toInt() ?? 0;
      return ImageWindowArgs(images: images, index: index, warm: warm);
    } catch (_) {
      return null;
    }
  }
}

/// 一条「加载图片组」命令的解析结果（主窗口 → 预热查看器窗口）。
class ImageViewerLoadParams {
  final List<String> images;
  final int index;

  const ImageViewerLoadParams(this.images, this.index);
}

/// 解析主窗口从命令通道送达的 `load` 载荷；格式不符返回 null。
ImageViewerLoadParams? tryDecodeLoadPayload(dynamic payload) {
  if (payload is! Map) return null;
  final raw = payload['images'];
  // 立即校验元素类型，避免 `.cast<String>()` 的惰性视图把非字符串列表放行。
  if (raw is! List || raw.isEmpty || !raw.every((e) => e is String)) {
    return null;
  }
  final images = raw.cast<String>();
  final index = (payload['index'] as num?)?.toInt() ?? 0;
  return ImageViewerLoadParams(images, index);
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

/// 图片查看器「预热常驻窗口」入口：配置窗口尺寸/居中（但保持隐藏），
/// 随后进入常驻监听模式，等待主窗口送入图片组。
///
/// 由主窗口 `main()` 检测到本窗口是「预热标记」子窗口时调用。
Future<void> runWarmImageViewerWindowApp() async {
  // 只配置窗口（尺寸/居中/黑色背景/隐藏系统标题栏），不 show，保持隐藏，
  // 由收到 `load` 命令时的 WarmImageViewerWindowApp 再显示。
  windowManager.waitUntilReadyToShow(
    const WindowOptions(
      title: 'NarrChat 图像查看器',
      size: Size(960, 720),
      center: true,
      backgroundColor: Colors.black,
      titleBarStyle: TitleBarStyle.hidden,
    ),
    () async {},
  );
  runApp(const WarmImageViewerWindowApp());
}

/// 预热常驻查看器窗口：注册「load」命令处理器，收到后加载图片组并显示。
///
/// 窗口初始为隐藏，本地无状态；每次 `load` 换一组新图片（用新 Key 重建
/// [DesktopImageViewer]），在窗口内完成显示与聚焦，避免主窗口「先 show 空窗口」。
class WarmImageViewerWindowApp extends StatefulWidget {
  const WarmImageViewerWindowApp({super.key});

  @override
  State<WarmImageViewerWindowApp> createState() =>
      _WarmImageViewerWindowAppState();
}

class _WarmImageViewerWindowAppState extends State<WarmImageViewerWindowApp> {
  List<String> _images = const [];
  int _index = 0;
  int _rev = 0;

  final _WindowHideOnCloseListener _closeListener =
      _WindowHideOnCloseListener();

  @override
  void initState() {
    super.initState();
    _setupWindowBehavior();
    _registerHandler();
  }

  @override
  void dispose() {
    windowManager.removeListener(_closeListener);
    super.dispose();
  }

  /// 复用窗口的关键：拦截关闭信号（X / Alt+F4 / 任务栏关闭 / 标题栏关闭按钮），
  /// 改为「隐藏」而非「销毁」，从而保留引擎，保证下次开图能直接复用（QQ 等软件的做法）。
  Future<void> _setupWindowBehavior() async {
    try {
      await windowManager.setPreventClose(true);
      windowManager.addListener(_closeListener);
    } catch (_) {
      // 窗口管理器未就绪时忽略。
    }
  }

  Future<void> _registerHandler() async {
    try {
      final controller = await WindowController.fromCurrentEngine();
      await controller.setWindowMethodHandler((call) async {
        if (call.method != 'load') {
          return <String, dynamic>{'ok': false};
        }
        final params = tryDecodeLoadPayload(call.arguments);
        if (params == null) {
          return <String, dynamic>{'ok': false};
        }
        if (mounted) {
          setState(() {
            _images = params.images;
            _index = params.index;
            _rev++;
          });
          await _showLoaded();
        }
        return <String, dynamic>{'ok': true};
      });
    } catch (e) {
      debugPrint('查看器窗口注册命令处理器失败: $e');
    }
  }

  Future<void> _showLoaded() async {
    try {
      // 预热窗口在启动时创建并保持隐藏，其尺寸可能未在创建时正确生效；
      // 因此在显示时重新强制正确尺寸并居中，避免 release 安装版出现尺寸/布局异常。
      await windowManager.setSize(const Size(960, 720));
      await windowManager.center();
      await windowManager.show();
      await windowManager.focus();
    } catch (_) {
      // 窗口管理器未就绪时忽略，不阻塞查看器。
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'NarrChat - 图片查看',
      theme: ThemeData(brightness: Brightness.dark),
      home: _images.isEmpty
          ? const ColoredBox(color: Colors.black)
          : DesktopImageViewer(
              key: ValueKey<int>(_rev),
              images: _images,
              initialIndex: _index,
            ),
    );
  }
}

/// 把「关闭」转成「隐藏」的窗口监听器：用于预热复用的查看器窗口，
/// 关闭时保留引擎与窗口，而非销毁，从而保证下次开图可复用。
class _WindowHideOnCloseListener with WindowListener {
  @override
  void onWindowClose() {
    // 隐藏而非关闭，保留预热引擎。
    windowManager.hide();
  }
}

/// 图片查看器「预热常驻窗口」管理。
///
/// 主窗口启动后（或首次用到时）提前创建一个隐藏的查看器窗口并复用：
/// 之后的每次开图只需向它发送 `load` 命令，省去每次重新创建 engine +
/// 重跑 `main()` 的冷启动开销。
///
/// 复用窗口在「关闭」时会被转换为「隐藏」（见 [_WindowHideOnCloseListener]），
/// 从而保留引擎与命令通道，正常流程下窗口永不销毁、可无限次复用。
/// 仅当引擎意外销毁时，才会在下次 `open` 用「全新 create（新 windowId → 新命令通道）」
/// 重建兜底，规避同一通道重复注册导致的 `CHANNEL_LIMIT_REACHED` / `CHANNEL_MODE_CONFLICT`。
class ImageViewerWindowManager {
  ImageViewerWindowManager._();

  static WindowController? _controller;
  static bool _listening = false;

  /// 确保存在一个隐藏的预热查看器窗口；已存在则直接成功。
  static Future<bool> warm() async {
    if (_controller != null) return true;
    try {
      _controller = await WindowController.create(
        WindowConfiguration(
          arguments:
              const ImageWindowArgs(images: [], index: 0, warm: true).encode(),
          hiddenAtLaunch: true,
        ),
      );
      _listenWindowsChanged();
      return true;
    } catch (e) {
      debugPrint('预热图片查看器窗口失败: $e');
      return false;
    }
  }

  /// 让预热窗口加载 [images]/[index]；窗口未就绪或已销毁时返回 false（调用方回退一次性创建）。
  static Future<bool> open(List<String> images, int index) async {
    try {
      await warm();
      final controller = _controller;
      if (controller == null) return false;
      await controller.invokeMethod('load', <String, dynamic>{
        'images': images,
        'index': index,
      });
      return true;
    } catch (e) {
      debugPrint('复用预热图片查看器窗口失败，回退一次性创建: $e');
      return false;
    }
  }

  /// 监听窗口列表变化：预热窗口被关闭（engine 销毁）时置空，下次 open 重建。
  static void _listenWindowsChanged() {
    if (_listening) return;
    _listening = true;
    onWindowsChanged.listen((_) async {
      final current = _controller;
      if (current == null) return;
      try {
        final all = await WindowController.getAll();
        if (!all.any((w) => w.windowId == current.windowId)) {
          _controller = null;
        }
      } catch (_) {
        // 通道不可用（如测试环境）时忽略。
      }
    });
  }
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

/// 生成「整图缩放至适配视口并居中」的矩阵（contain）。
Matrix4 _fitMatrix(Size viewport, Size img) {
  final scale = fitScale(viewport.width, viewport.height, img.width, img.height);
  final tx = (viewport.width - img.width * scale) / 2;
  final ty = (viewport.height - img.height * scale) / 2;
  return Matrix4.identity()
    ..translateByDouble(tx, ty, 0, 1)
    ..scaleByDouble(scale, scale, 1, 1);
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
  Size? _imageSize;
  Size _viewport = Size.zero;
  Size _lastViewport = Size.zero;
  double _fitScale = 0.01;
  bool _needsFit = true;
  String _title = 'NarrChat 图像查看器';

  ImageStream? _imageStream;
  ImageStreamListener? _imageListener;

  @override
  void initState() {
    super.initState();
    _loadCurrent();
  }

  @override
  void dispose() {
    _removeImageListener();
    _transform.dispose();
    super.dispose();
  }

  void _removeImageListener() {
    final stream = _imageStream;
    final listener = _imageListener;
    if (stream != null && listener != null) {
      stream.removeListener(listener);
    }
    _imageStream = null;
    _imageListener = null;
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
    _removeImageListener();
    _updateTitle();
    setState(() {
      _absPath = null;
      _missing = false;
      _imageSize = null;
      _needsFit = true;
      _transform.value = Matrix4.identity();
    });
    String abs;
    try {
      abs = await ImageStore.resolveAbsolute(widget.images[_index]);
    } catch (_) {
      abs = widget.images[_index];
    }
    if (!mounted) return;
    final provider = FileImage(File(abs));
    final stream = provider.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener(
      (info, _) {
        if (!mounted) return;
        setState(() {
          _absPath = abs;
          // 用「逻辑尺寸」（物理像素 / scale），与 Image 实际渲染尺寸一致。
          _imageSize = Size(
            info.image.width / info.scale,
            info.image.height / info.scale,
          );
          _needsFit = true;
        });
      },
      onError: (_, _) {
        if (!mounted) return;
        setState(() {
          _absPath = abs;
          _imageSize = null;
          _missing = true;
          _needsFit = false;
        });
      },
    );
    stream.addListener(listener);
    _imageStream = stream;
    _imageListener = listener;
  }

  void _prev() {
    if (_index <= 0) return;
    setState(() {
      _index--;
      _absPath = null;
      _missing = false;
      _imageSize = null;
      _needsFit = true;
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
      _imageSize = null;
      _needsFit = true;
      _transform.value = Matrix4.identity();
    });
    _loadCurrent();
  }

  /// 鼠标滚轮缩放（围绕光标），最小到适配态（不缩到更小），随后按图片内容钳制平移。
  void _onWheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final img = _imageSize;
    if (img == null || _viewport == Size.zero) return;
    final factor = event.scrollDelta.dy < 0 ? 1.15 : 0.87;
    _transform.value = zoomAt(
      _transform.value,
      event.localPosition,
      factor,
      minScale: _fitScale,
      maxScale: _maxScale,
    );
    _transform.value = clampTransform(_transform.value, _viewport, img);
  }

  /// 鼠标拖动平移：每次移动先按拖拽增量平移，再实时钳制到图片内容范围。
  void _onPanUpdate(DragUpdateDetails details) {
    final img = _imageSize;
    if (img == null || _viewport == Size.zero) return;
    _transform.value = clampTransform(
      _transform.value.clone()
        ..translateByDouble(details.delta.dx, details.delta.dy, 0, 1),
      _viewport,
      img,
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
              child: LayoutBuilder(
                builder: (context, constraints) {
                  _viewport = Size(
                    constraints.maxWidth,
                    constraints.maxHeight,
                  );
                  _applyFitOrClamp();
                  return Stack(
                    children: [
                      // 图片：InteractiveViewer(constrained:false) 仅作显示（保持图片固有尺寸、
                      // 应用控制器矩阵、并裁剪到视口）；其手势全部禁用。
                      // 手势层以 opaque 位于其上：GestureDetector 接拖动、Listener 接滚轮，
                      // 每次移动都用 clampTransform 精确钳制（未填满轴居中、放大轴贴边），
                      // 不与 InteractiveViewer 手势互相拉扯 → 无漂移、无黑边。
                      Positioned.fill(
                        child: Stack(
                          children: [
                            Positioned.fill(
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
                                          constrained: false,
                                          panEnabled: false,
                                          scaleEnabled: false,
                                          child: Image.file(
                                            File(_absPath!),
                                            fit: BoxFit.contain,
                                            errorBuilder: (_, _, _) =>
                                                MissingImage(
                                                    widget.images[_index]),
                                          ),
                                        ),
                            ),
                            Positioned.fill(
                              child: Listener(
                                onPointerSignal: _onWheel,
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onPanUpdate: _onPanUpdate,
                                ),
                              ),
                            ),
                          ],
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
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 在 build 内同步应用「适配/钳制」：
  /// - 未放大（或缩到适配）→ 复位为适配 + 居中；
  /// - 已放大 → 按图片内容钳制平移（边缘贴窗，不出现黑边）。
  void _applyFitOrClamp() {
    final img = _imageSize;
    if (img == null || _viewport == Size.zero) return;
    final newFit = fitScale(
      _viewport.width,
      _viewport.height,
      img.width,
      img.height,
    );
    _fitScale = newFit;
    // 窗口尺寸变化或首次加载 → 重新「适配并居中」到当前视口。
    final resized = _lastViewport != _viewport;
    _lastViewport = _viewport;
    if (_needsFit || resized) {
      _transform.value = _fitMatrix(_viewport, img);
      _needsFit = false;
    }
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
