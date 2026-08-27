import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/cloud_sync_provider.dart';
import '../services/image_store.dart';
import '../services/storage_service.dart';
import '../services/sync/image_deletion.dart';
import '../services/sync/sync_models.dart';
import '../theme/app_theme.dart';
import '../widgets/image_preview.dart';

/// 本地图片库（二级页面）：按「小米相册」风格设计。
///
/// - 全屏沉浸网格，按修改日期分组（吸顶日期头，今天 / 昨天 / 日期）；
/// - 点击图片全屏查看（左右滑动切换）；
/// - 右上角「选择」或**长按图片**进入多选模式：点选打勾、顶部显示已选数量，
///   底部滑出操作条（全选 / 取消全选、批量导出、删除）；
/// - 批量导出到指定文件夹；删除二次确认，完成后刷新并退出选择模式。
class ImageGalleryPage extends StatefulWidget {
  /// 目录选择回调（测试注入替身；缺省用 [FilePicker.platform.getDirectoryPath]）。
  final Future<String?> Function()? directoryPicker;

  const ImageGalleryPage({super.key, this.directoryPicker});

  @override
  State<ImageGalleryPage> createState() => _ImageGalleryPageState();
}

class _ImageGalleryPageState extends State<ImageGalleryPage> {
  StorageService get _service => context.read<StorageService>();

  List<StorageImageInfo>? _images;
  bool _loading = true;
  bool _selectMode = false;
  bool _deleting = false;
  bool _exporting = false;
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<String?> _pickDirectory() {
    final custom = widget.directoryPicker;
    if (custom != null) return custom();
    return FilePicker.platform.getDirectoryPath(dialogTitle: '选择导出文件夹');
  }

  Future<void> _load() async {
    try {
      final list = await _service.listImages();
      if (mounted) {
        setState(() {
          _images = list;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _images = const [];
          _loading = false;
        });
      }
    }
  }

  List<String> get _relPaths =>
      [for (final i in _images ?? const <StorageImageInfo>[]) i.relPath];

  void _toggleSelectMode() {
    setState(() {
      _selectMode = !_selectMode;
      _selected.clear();
    });
  }

  void _onTapTile(StorageImageInfo info, int index) {
    if (_selectMode) {
      setState(() {
        if (_selected.contains(info.relPath)) {
          _selected.remove(info.relPath);
        } else {
          _selected.add(info.relPath);
        }
      });
      return;
    }
    final paths = _relPaths;
    if (paths.isEmpty) return;
    showImageViewer(context, paths, index);
  }

  /// 长按进入选择模式并选中该张（若已在选择模式则等同于点选）。
  void _onLongPressTile(StorageImageInfo info) {
    if (!_selectMode) {
      setState(() {
        _selectMode = true;
        _selected.add(info.relPath);
      });
      return;
    }
    _onTapTile(info, _relPaths.indexOf(info.relPath));
  }

  Future<void> _exportSelected() async {
    final dirPath = await _pickDirectory();
    if (dirPath == null || !mounted) return;
    final relPaths = _selected.toList();
    setState(() => _exporting = true);
    try {
      final count = await _service.exportImages(
        relPaths: relPaths,
        targetDirPath: dirPath,
      );
      if (mounted) {
        final message = count == relPaths.length
            ? '已导出 $count 张到 $dirPath'
            : '已导出 $count/${relPaths.length} 张到 $dirPath（部分图片缺失或失败）';
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导出失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  void _toggleSelectAll() {
    setState(() {
      if (_selected.length == (_images?.length ?? 0)) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll([for (final i in _images ?? const <StorageImageInfo>[]) i.relPath]);
      }
    });
  }

  Future<void> _deleteSelected() async {
    final count = _selected.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除图片'),
        content: Text('将删除已选的 $count 张图片。删除后，引用它们的剧情将显示为缺失，'
            '同步后云端与其它设备也会一并删除。确定删除吗？'),
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
    if (confirmed != true || !mounted) return;
    setState(() => _deleting = true);
    final deletion = context.read<ImageDeletionService>();
    var failed = 0;
    for (final rel in _selected) {
      try {
        // 删本机文件 + 记录删除墓碑：同步据此删除云端并传播到其它设备。
        await deletion.delete(rel);
      } catch (_) {
        failed++;
      }
    }
    if (!mounted) return;
    setState(() {
      _deleting = false;
      _selectMode = false;
      _selected.clear();
    });
    // 删除意图尽快推送到云端（仅图片平面：墓碑 + blob 收敛，不涉数据；
    // 自动模式；未配置/手动模式内部忽略）。
    context
        .read<CloudSyncProvider?>()
        ?.triggerSync(kind: SyncKind.images);
    await _load();
    if (mounted) {
      final messenger = ScaffoldMessenger.of(context);
      messenger.showSnackBar(
        SnackBar(
          content: Text(failed == 0 ? '已删除' : '已删除，$failed 张删除失败'),
        ),
      );
    }
  }

  String _dateLabel(DateTime d) {
    final day = DateTime(d.year, d.month, d.day);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return '今天';
    if (diff == 1) return '昨天';
    return '${d.year}年${d.month}月${d.day}日';
  }

  List<({String label, List<StorageImageInfo> items})> _group() {
    final groups = <({String label, List<StorageImageInfo> items})>[];
    for (final info in _images ?? const <StorageImageInfo>[]) {
      final label = _dateLabel(info.modified);
      if (groups.isEmpty || groups.last.label != label) {
        groups.add((label: label, items: [info]));
      } else {
        groups.last.items.add(info);
      }
    }
    return groups;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    final allSelected =
        _images != null && _images!.isNotEmpty && _selected.length == _images!.length;
    return Scaffold(
      backgroundColor: colors.surface,
      appBar: AppBar(
        backgroundColor: colors.surface,
        leading: _selectMode
            ? IconButton(
                icon: const Icon(Icons.close),
                tooltip: '取消',
                onPressed: _toggleSelectMode,
              )
            : null,
        title: Text(_selectMode ? '已选 ${_selected.length} 张' : '图片库'),
        actions: [
          if (_images != null && _images!.isNotEmpty)
            TextButton.icon(
              onPressed: _selectMode ? _toggleSelectMode : _toggleSelectMode,
              icon: Icon(
                _selectMode ? Icons.done : Icons.checklist,
                size: 18,
              ),
              label: Text(_selectMode ? '完成' : '选择'),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : (_images == null || _images!.isEmpty)
              ? _buildEmpty(colors)
              : _buildGrid(colors, allSelected),
    );
  }

  Widget _buildEmpty(NarrChatColors colors) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.photo_library_outlined, size: 48, color: colors.textSecondary),
          const SizedBox(height: 10),
          Text(
            '暂无本地图片',
            style: TextStyle(fontSize: 13, color: colors.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _buildGrid(NarrChatColors colors, bool allSelected) {
    final groups = _group();
    return Stack(
      children: [
        CustomScrollView(
          slivers: [
            const SliverToBoxAdapter(child: SizedBox(height: 8)),
            for (final g in groups) ...[
              SliverPersistentHeader(
                pinned: true,
                delegate: _DateHeaderDelegate(label: g.label),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                sliver: SliverGrid(
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 132,
                    mainAxisSpacing: 4,
                    crossAxisSpacing: 4,
                    childAspectRatio: 1,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, i) {
                      final info = g.items[i];
                      final index = _relPaths.indexOf(info.relPath);
                      return _GalleryTile(
                        key: ValueKey('gallery_tile:${info.relPath}'),
                        info: info,
                        selectMode: _selectMode,
                        selected: _selected.contains(info.relPath),
                        onTap: () => _onTapTile(info, index),
                        onLongPress: () => _onLongPressTile(info),
                      );
                    },
                    childCount: g.items.length,
                  ),
                ),
              ),
            ],
            const SliverToBoxAdapter(child: SizedBox(height: 96)),
          ],
        ),
        // 底部操作条（选择模式下可见）。
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: _BottomActionBar(
            visible: _selectMode,
            allSelected: allSelected,
            deleting: _deleting,
            exporting: _exporting,
            onCancel: _toggleSelectMode,
            onToggleAll: _toggleSelectAll,
            onExport: _exportSelected,
            onDelete: _deleteSelected,
          ),
        ),
      ],
    );
  }
}

/// 吸顶日期头。
class _DateHeaderDelegate extends SliverPersistentHeaderDelegate {
  final String label;
  const _DateHeaderDelegate({required this.label});

  @override
  double get minExtent => 34;
  @override
  double get maxExtent => 34;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final colors = context.narrColors;
    return Container(
      color: colors.surface,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
      alignment: Alignment.centerLeft,
      child: Text(
        label,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: colors.textPrimary,
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(_DateHeaderDelegate oldDelegate) =>
      oldDelegate.label != label;
}

/// 单张图片网格块：缩略图 + 选择态遮罩 / 勾选。
class _GalleryTile extends StatelessWidget {
  final StorageImageInfo info;
  final bool selectMode;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _GalleryTile({
    super.key,
    required this.info,
    required this.selectMode,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          fit: StackFit.expand,
          children: [
            _thumb(context),
            // 选中遮罩 + 勾选角标（仅选择模式）。
            if (selectMode)
              AnimatedOpacity(
                opacity: selected ? 1 : 0,
                duration: const Duration(milliseconds: 150),
                child: Container(
                  color: Colors.black.withValues(alpha: 0.28),
                  alignment: Alignment.topRight,
                  padding: const EdgeInsets.all(6),
                  child: Icon(
                    selected
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    size: 22,
                    color: selected ? scheme.primary : Colors.white70,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _thumb(BuildContext context) {
    final colors = context.narrColors;
    return FutureBuilder<String>(
      future: ImageStore.resolveAbsolute(info.relPath),
      builder: (context, snapshot) {
        final path = snapshot.data;
        final file = (path == null || path.isEmpty) ? null : File(path);
        if (file == null || !file.existsSync()) {
          return Container(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            alignment: Alignment.center,
            child: Icon(
              Icons.image_outlined,
              size: 28,
              color: colors.textSecondary,
            ),
          );
        }
        return Image.file(
          file,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => Container(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            alignment: Alignment.center,
            child: Icon(
              Icons.broken_image_outlined,
              size: 28,
              color: colors.textSecondary,
            ),
          ),
        );
      },
    );
  }
}

/// 底部操作条：取消 + 全选 / 取消全选 + 删除（带滑入动画）。
class _BottomActionBar extends StatelessWidget {
  final bool visible;
  final bool allSelected;
  final bool deleting;
  final bool exporting;
  final VoidCallback onCancel;
  final VoidCallback onToggleAll;
  final VoidCallback onExport;
  final VoidCallback onDelete;

  const _BottomActionBar({
    required this.visible,
    required this.allSelected,
    required this.deleting,
    required this.exporting,
    required this.onCancel,
    required this.onToggleAll,
    required this.onExport,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    final processing = deleting || exporting;
    return AnimatedSlide(
      offset: visible ? Offset.zero : const Offset(0, 1.2),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 150),
        child: Material(
          color: colors.surface,
          elevation: 8,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: [
                  TextButton.icon(
                    onPressed: processing ? null : onCancel,
                    icon: const Icon(Icons.close, size: 18),
                    label: const Text('取消'),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: processing ? null : onToggleAll,
                    icon: const Icon(Icons.done_all, size: 18),
                    label: Text(allSelected ? '取消全选' : '全选'),
                  ),
                  const SizedBox(width: 4),
                  OutlinedButton.icon(
                    onPressed: deleting ? null : onExport,
                    icon: const Icon(Icons.drive_file_move_outline, size: 18),
                    label: Text(exporting ? '导出中…' : '导出'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: exporting ? null : onDelete,
                    style: FilledButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.error,
                      foregroundColor: Colors.white,
                    ),
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: Text(deleting ? '删除中…' : '删除'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
