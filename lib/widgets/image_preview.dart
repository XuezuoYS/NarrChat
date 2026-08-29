import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:provider/provider.dart';

import '../providers/cloud_sync_provider.dart';
import '../services/clipboard_image_service.dart';
import '../services/image_store.dart';
import '../services/sync/image_deletion.dart';
import '../services/sync/sync_models.dart';
import 'image_viewer_window.dart';

/// 图片缩略图：解析相对路径 → 显示图片；文件缺失显示灰色占位块
/// （破损图标 + 原文件名 + 「图片已丢失」）。
class ImageThumbnail extends StatelessWidget {
  final String relPath;

  /// 缩略图边长。
  final double size;

  /// 是否显示右上角删除按钮。
  final VoidCallback? onRemove;

  /// 点击回调（通常打开全屏查看）。
  final VoidCallback? onTap;

  const ImageThumbnail({
    super.key,
    required this.relPath,
    this.size = 120,
    this.onRemove,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: FutureBuilder<String>(
        future: ImageStore.resolveAbsolute(relPath),
        builder: (context, snapshot) {
          final Widget inner;
          if (snapshot.hasError) {
            inner = MissingImage(relPath);
          } else {
            inner = _FileImage(absPath: snapshot.data ?? '', relPath: relPath);
          }
          if (onTap == null && onRemove == null) return inner;
          return Stack(
            children: [
              if (onTap != null)
                GestureDetector(onTap: onTap, child: inner)
              else
                inner,
              if (onRemove != null)
                Positioned(
                  top: 2,
                  right: 2,
                  child: _RemoveBadge(onPressed: onRemove!),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// 单个已存在图片文件（加载失败回退占位）。
class _FileImage extends StatelessWidget {
  final String absPath;
  final String relPath;

  const _FileImage({required this.absPath, required this.relPath});

  @override
  Widget build(BuildContext context) {
    final file = File(absPath);
    if (!file.existsSync()) return MissingImage(relPath);
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Image.file(
        file,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        errorBuilder: (_, _, _) => MissingImage(relPath),
      ),
    );
  }
}

/// 文件缺失 / 读取失败的灰色占位块。
class MissingImage extends StatelessWidget {
  final String relPath;

  const MissingImage(this.relPath, {super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.all(6),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.broken_image_outlined, size: 24, color: scheme.outline),
          const SizedBox(height: 4),
          Text(
            ImageStore.fileNameOf(relPath),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 10, color: scheme.outline),
          ),
          const SizedBox(height: 2),
          Text('图片已丢失', style: TextStyle(fontSize: 9, color: scheme.outline)),
        ],
      ),
    );
  }
}

/// 缩略图右上角的删除小圆钮。
///
/// 注意：不能用 `Ink(decoration: ...)` 绘制圆钮背景——`Ink` 会把装饰画到最近的
/// `Material` 上，而该 `Material` 在图片之下，导致圆钮的圆底/描边/阴影被图片盖住
/// 而“不生效”。这里改用 `Material` 本体承载颜色/圆角描边/阴影，作为真实 widget
/// 绘制在图片之上，`InkWell` 让点击水波显示在圆钮上。
class _RemoveBadge extends StatelessWidget {
  final VoidCallback onPressed;

  const _RemoveBadge({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.2),
      elevation: 2,
      shape: const CircleBorder(
        // side: BorderSide(color: Colors.black, width: 0),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        customBorder: const CircleBorder(),
        child: const SizedBox(
          width: 18,
          height: 18,
          child: Icon(Icons.close, size: 12, color: Colors.white),
        ),
      ),
    );
  }
}

/// 横向滚动的图片预览条（气泡正文上方 / 输入框待发送上方复用）。
class ImagePreviewStrip extends StatelessWidget {
  final List<String> images;

  /// 点击单张图片回调（`relPath` + 所在序号）。为空则仅缩略图。
  final void Function(String relPath, int index)? onTapImage;

  /// 每张图的可选删除回调。
  final void Function(String relPath)? onRemove;

  final double size;

  const ImagePreviewStrip({
    super.key,
    required this.images,
    this.onTapImage,
    this.onRemove,
    this.size = 96,
  });

  @override
  Widget build(BuildContext context) {
    if (images.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: size,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        shrinkWrap: true,
        itemCount: images.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final rel = images[i];
          return ImageThumbnail(
            relPath: rel,
            size: size,
            onTap: onTapImage == null ? null : () => onTapImage!(rel, i),
            onRemove: onRemove == null ? null : () => onRemove!(rel),
          );
        },
      ),
    );
  }
}

/// 打开图片查看器。
///
/// [images] 为当前一组图片（同一轮次的全部图片），[initialIndex] 为点击的那张序号。
/// - Windows 桌面端：打开**独立系统窗口**（左右箭头 + 滚轮缩放 + 拖动平移）；
/// - 其它平台：主窗口内 photo_view 查看器（左右滑动 + 双指缩放）。
/// [onDeleted]：应用内查看器删除某张图片后的回调（relPath），供调用方同步移除
/// 列表项；桌面独立窗口的删除在窗口内处理，不经过本回调。
Future<void> showImageViewer(
  BuildContext context,
  List<String> images,
  int initialIndex, {
  void Function(String relPath)? onDeleted,
}) async {
  if (Platform.isWindows &&
      await _tryOpenImageViewerWindow(images, initialIndex)) {
    return;
  }
  if (!context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => ImageViewerPage(
        images: images,
        initialIndex: initialIndex,
        onDeleted: onDeleted,
      ),
    ),
  );
}

/// 尝试打开桌面端独立图片查看器窗口；成功返回 true，失败返回 false（调用方回退到应用内查看器）。
Future<bool> _tryOpenImageViewerWindow(
  List<String> images,
  int initialIndex,
) async {
  // 优先复用「预热常驻」查看器窗口（省去每次重新创建 engine 的冷启动）；
  // 未就绪 / 窗口已销毁时返回 false，走下方一次性创建兜底。
  if (await ImageViewerWindowManager.open(images, initialIndex)) return true;
  try {
    await WindowController.create(
      WindowConfiguration(
        arguments: ImageWindowArgs(
          images: images,
          index: initialIndex,
        ).encode(),
        hiddenAtLaunch: true,
      ),
    );
    return true;
  } catch (e) {
    debugPrint('打开图片查看器窗口失败，回退到应用内查看器: $e');
    return false;
  }
}

/// 另存为对话框实现签名（测试可注入替身，避免触碰真实 file_picker 通道）。
///
/// [bytes]：Android/iOS 上 `file_picker` 的 saveFile 必须携带非空字节（原生 SAF
/// 直接写入用户选择的目标）；Windows 上忽略该参数，仅返回用户选择的路径。
typedef SaveImagePicker = Future<String?> Function({
  required String fileName,
  Uint8List? bytes,
});

/// 默认另存为对话框（file_picker：Windows 选路径、Android/iOS 传字节由原生落盘）。
Future<String?> _pickSavePath({required String fileName, Uint8List? bytes}) {
  return FilePicker.platform.saveFile(
    dialogTitle: '保存图片',
    fileName: fileName,
    type: FileType.image,
    bytes: bytes,
  );
}

/// 另存为是否由原生侧直接写入字节（Android/iOS 的 SAF 语义：不经 Dart 复制）。
bool _saveNeedsNativeBytes() => Platform.isAndroid || Platform.isIOS;

/// 将图片另存为用户所选位置（用户取消不提示；失败给出提示）。
///
/// - Android/iOS：读取原图字节交给 [savePicker]（file_picker 经 SAF 直接写入用户
///   选择的目标，返回的只是拼装的展示路径），成功后仅提示「图片已保存」，不再
///   二次复制——分区存储下按返回路径复制会失败，且路径不真实；
/// - Windows：经 [savePicker] 选择路径后，由本函数 `file.copy` 到该路径。
///
/// [savePicker] / [needsNativeBytes] 为测试注入口（缺省走真实平台实现）。
/// 供移动端应用内查看器与桌面端独立窗口查看器复用。
Future<void> saveImageFile(
  BuildContext context, {
  required String relPath,
  required String absPath,
  SaveImagePicker? savePicker,
  bool Function()? needsNativeBytes,
}) async {
  final file = File(absPath);
  if (!file.existsSync()) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('图片文件已丢失，无法保存')));
    }
    return;
  }
  try {
    final nativeWrite = (needsNativeBytes ?? _saveNeedsNativeBytes)();
    final bytes = nativeWrite ? await file.readAsBytes() : null;
    final name = ImageStore.fileNameOf(relPath);
    final outPath = await (savePicker ?? _pickSavePath)(
      fileName: name.isEmpty ? 'image.png' : name,
      bytes: bytes,
    );
    if (outPath == null || !context.mounted) return; // 用户取消（不提示）。
    if (bytes != null) {
      // 原生 SAF 已完成写入：outPath 只是插件拼装的展示路径，不再复制。
      _showViewerSnack(context, '图片已保存');
      return;
    }
    await file.copy(outPath);
    if (context.mounted) _showViewerSnack(context, '已保存到 $outPath');
  } catch (_) {
    if (context.mounted) _showViewerSnack(context, '保存失败，请重试');
  }
}

/// 查看器「复制图片」：读取图片字节写入系统剪贴板。
Future<void> copyImageFile(
  BuildContext context, {
  required String relPath,
  required String absPath,
  ClipboardImageWriter writer = const SystemClipboardImageWriter(),
}) async {
  final file = File(absPath);
  if (!file.existsSync()) {
    _showViewerSnack(context, '图片文件已丢失，无法复制');
    return;
  }
  try {
    await writer.writeImage(absPath: absPath, bytes: await file.readAsBytes());
    if (context.mounted) _showViewerSnack(context, '图片已复制到剪贴板');
  } catch (_) {
    if (context.mounted) _showViewerSnack(context, '复制失败，请重试');
  }
}

/// 查看器「删除图片」：二次确认后删除本机文件并登记删除墓碑（与图片库删除同一
/// 全局语义：删除后引用它的剧情显示为缺失，同步后云端与其它设备一并删除）。
///
/// - [deletionService] 为 null 时从 [context] 读取 Provider 注册的
///   [ImageDeletionService]（主窗口内使用），并顺带触发图片平面同步；
///   桌面独立查看器窗口无 Provider 树，由调用方直接传入实现。
/// - 删除成功时调用 [onDeleted]（查看器用于移除当前项 / 更新页码）。
/// 返回是否已删除（取消 / 失败为 false）。
Future<bool> deleteImageFile(
  BuildContext context, {
  required String relPath,
  ImageDeletionService? deletionService,
  VoidCallback? onDeleted,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('删除图片'),
      content: Text(
        '将删除「${ImageStore.fileNameOf(relPath)}」。删除后，引用它的剧情将显示为缺失，'
        '同步后云端与其它设备也会一并删除。确定删除吗？',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(ctx).colorScheme.error,
          ),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('删除'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return false;
  final service = deletionService ?? context.read<ImageDeletionService>();
  try {
    await service.delete(relPath);
  } catch (_) {
    if (context.mounted) _showViewerSnack(context, '删除失败，请重试');
    return false;
  }
  if (!context.mounted) return true;
  if (deletionService == null) {
    // 删除意图尽快推送到云端（仅图片平面；未配置 / 手动模式内部忽略）。
    context.read<CloudSyncProvider?>()?.triggerSync(kind: SyncKind.images);
  }
  _showViewerSnack(context, '已删除');
  onDeleted?.call();
  return true;
}

/// 查看器动作菜单项。
enum ImageViewerAction { saveAs, copy, delete }

/// 查看器长按（触屏）/ 右键（鼠标）操作菜单：另存为 / 复制图片 / 删除。
///
/// 复制图片仅桌面端（Windows）展示：Android 上剪贴板图片是 pasteboard 原生重编码的
/// **PNG 像素**（原始 JPEG 等格式不保留），与桌面端「保留原始文件」语义不一致，
/// 故 Android **移除「复制图片」**，仅保留另存为 / 删除。
///
/// [globalPosition] 为触发事件的位置（全局坐标），菜单在该处展开；
/// [canCopyImage] 为测试注入口（缺省 = 非 Android 平台）；
/// 其余参数语义见 [saveImageFile] / [copyImageFile] / [deleteImageFile]。
Future<void> showImageViewerMenu(
  BuildContext context, {
  required String relPath,
  required String? absPath,
  required Offset globalPosition,
  ImageDeletionService? deletionService,
  VoidCallback? onDeleted,
  bool Function()? canCopyImage,
}) async {
  final overlay = Overlay.of(context).context.findRenderObject();
  if (overlay is! RenderBox) return;
  final position = RelativeRect.fromLTRB(
    globalPosition.dx,
    globalPosition.dy,
    overlay.size.width - globalPosition.dx,
    overlay.size.height - globalPosition.dy,
  );

  PopupMenuItem<ImageViewerAction> menuItem(
    IconData icon,
    String label,
    ImageViewerAction value, {
    bool danger = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final fg = danger ? scheme.error : scheme.onSurface;
    return PopupMenuItem<ImageViewerAction>(
      value: value,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 20, color: fg),
          const SizedBox(width: 10),
          Text(label, style: danger ? TextStyle(color: fg) : null),
        ],
      ),
    );
  }

  final action = await showMenu<ImageViewerAction>(
    context: context,
    position: position,
    items: [
      menuItem(Icons.save_alt, '另存为', ImageViewerAction.saveAs),
      if ((canCopyImage ?? _canCopyImage)())
        menuItem(Icons.copy_outlined, '复制图片', ImageViewerAction.copy),
      menuItem(
        Icons.delete_outline,
        '删除',
        ImageViewerAction.delete,
        danger: true,
      ),
    ],
  );
  if (action == null || !context.mounted) return;
  final abs = absPath;
  switch (action) {
    case ImageViewerAction.saveAs:
      saveImageFile(context, relPath: relPath, absPath: abs ?? '');
    case ImageViewerAction.copy:
      if (abs == null || abs.isEmpty) {
        _showViewerSnack(context, '图片文件已丢失，无法复制');
      } else {
        await copyImageFile(context, relPath: relPath, absPath: abs);
      }
    case ImageViewerAction.delete:
      await deleteImageFile(
        context,
        relPath: relPath,
        deletionService: deletionService,
        onDeleted: onDeleted,
      );
  }
}

void _showViewerSnack(BuildContext context, String message) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

/// 是否展示「复制图片」菜单项：Android 剪贴板图片为 PNG 重编码（原格式不保留），
/// 与桌面端保留原始文件的语义不一致 → Android 不展示（仅另存为 / 删除）。
bool _canCopyImage() => !Platform.isAndroid;

/// 移动端图片查看器「单击」决策：未放大（initial）时单击退出，否则缩回未放大。
///
/// QQ 手机端体验：未放大单击关闭预览；放大状态单击即回到未放大。
bool shouldExitPreviewOnTap(PhotoViewScaleState state) =>
    state == PhotoViewScaleState.initial;

/// 移动端图片查看器「双击」循环：未放大→铺满放大；任意放大态→回到未放大。
///
/// 覆盖 photo_view 默认（initial→covering→originalSize→initial 的多级循环），
/// 改成「未放大双击放大、放大双击一定回到未放大」的单级循环。
PhotoViewScaleState mobileDoubleTapCycle(PhotoViewScaleState state) =>
    state == PhotoViewScaleState.initial
    ? PhotoViewScaleState.covering
    : PhotoViewScaleState.initial;

/// 下滑关闭：松手判定距离阈值 = 屏高 × 此比例（慢速拖到底）。
const double _kDismissCommitDistanceRatio = 0.3;

/// 下滑关闭：松手瞬间向下的速度阈值（px/s，快速下甩即关闭）。
const double _kDismissCommitVelocity = 1000;

/// 下滑关闭：视觉满程（缩小 + 淡出达最大）对应的拖动距离 = 屏高 × 此比例。
const double _kDismissVisualRangeRatio = 0.4;

/// 下滑关闭：满程时内容额外缩小比例（1.0 → 1.0 - 此值）。
const double _kDismissMaxScale = 0.12;

/// 下滑关闭：满程时内容淡出的最大不透明度损失（1.0 → 1.0 - 此值）。
const double _kDismissMaxFade = 0.6;

/// 触屏「下滑关闭」松手判定（QQ / 小米相册体验）：
/// 未放大时向下拖动，松手满足任一条件即滑出关闭，否则回弹复位：
/// - 拖动距离 ≥ 屏高 × [_kDismissCommitDistanceRatio]（慢速拖到底）；
/// - 松手瞬间向下速度 ≥ [_kDismissCommitVelocity]（px/s，快速下甩）。
bool shouldDismissOnDragEnd({
  required double dragDistance,
  required double flingVelocity,
  required double screenHeight,
}) {
  return dragDistance >= screenHeight * _kDismissCommitDistanceRatio ||
      flingVelocity >= _kDismissCommitVelocity;
}

/// 全屏图片查看页：左右滑动切换 + 双指缩放（photo_view）。
///
/// - 未放大时左右滑动 → 上一张 / 下一张；放大后可平移查看、缩回后再滑动切换；
/// - 双指缩放可扩展至铺满全屏（覆盖画面），不再被“原比例留黑边”限制；
/// - 顶部显示页码（如 2/5）与关闭按钮；保存/复制/删除经长按（右键）菜单；
/// - 单击：未放大→退出查看器；放大状态→缩回未放大（QQ 手机端体验）；
/// - 双击：未放大→放大；放大状态→缩回未放大（QQ 手机端体验）；
/// - 触屏下滑（未放大态）：向下拖动时内容随指下移/缩小/淡出，松手超过阈值
///   （屏高 30% 或快速下甩）滑出关闭，否则回弹复位（QQ / 小米相册体验）。
class ImageViewerPage extends StatefulWidget {
  final List<String> images;
  final int initialIndex;

  /// 某张图片被删除后的回调（relPath），供调用方同步移除列表项。
  final void Function(String relPath)? onDeleted;

  const ImageViewerPage({
    super.key,
    required this.images,
    this.initialIndex = 0,
    this.onDeleted,
  });

  @override
  State<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<ImageViewerPage>
    with SingleTickerProviderStateMixin {
  late final PageController _pageController = PageController(
    initialPage: widget.initialIndex,
  );
  late int _index = widget.initialIndex;

  // 本页持有的可变图片列表：长按/右键删除后移除当前项并更新页码/画布。
  late final List<String> _images = List.of(widget.images);

  // 每个页面一个缩放状态控制器，用于单击时判断「是否放大」并驱动「缩回未放大」。
  // 数量固定为初始图片总数（删除后只减少，索引始终与 _images 前缀对齐）。
  late final List<PhotoViewScaleStateController> _scaleControllers =
      List.generate(
        widget.images.length,
        (_) => PhotoViewScaleStateController(),
      );

  // ---------- 触屏下滑关闭（QQ / 小米相册体验）状态 ----------

  /// 当前页是否「未放大」（initial）：未放大才挂载下滑关闭识别器。
  ///
  /// 放大后必须摘除该识别器：photo_view 的缩放识别器自身需 36px 位移才赢得
  /// 手势竞技场，若下滑识别器常驻，会在 18px 处抢先，导致放大态的垂直拖动平移失效。
  bool get _dismissEnabled =>
      _scaleControllers[_index].scaleState == PhotoViewScaleState.initial;

  /// 当前按下指针是否为触屏（下滑关闭仅对触屏生效）。
  bool _dismissPointerIsTouch = false;

  /// 当前向下拖动距离（≥ 0；内容随指下移，松手后回弹或滑出关闭）。
  double _dismissDrag = 0;

  /// 是否正在拖拽中（松手 / 取消后置 false）。
  bool _dismissDragging = false;

  /// 滑出关闭动画是否进行中（期间不再识别新的下滑）。
  bool _dismissClosing = false;

  /// 回弹 / 滑出动画控制器与当前动画曲线（null = 无进行中的动画）。
  late final AnimationController _dismissController = AnimationController(
    vsync: this,
  )..addListener(_onDismissAnimate);
  Animatable<double>? _dismissAnim;

  // 已解析的绝对路径（与 _images 等长有序对应；null = 解析中 / 删除后待重解析）。
  // 单个解析失败（如测试环境无 path_provider）时回退相对路径，交由
  // PhotoView 的 errorBuilder 显示占位，避免整批失败导致无限加载转圈。
  List<String>? _absPaths;
  int _resolveToken = 0;

  @override
  void initState() {
    super.initState();
    _resolvePaths();
    // 监听每页缩放状态：未放大 ⇄ 放大切换时决定下滑识别器挂载 / 摘除。
    for (final c in _scaleControllers) {
      c.addIgnorableListener(_onScaleStateChanged);
    }
  }

  /// 任一页缩放状态变化时重建：[_dismissEnabled] 据此挂载 / 摘除下滑识别器。
  void _onScaleStateChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _resolvePaths() async {
    final token = ++_resolveToken;
    final paths = await Future.wait(
      _images.map((rel) async {
        try {
          return await ImageStore.resolveAbsolute(rel);
        } catch (_) {
          return rel;
        }
      }),
    );
    if (!mounted || token != _resolveToken) return;
    // 解析期间列表发生过增删时丢弃该次结果（删除路径会再触发一次解析）。
    if (paths.length != _images.length) return;
    setState(() => _absPaths = paths);
  }

  @override
  void dispose() {
    for (final c in _scaleControllers) {
      c.removeIgnorableListener(_onScaleStateChanged);
    }
    _dismissController.dispose();
    _pageController.dispose();
    for (final c in _scaleControllers) {
      c.dispose();
    }
    super.dispose();
  }

  /// 长按（触屏）/ 右键（鼠标）弹出当前图片的操作菜单（另存为 / 复制 / 删除）。
  ///
  /// 删除服务经 Provider 读取（本机文件 + 同步墓碑 + 触发云端同步）；
  /// 删除成功后经 [onDeleted] 回调到 [_onImageDeleted] 更新本页列表。
  void _showActionMenu(Offset globalPosition) {
    final rel = _images[_index];
    showImageViewerMenu(
      context,
      relPath: rel,
      // 解析未完成时为 null：复制/保存给出「文件丢失」提示，删除不受影响。
      absPath: _absPaths?[_index],
      globalPosition: globalPosition,
      onDeleted: () => _onImageDeleted(rel),
    );
  }

  /// 图片删除成功后的本地状态更新：移除当前项并更新页码/画布；最后一张则关闭查看器。
  void _onImageDeleted(String rel) {
    if (!mounted) return;
    widget.onDeleted?.call(rel);
    if (_images.length == 1) {
      // 最后一张：直接关闭查看器。
      Navigator.of(context).pop();
      return;
    }
    final removedIndex = _images.indexOf(rel);
    if (removedIndex < 0) return;
    final nextIndex = removedIndex >= _images.length - 1
        ? _images.length - 2
        : removedIndex;
    // 复位被删页的缩放状态（其控制器可能被复用给下一张图）。
    _scaleControllers[removedIndex].scaleState = PhotoViewScaleState.initial;
    setState(() {
      _images.removeAt(removedIndex);
      _index = nextIndex;
      final abs = _absPaths;
      if (abs != null && abs.length == _images.length + 1) {
        abs.removeAt(removedIndex);
      } else {
        // 解析仍在进行：置空并重新解析，保证 _absPaths 与 _images 对齐。
        _absPaths = null;
      }
    });
    if (_pageController.hasClients) _pageController.jumpToPage(nextIndex);
    if (_absPaths == null) _resolvePaths();
  }

  // ---------- 触屏下滑关闭（QQ / 小米相册体验）----------

  /// 下滑开始：非触屏忽略；若回弹动画进行中则中断，从当前位置继续拖拽。
  void _onDismissDragStart(DragStartDetails details) {
    if (!_dismissPointerIsTouch || _dismissClosing) return;
    _dismissController.stop();
    _dismissAnim = null;
    setState(() => _dismissDragging = true);
  }

  /// 下滑更新：内容随指下移（向上拖动只收不回放，距离以 0 为下限）。
  void _onDismissDragUpdate(DragUpdateDetails details) {
    if (!_dismissDragging) return;
    setState(() {
      _dismissDrag = math.max(0, _dismissDrag + details.delta.dy);
    });
  }

  /// 下滑松手：超过阈值滑出关闭，否则回弹复位。
  void _onDismissDragEnd(DragEndDetails details) {
    if (!_dismissDragging) return;
    setState(() => _dismissDragging = false);
    final screenHeight = MediaQuery.sizeOf(context).height;
    if (shouldDismissOnDragEnd(
      dragDistance: _dismissDrag,
      flingVelocity: details.primaryVelocity ?? 0,
      screenHeight: screenHeight,
    )) {
      _startDismissExit();
    } else {
      _animateDismiss(
        end: 0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    }
  }

  /// 下滑被取消（如双指接管缩放）：回弹复位。
  void _onDismissDragCancel() {
    if (!_dismissDragging) return;
    setState(() => _dismissDragging = false);
    _animateDismiss(
      end: 0,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  /// 松手超过阈值：内容继续向下滑出（缩小 + 淡出）后关闭查看器。
  void _startDismissExit() {
    setState(() => _dismissClosing = true);
    _animateDismiss(
      end: MediaQuery.sizeOf(context).height * 1.2,
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeIn,
      onComplete: () {
        if (mounted) Navigator.of(context).pop();
      },
    );
  }

  /// 把 [_dismissDrag] 从当前值动画到 [end]（回弹复位或滑出关闭）。
  void _animateDismiss({
    required double end,
    required Duration duration,
    required Curve curve,
    VoidCallback? onComplete,
  }) {
    _dismissAnim = Tween(
      begin: _dismissDrag,
      end: end,
    ).chain(CurveTween(curve: curve));
    _dismissController
      ..duration = duration
      ..reset();
    final future = _dismissController.forward();
    if (onComplete != null) {
      future.whenComplete(() {
        if (mounted) onComplete();
      });
    }
  }

  /// 动画帧监听：驱动 [_dismissDrag] 更新（重建画面位移 / 缩放 / 淡出）。
  void _onDismissAnimate() {
    final anim = _dismissAnim;
    if (anim == null) return;
    setState(() => _dismissDrag = anim.transform(_dismissController.value));
  }

  /// 触屏下滑关闭手势层：仅当前页未放大且未在滑出时挂载（说明见 [_dismissEnabled]）。
  Widget _buildDismissGesture(Widget child) {
    if (!_dismissEnabled || _dismissClosing) return child;
    return Listener(
      onPointerDown: (event) =>
          _dismissPointerIsTouch = event.kind == PointerDeviceKind.touch,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onVerticalDragStart: _onDismissDragStart,
        onVerticalDragUpdate: _onDismissDragUpdate,
        onVerticalDragEnd: _onDismissDragEnd,
        onVerticalDragCancel: _onDismissDragCancel,
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final absPaths = _absPaths;
    final screenHeight = MediaQuery.sizeOf(context).height;
    // 视觉进度（0..1）：拖动距离 → 缩小 + 淡出程度（QQ / 小米相册式随手下移淡出）。
    final dismissProgress = screenHeight <= 0
        ? 0.0
        : (_dismissDrag / (screenHeight * _kDismissVisualRangeRatio)).clamp(
            0.0,
            1.0,
          );
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: _buildDismissGesture(
          Opacity(
            opacity: 1 - _kDismissMaxFade * dismissProgress,
            child: Transform.translate(
              offset: Offset(0, _dismissDrag),
              child: Transform.scale(
                scale: 1 - _kDismissMaxScale * dismissProgress,
                child: Stack(
                  children: [
                    // 图片画布：PhotoViewGallery（左右滑动换图 + 双指缩放；单击退出）。
                    // 长按（触屏）/ 右键（鼠标）弹出操作菜单：长按识别器持按 500ms 后
                    // 在竞技场获胜，与 photo_view 单击退出 / 双击缩放置斥，不会误触发。
                    Positioned.fill(
                      child: GestureDetector(
                        key: const Key('image_viewer_canvas'),
                        onLongPressStart: (details) =>
                            _showActionMenu(details.globalPosition),
                        onSecondaryTapDown: (details) =>
                            _showActionMenu(details.globalPosition),
                        child: absPaths == null
                            ? const Center(
                                child: Icon(
                                  Icons.image_outlined,
                                  color: Colors.white24,
                                  size: 48,
                                ),
                              )
                            : PhotoViewGallery(
                                pageController: _pageController,
                                backgroundDecoration: const BoxDecoration(
                                  color: Colors.black,
                                ),
                                onPageChanged: (i) =>
                                    setState(() => _index = i),
                                pageOptions: [
                                  for (var i = 0; i < _images.length; i++)
                                    PhotoViewGalleryPageOptions(
                                      imageProvider: FileImage(
                                        File(absPaths[i]),
                                      ),
                                      errorBuilder:
                                          (context, error, stackTrace) =>
                                              MissingImage(_images[i]),
                                      // 初始整图可见（contained）；双指放大可扩展到铺满全屏并继续放大。
                                      minScale:
                                          PhotoViewComputedScale.contained,
                                      maxScale:
                                          PhotoViewComputedScale.covered * 3,
                                      // 每页独立缩放状态：单击据此判断「放大态→缩回」还是「未放大→退出」。
                                      scaleStateController:
                                          _scaleControllers[i],
                                      // 双击：未放大→铺满放大；任意放大态→回到未放大（QQ 手机端体验）。
                                      scaleStateCycle: mobileDoubleTapCycle,
                                      // 单击：未放大→退出查看器；放大状态→缩回未放大（QQ 手机端体验）。
                                      onTapUp: (ctx, _, _) {
                                        if (shouldExitPreviewOnTap(
                                          _scaleControllers[_index].scaleState,
                                        )) {
                                          Navigator.of(ctx).pop();
                                        } else {
                                          _scaleControllers[_index].scaleState =
                                              PhotoViewScaleState.initial;
                                        }
                                      },
                                    ),
                                ],
                              ),
                      ),
                    ),
                    // 顶部页码指示（如 2/5）。
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              '${_index + 1}/${_images.length}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    // 右上角关闭按钮。
                    Positioned(
                      top: 0,
                      right: 0,
                      child: IconButton(
                        icon: const Icon(Icons.close, color: Colors.white),
                        tooltip: '关闭',
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
