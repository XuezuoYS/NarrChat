import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../models/app_notice.dart';
import '../screens/image_gallery_page.dart';
import '../services/storage_service.dart';
import '../theme/app_theme.dart';
import '../utils/focus_utils.dart';
import '../utils/formats.dart';
import 'app_notice_overlay.dart';

/// 设置页「存储管理」面板（R3 多库视角）。
///
/// - **存储总览**：逐库列出（书籍目录库 / Mod 库 / 每本书库 / 本地缓存库 /
///   本地备份状态库 / 旧版 R2 备份）+ 各自大小，外加图片目录占用与合计；
/// - **导出**：把整组用户数据打包成 `narrchat.zip`（library + mods + 全部书库 + img）；
/// - **导入**：校验版本后整组落地，落地前自动备份现有 `user_data`；
/// - **图片库**：与云备份联动——删除即全局删除，其它设备同步后也会消失。
class StorageManagementPanel extends StatefulWidget {
  /// 目录选择回调（测试注入替身；缺省用 [FilePicker.platform.getDirectoryPath]）。
  final Future<String?> Function()? directoryPicker;

  /// 文件选择回调（测试注入替身；缺省用 [FilePicker.platform.pickFiles]）。
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
  StorageOverview? _overview;
  bool _overviewLoading = true;
  List<StorageImageInfo>? _images;
  bool _imagesLoading = true;
  bool _exporting = false;
  bool _importing = false;

  StorageService get _service => context.read<StorageService>();

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _loadOverview();
    _loadImages();
  }

  Future<void> _loadOverview() async {
    setState(() => _overviewLoading = true);
    try {
      final overview = await _service.overview();
      if (mounted) {
        setState(() {
          _overview = overview;
          _overviewLoading = false;
        });
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _overviewLoading = false);
      _snack('读取存储信息失败：$error', kind: NoticeKind.error);
    }
  }

  Future<void> _loadImages() async {
    setState(() => _imagesLoading = true);
    try {
      final list = await _service.listImages();
      if (mounted) {
        setState(() {
          _images = list;
          _imagesLoading = false;
        });
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _images = const [];
        _imagesLoading = false;
      });
      _snack('读取图片列表失败：$error', kind: NoticeKind.error);
    }
  }

  void _snack(String message, {NoticeKind kind = NoticeKind.info}) {
    context.notices.show(message, kind: kind);
  }

  Future<String?> _pickDirectory() {
    final custom = widget.directoryPicker;
    if (custom != null) return custom();
    return FilePicker.platform.getDirectoryPath(dialogTitle: '选择导出文件夹');
  }

  Future<String?> _pickArchiveFile() {
    final custom = widget.filePicker;
    if (custom != null) return custom();
    // 不用 FileType.custom + allowedExtensions:['zip']：Android 的 MimeTypeMap
    // 对非常见扩展名会得到空 MIME 数组，file_picker 直接以「Unsupported filter」
    // 报错，选择器根本弹不出来。选完再按后缀校验。
    return FilePicker.platform
        .pickFiles(dialogTitle: '选择导出包（narrchat.zip）', type: FileType.any)
        .then((result) => result?.files.single.path);
  }

  String _defaultArchiveName() {
    final now = DateTime.now();
    final ts = '${now.year}-${Formats.two(now.month)}-${Formats.two(now.day)}';
    return 'narrchat_$ts.zip';
  }

  Future<String?> _askArchiveName() async {
    final result = await showDialog<String>(
      context: context,
      builder: (_) => _FileNameDialog(
        title: '导出整组数据',
        initialName: _defaultArchiveName(),
        hint: 'narrchat_2026-01-01.zip',
        note: '将打包 library + mods + 全部书库 + 图片目录。',
      ),
    );
    if (result == null) return null;
    var name = result.trim();
    if (name.isEmpty) return null;
    if (!name.toLowerCase().endsWith('.zip')) name = '$name.zip';
    return name;
  }

  Future<void> _exportArchive() async {
    final String? dirPath;
    final String? name;
    try {
      dirPath = await _pickDirectory();
      if (dirPath == null || !mounted) return;
      name = await _askArchiveName();
    } catch (error) {
      if (!mounted) return;
      _snack('选择导出位置失败：$error', kind: NoticeKind.error);
      return;
    }
    if (name == null || !mounted) return;

    setState(() => _exporting = true);
    String message;
    var ok = true;
    try {
      final target = await _service.exportArchive(
        targetDirPath: dirPath,
        fileName: name,
      );
      message = '已导出到 $target';
    } catch (error) {
      ok = false;
      message = '导出失败：$error';
    }
    if (!mounted) return;
    setState(() => _exporting = false);
    _snack(message, kind: ok ? NoticeKind.success : NoticeKind.error);
  }

  Future<void> _importArchive() async {
    final String? path;
    try {
      path = await _pickArchiveFile();
    } catch (error) {
      if (!mounted) return;
      _snack('选择导出包失败：$error', kind: NoticeKind.error);
      return;
    }
    if (path == null || !mounted) return;
    if (p.extension(path).toLowerCase() != '.zip') {
      _snack('请选择 .zip 导出包。', kind: NoticeKind.warning);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('导入整组数据'),
        content: const Text(
          '导入会用压缩包里的内容**整体替换**当前书库、Mod 与图片。\n\n'
          '现有数据会先自动备份到 user_data 旁边的 .import-backup-* 目录。\n'
          '导入完成后建议重启应用，让界面重新加载数据。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('开始导入'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _importing = true);
    final result = await _service.importArchive(archivePath: path);
    if (!mounted) return;
    setState(() => _importing = false);
    if (result.ok) {
      await _showImportDone(result);
      if (mounted) _reload();
      return;
    }
    _snack(result.message, kind: NoticeKind.error);
  }

  /// 导入成功后的收尾提示：备份位置 + 是否需要重启。
  ///
  /// 用对话框而不是浮条：这段信息（备份目录、要重启）用户很可能要抄下来，
  /// 浮条几秒就没了。
  Future<void> _showImportDone(StorageImportResult result) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('导入完成'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(result.message),
              if (result.suggestRestart) ...[
                const SizedBox(height: 10),
                const Text('数据库文件已被整体替换，请重启应用让界面重新加载数据。'),
              ],
              if (result.backupPath != null) ...[
                const SizedBox(height: 10),
                const Text('原数据已备份到：'),
                SelectableText(
                  result.backupPath!,
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteLegacyBackup() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除旧版数据库备份'),
        content: const Text(
          '这会删除升级到 3.0 时留下的 narrchat.db.r2.bak。\n'
          '删除后无法再用 2.x 版应用打开旧数据，请确认不再需要。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _service.deleteLegacyBackup();
      if (!mounted) return;
      _snack('旧版备份已删除。', kind: NoticeKind.success);
      _loadOverview();
    } catch (error) {
      if (!mounted) return;
      _snack('删除失败：$error', kind: NoticeKind.error);
    }
  }

  Future<void> _openGallery() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ImageGalleryPage()),
    );
    if (mounted) _reload();
  }

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
          '3.0 起数据按「一个库一个文件」存放：书籍目录、Mod、每本书各一个库，'
          '图片单独存放。导出会把整组打成 zip，导入会整组替换并先备份。',
          style: TextStyle(fontSize: 12, color: colors.textSecondary),
        ),
        const SizedBox(height: 20),
        _SectionHeader(
          icon: Icons.storage_outlined,
          title: '本地数据',
          subtitle: '逐库占用；导出/导入针对整组用户数据。',
        ),
        const SizedBox(height: 12),
        _Card(
          child: _overviewLoading
              ? const LinearProgressIndicator(minHeight: 2)
              : _buildOverview(context),
        ),
        const SizedBox(height: 24),
        _SectionHeader(
          icon: Icons.photo_library_outlined,
          title: '图片库',
          subtitle: '按修改时间浏览、查看与清理；删除会同步到云端与其它设备。',
        ),
        const SizedBox(height: 12),
        _buildImageEntry(context),
      ],
    );
  }

  Widget _buildOverview(BuildContext context) {
    final colors = context.narrColors;
    final overview = _overview;
    if (overview == null) {
      return Text(
        '存储信息暂不可用。',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 12, color: colors.textSecondary),
      );
    }

    final rows = overview.existingDatabases;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (rows.isEmpty)
          Text(
            '还没有任何库文件。',
            style: TextStyle(fontSize: 12, color: colors.textSecondary),
          )
        else
          for (final file in rows) _buildDbRow(context, file),
        const Divider(height: 20),
        _buildKeyValue(
          context,
          '图片',
          overview.imageCount == 0
              ? '暂无图片'
              : '${overview.imageCount} 张 · ${Formats.formatBytes(overview.imageBytes)}',
        ),
        const SizedBox(height: 4),
        _buildKeyValue(
          context,
          '合计占用',
          '${Formats.formatBytes(overview.totalBytes)}'
              '（库 ${Formats.formatBytes(overview.databaseBytes)}'
              ' + 图片 ${Formats.formatBytes(overview.imageBytes)}）',
          emphasize: true,
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: _exporting || _importing ? null : _exportArchive,
              icon: const Icon(Icons.archive_outlined, size: 18),
              label: Text(_exporting ? '导出中…' : '导出整组数据'),
            ),
            OutlinedButton.icon(
              onPressed: _exporting || _importing ? null : _importArchive,
              icon: const Icon(Icons.unarchive_outlined, size: 18),
              label: Text(_importing ? '导入中…' : '导入整组数据'),
            ),
            if (rows.any((file) => file.id == 'legacy-backup'))
              TextButton.icon(
                onPressed: _exporting || _importing ? null : _deleteLegacyBackup,
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('删除旧版备份'),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildDbRow(BuildContext context, StorageFileInfo file) {
    final colors = context.narrColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.dns_outlined, size: 16, color: colors.textSecondary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  file.label,
                  style: TextStyle(fontSize: 12, color: colors.textPrimary),
                ),
                Text(
                  file.path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10, color: colors.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            Formats.formatBytes(file.sizeBytes),
            style: TextStyle(fontSize: 11, color: colors.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _buildKeyValue(
    BuildContext context,
    String label,
    String value, {
    bool emphasize = false,
  }) {
    final colors = context.narrColors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 72,
          child: Text(
            label,
            style: TextStyle(fontSize: 11, color: colors.textSecondary),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              fontSize: emphasize ? 12 : 11,
              fontWeight: emphasize ? FontWeight.w600 : FontWeight.w400,
              color: colors.textPrimary,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildImageEntry(BuildContext context) {
    final colors = context.narrColors;
    final images = _images ?? const <StorageImageInfo>[];
    final total = images.fold<int>(0, (sum, image) => sum + image.size);
    final summary = _imagesLoading
        ? '加载中…'
        : images.isEmpty
            ? '暂无图片'
            : '共 ${images.length} 张 · 合计 ${Formats.formatBytes(total)}';

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

/// 文件名输入对话框：自持 controller，避免关闭动画期间被外部 dispose。
class _FileNameDialog extends StatefulWidget {
  final String title;
  final String initialName;
  final String hint;
  final String note;

  const _FileNameDialog({
    required this.title,
    required this.initialName,
    required this.hint,
    required this.note,
  });

  @override
  State<_FileNameDialog> createState() => _FileNameDialogState();
}

class _FileNameDialogState extends State<_FileNameDialog> {
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
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            onTapOutside: unfocusOnTapOutside,
            autofocus: true,
            decoration: InputDecoration(
              labelText: '文件名',
              hintText: widget.hint,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            widget.note,
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
          child: const Text('确定'),
        ),
      ],
    );
  }
}
