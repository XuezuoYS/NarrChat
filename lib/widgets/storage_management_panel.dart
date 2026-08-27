import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../providers/cloud_sync_provider.dart';
import '../screens/database_merge_screen.dart';
import '../screens/image_gallery_page.dart';
import '../services/app_paths.dart';
import '../services/database_merge_service.dart';
import '../services/storage_service.dart';
import '../theme/app_theme.dart';
import '../utils/focus_utils.dart';
import '../utils/formats.dart';

/// 设置页「存储管理」面板。
///
/// - **本地数据库导出/导入**：展示数据库路径 / 大小 / 修改时间，选择目标文件夹并
///   以自定义文件名导出（SQLite 开启 WAL 时会连同 `-wal`/`-shm` 一并复制），
///   或从本机 `.db` 备份导入并逐本确认合并；
/// - **本地/云端图片管理**：列出 `img/` 目录下全部图片（按修改时间倒序），提供
///   全屏查看、删除（带确认）与刷新，并显示图片总数与占用空间。图片库与云同步
///   联动：删除是全局语义（同步删云端并传播到其它设备），其它设备新增的图片
///   同步后也会出现在本地。
class StorageManagementPanel extends StatefulWidget {
  /// 目录选择回调（测试注入替身；缺省用 [FilePicker.platform.getDirectoryPath]）。
  final Future<String?> Function()? directoryPicker;

  /// 数据库文件选择回调（测试注入替身；缺省用 [FilePicker.platform.pickFiles]）。
  final Future<String?> Function()? filePicker;

  const StorageManagementPanel({
    super.key,
    this.directoryPicker,
    this.filePicker,
  });

  @override
  State<StorageManagementPanel> createState() =>
      _StorageManagementPanelState();
}

class _StorageManagementPanelState extends State<StorageManagementPanel> {
  late Future<StorageDbInfo?> _dbFuture;
  // 图片列表用状态持有（而非 FutureBuilder 换 future），删除/刷新后重载更确定。
  List<StorageImageInfo>? _images;
  bool _imagesLoading = true;
  bool _exporting = false;
  bool _importing = false;

  StorageService get _service => context.read<StorageService>();

  @override
  void initState() {
    super.initState();
    _dbFuture = _service.dbInfo();
    _loadImages();
  }

  /// 重新加载图片列表（加载中置 loading，完成后写回状态）。
  void _loadImages() {
    setState(() => _imagesLoading = true);
    _loadImagesAsync();
  }

  Future<void> _loadImagesAsync() async {
    try {
      final list = await _service.listImages();
      if (mounted) {
        setState(() {
          _images = list;
          _imagesLoading = false;
        });
      }
    } catch (_) {
      // 读取失败：置空，避免挂在加载态。
      if (mounted) {
        setState(() {
          _images = const [];
          _imagesLoading = false;
        });
      }
    }
  }

  Future<String?> _pickDirectory() {
    final custom = widget.directoryPicker;
    if (custom != null) return custom();
    return FilePicker.platform.getDirectoryPath(dialogTitle: '选择数据库导出文件夹');
  }

  String _defaultExportName() {
    final now = DateTime.now();
    final ts =
        '${now.year}-${Formats.two(now.month)}-${Formats.two(now.day)}_'
        '${Formats.two(now.hour)}-${Formats.two(now.minute)}-${Formats.two(now.second)}';
    return 'narrchat_$ts.db';
  }

  /// 弹出「导出文件名」对话框，返回规范化后的文件名（取消返回 null）。
  Future<String?> _askExportName() async {
    final result = await showDialog<String>(
      context: context,
      builder: (_) => _ExportNameDialog(initialName: _defaultExportName()),
    );
    if (result == null) return null;
    var name = result.trim();
    if (name.isEmpty) return null;
    if (!name.toLowerCase().endsWith('.db')) name = '$name.db';
    return name;
  }

  Future<void> _exportDatabase() async {
    final dirPath = await _pickDirectory();
    if (dirPath == null || !mounted) return;
    final name = await _askExportName();
    if (name == null || !mounted) return;
    setState(() => _exporting = true);
    String message;
    try {
      final target = await _service.exportDatabase(
        targetDirPath: dirPath,
        fileName: name,
      );
      message = '数据库已导出到 $target';
    } catch (e) {
      message = '数据库导出失败：$e';
    }
    if (mounted) {
      setState(() => _exporting = false);
      _snack(message);
    }
  }

  Future<void> _refresh() async {
    _loadImages();
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<String?> _pickDatabaseFile() {
    final custom = widget.filePicker;
    if (custom != null) return custom();
    // 注意：不要用 FileType.custom + allowedExtensions:['db']。Android 的 MimeTypeMap
    // 不识别 `.db` 扩展名，getMimeTypeFromExtension('db') 返回 null，file_picker 会得到空
    // MIME 数组并直接以「Unsupported filter」报错，导致系统文件选择器根本弹不出来（按钮有
    // 点击效果却无响应）。这里改用 FileType.any 可靠弹出选择器，选中后再校验 `.db` 后缀。
    return FilePicker.platform.pickFiles(
      dialogTitle: '选择数据库备份文件',
      type: FileType.any,
    ).then((result) => result?.files.single.path);
  }

  /// 判断路径是否以 `.db`（不区分大小写）结尾。
  bool _isDbPath(String path) => p.extension(path).toLowerCase() == '.db';

  /// 导入本机数据库备份：解析出合并计划后进入「合并决策页」逐本确认。
  Future<void> _importDatabase() async {
    final provider = context.read<CloudSyncProvider>();
    final String? path;
    try {
      path = await _pickDatabaseFile();
    } catch (e) {
      if (!mounted) return;
      _snack('选择数据库文件失败：$e');
      return;
    }
    if (path == null || !mounted) return;
    if (!_isDbPath(path)) {
      _snack('请选择 .db 数据库备份文件。');
      return;
    }
    // 防止选择当前本地库本身（只会产生「全一致」且无意义的自我合并）。
    final localPath = await AppPaths.userDatabasePath();
    if (!mounted) return;
    if (_samePath(path, localPath)) {
      _snack('请选择备份文件，而非当前数据库。');
      return;
    }
    setState(() => _importing = true);
    final DatabaseMergePlan plan;
    try {
      plan = await DatabaseMergeService.buildPlanFromBackup(path);
    } catch (e) {
      if (!mounted) return;
      setState(() => _importing = false);
      _snack('解析导入文件失败：$e');
      return;
    }
    if (!mounted) return;
    await DatabaseMergeScreen.open(
      context,
      plan: plan,
      onApply: (p, bd, md) => provider.applyMergePlan(p, bd, md),
    );
    if (mounted) setState(() => _importing = false);
  }

  bool _samePath(String a, String b) => p.normalize(a).toLowerCase() ==
      p.normalize(b).toLowerCase();

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '存储管理',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        Text(
          '导出本地数据库到指定位置；图片库与云同步联动——删除即全局删除，'
          '其它设备同步后也会一并消失。',
          style: TextStyle(fontSize: 12, color: colors.textSecondary),
        ),
        const SizedBox(height: 20),
        // ---------- 本地数据库导出/导入 ----------
        _SectionHeader(
          icon: Icons.storage_outlined,
          title: '本地数据库导出/导入',
          subtitle: '把当前书籍及剧情的 sqlite 数据库复制到你选择的文件夹，或从本机备份导入并逐本确认合并。',
        ),
        const SizedBox(height: 12),
        FutureBuilder<StorageDbInfo?>(
          future: _dbFuture,
          builder: (context, snapshot) {
            return _Card(
              child: snapshot.connectionState != ConnectionState.done
                  ? const LinearProgressIndicator(minHeight: 2)
                  : _buildDbContent(context, snapshot.data),
            );
          },
        ),
        const SizedBox(height: 24),
        // ---------- 本地/云端图片管理 ----------
        _SectionHeader(
          icon: Icons.photo_library_outlined,
          title: '本地/云端图片管理',
          subtitle: '按修改时间浏览、查看与清理图片；删除会同步到云端与其它设备，'
              '其它设备新增的图片同步后也会出现在本地。',
        ),
        const SizedBox(height: 12),
        _buildImageEntry(context),
      ],
    );
  }

  Future<void> _openGallery() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ImageGalleryPage()),
    );
    // 返回后刷新图片统计（可能已删除）。
    if (mounted) _refresh();
  }

  Widget _buildImageEntry(BuildContext context) {
    final colors = context.narrColors;
    String summary;
    if (_imagesLoading) {
      summary = '加载中…';
    } else {
      final images = _images ?? const <StorageImageInfo>[];
      final total = images.fold<int>(0, (s, i) => s + i.size);
      summary = images.isEmpty
          ? '暂无图片'
          : '共 ${images.length} 张 · 合计 ${Formats.formatBytes(total)}';
    }
    return Material(
      color: colors.background,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colors.divider),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: _openGallery,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          child: Row(
            children: [
              Icon(
                Icons.photo_library_outlined,
                size: 20,
                color: colors.textSecondary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  summary,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: colors.textPrimary),
                ),
              ),
              Icon(Icons.chevron_right, size: 20, color: colors.textSecondary),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDbContent(BuildContext context, StorageDbInfo? db) {
    final colors = context.narrColors;
    if (db == null) {
      return Text(
        '本地数据库暂不可用。',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 12, color: colors.textSecondary),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.dns_outlined, size: 20, color: colors.textSecondary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                db.path,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: colors.textPrimary),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '大小 ${Formats.formatBytes(db.size)} · '
          '修改于 ${Formats.formatDateTime(db.modified)}',
          style: TextStyle(fontSize: 11, color: colors.textSecondary),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: _exporting ? null : _exportDatabase,
              icon: const Icon(Icons.upload_file_outlined, size: 18),
              label: Text(_exporting ? '导出中…' : '导出数据库'),
            ),
            OutlinedButton.icon(
              onPressed: _importing ? null : _importDatabase,
              icon: const Icon(Icons.file_open_outlined, size: 18),
              label: Text(_importing ? '导入中…' : '导入数据库'),
            ),
          ],
        ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _SectionHeader({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    return Row(
      children: [
        Icon(icon, size: 18, color: NarrChatTheme.primary),
        const SizedBox(width: 8),
        Text(
          title,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: colors.textPrimary,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            subtitle,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: colors.textSecondary),
          ),
        ),
      ],
    );
  }
}

/// 通用卡片容器。
class _Card extends StatelessWidget {
  final Widget child;

  const _Card({required this.child});

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.divider),
      ),
      child: child,
    );
  }
}

/// 导出文件名对话框：自持 controller，避免关闭动画期间被外部 dispose。
class _ExportNameDialog extends StatefulWidget {
  final String initialName;

  const _ExportNameDialog({required this.initialName});

  @override
  State<_ExportNameDialog> createState() => _ExportNameDialogState();
}

class _ExportNameDialogState extends State<_ExportNameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialName);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('导出数据库'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            onTapOutside: unfocusOnTapOutside,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: '导出文件名',
              hintText: 'narrchat_2026-01-01_12-00-00.db',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '文件将保存到你选择的文件夹。',
            style: TextStyle(
              fontSize: 11,
              color: context.narrColors.textSecondary,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('导出'),
        ),
      ],
    );
  }
}
