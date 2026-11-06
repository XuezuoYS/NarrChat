import 'package:flutter/material.dart';

import '../services/debug_database_service.dart';
import '../services/debug_file_service.dart';
import '../theme/app_theme.dart';
import '../utils/formats.dart';
import '../widgets/app_empty_hint.dart';
import '../widgets/island_bar.dart';
import '../widgets/load_error_hint.dart';
import '../widgets/narr_chat_app_bar.dart';
import 'database_inspect_screen.dart';
import 'debug_image_screen.dart';
import 'debug_text_view_screen.dart';

/// 「数据文件」页：只读浏览应用数据根目录下的全部文件。
///
/// 从 `user_data/`、`local_config/` 的父目录开始，按文件夹逐层进入；点文件
/// 按类型打开对应阅读器。书籍库（`narrbook_<uuid>.db`）会异步读取
/// `book_meta.title`，在文件名下方用小字显示。
class DebugFilesScreen extends StatefulWidget {
  const DebugFilesScreen({
    super.key,
    required this.fileService,
    required this.databaseService,
    this.relativePath = '',
    this.title = '数据文件',
  });

  final DebugFileService fileService;
  final DebugDatabaseService databaseService;

  /// 当前目录相对数据根目录的路径；空字符串表示根目录。
  final String relativePath;

  /// 顶栏标题（根目录用「数据文件」，子目录用文件夹名）。
  final String title;

  @override
  State<DebugFilesScreen> createState() => _DebugFilesScreenState();
}

class _DebugFilesScreenState extends State<DebugFilesScreen> {
  List<DebugFileEntry>? _entries;
  Map<String, String?>? _bookTitles;
  bool _loading = true;
  String? _error;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _error = null;
      _entries = null;
      _bookTitles = null;
    });
    try {
      final entries = await widget.fileService.listDirectory(
        widget.relativePath,
      );
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
      await _loadBookTitles(entries, generation);
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
  }

  /// 异步补书名：先让目录列表出现，再逐个读书库的 `book_meta.title`。
  Future<void> _loadBookTitles(
    List<DebugFileEntry> entries,
    int generation,
  ) async {
    final bookEntries = entries
        .where((entry) => entry.isBookDatabase)
        .toList(growable: false);
    if (bookEntries.isEmpty) return;

    try {
      final paths = <String>[
        for (final entry in bookEntries)
          widget.fileService.absolutePathOf(entry.relativePath),
      ];
      final titles = await widget.databaseService.readBookTitles(paths);
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _bookTitles = {
          for (var i = 0; i < bookEntries.length; i++)
            bookEntries[i].relativePath: titles[paths[i]],
        };
      });
    } catch (_) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _bookTitles = {
          for (final entry in bookEntries) entry.relativePath: null,
        };
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    return IslandAwareScaffold(
      backgroundColor: colors.background,
      appBarBuilder: (context, extraRow) => NarrChatAppBar(
        extraRowHeight: extraRow,
        title: widget.title,
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh, size: 20),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return LoadErrorHint(message: '目录读取失败：$_error', onRetry: _load);
    }

    final entries = _entries ?? const <DebugFileEntry>[];
    if (entries.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: AppEmptyHint(
            icon: Icons.folder_open_outlined,
            text: '这个文件夹是空的',
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _CurrentPath(
          rootPath: widget.fileService.rootPath,
          relativePath: widget.relativePath,
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 4),
            itemCount: entries.length,
            separatorBuilder: (_, _) => const Divider(height: 1, indent: 56),
            itemBuilder: (context, index) {
              final entry = entries[index];
              return _FileTile(
                entry: entry,
                bookTitle: _bookTitles?[entry.relativePath],
                titlesLoading: entry.isBookDatabase && _bookTitles == null,
                onTap: () => _open(entry),
              );
            },
          ),
        ),
      ],
    );
  }

  void _open(DebugFileEntry entry) {
    if (entry.isDirectory) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => DebugFilesScreen(
            fileService: widget.fileService,
            databaseService: widget.databaseService,
            relativePath: entry.relativePath,
            title: entry.name,
          ),
        ),
      );
      return;
    }

    switch (entry.kind) {
      case DebugFileKind.sqlite:
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => DatabaseInspectScreen(
              service: widget.databaseService,
              dbPath: widget.fileService.absolutePathOf(entry.relativePath),
              title: entry.name,
            ),
          ),
        );
        break;
      case DebugFileKind.json || DebugFileKind.text:
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => DebugTextViewScreen(
              fileService: widget.fileService,
              entry: entry,
              formatJson: entry.kind == DebugFileKind.json,
            ),
          ),
        );
        break;
      case DebugFileKind.image:
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) =>
                DebugImageScreen(fileService: widget.fileService, entry: entry),
          ),
        );
        break;
      case DebugFileKind.binary:
        _showBinaryInfo(entry);
        break;
      case DebugFileKind.directory:
        // 目录已在上面处理；保留分支只为穷尽枚举。
        break;
    }
  }

  Future<void> _showBinaryInfo(DebugFileEntry entry) async {
    final path = widget.fileService.absolutePathOf(entry.relativePath);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final colors = dialogContext.narrColors;
        return AlertDialog(
          title: Text(entry.name),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '二进制文件无法预览。',
                  style: TextStyle(fontSize: 13, color: colors.textPrimary),
                ),
                const SizedBox(height: 12),
                _InfoRow(label: '路径', value: path),
                _InfoRow(
                  label: '大小',
                  value: Formats.formatBytes(entry.sizeBytes),
                ),
                if (entry.modified != null)
                  _InfoRow(
                    label: '修改时间',
                    value: Formats.formatDateTime(entry.modified!),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }
}

/// 顶部当前位置：根目录显示真实根路径，子目录显示相对路径。
class _CurrentPath extends StatelessWidget {
  const _CurrentPath({required this.rootPath, required this.relativePath});

  final String rootPath;
  final String relativePath;

  @override
  Widget build(BuildContext context) {
    final text = relativePath.isEmpty
        ? '应用数据根目录：$rootPath'
        : '当前位置：${relativePath.split('/').join(' / ')}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11, color: context.narrColors.textSecondary),
      ),
    );
  }
}

/// 单个文件 / 文件夹行。
class _FileTile extends StatelessWidget {
  const _FileTile({
    required this.entry,
    required this.bookTitle,
    required this.titlesLoading,
    required this.onTap,
  });

  final DebugFileEntry entry;
  final String? bookTitle;
  final bool titlesLoading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    final subtitle = <Widget>[];
    if (entry.isBookDatabase) {
      final titleText = titlesLoading
          ? '读取书名…'
          : (bookTitle != null && bookTitle!.trim().isNotEmpty
                ? '《${bookTitle!.trim()}》'
                : '书名未知');
      subtitle.add(
        Text(
          titleText,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 11, color: colors.textSecondary),
        ),
      );
    }
    subtitle.add(
      Text(
        _metaText(),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 10, color: colors.textSecondary),
      ),
    );

    return ListTile(
      leading: Icon(_iconFor(entry), size: 20, color: colors.textSecondary),
      title: Text(
        entry.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 13, color: colors.textPrimary),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: subtitle,
      ),
      isThreeLine: entry.isBookDatabase,
      trailing: entry.kind == DebugFileKind.binary
          ? null
          : Icon(Icons.chevron_right, size: 18, color: colors.textSecondary),
      onTap: onTap,
    );
  }

  String _metaText() {
    if (entry.isDirectory) return '文件夹';
    final parts = <String>[Formats.formatBytes(entry.sizeBytes)];
    final modified = entry.modified;
    if (modified != null) parts.add(Formats.formatDateTime(modified));
    return parts.join(' · ');
  }

  static IconData _iconFor(DebugFileEntry entry) {
    if (entry.isDirectory) return Icons.folder_outlined;
    switch (entry.kind) {
      case DebugFileKind.sqlite:
        return Icons.storage_outlined;
      case DebugFileKind.json:
        return Icons.data_object;
      case DebugFileKind.image:
        return Icons.image_outlined;
      case DebugFileKind.text:
        return Icons.description_outlined;
      case DebugFileKind.binary:
        return Icons.insert_drive_file_outlined;
      case DebugFileKind.directory:
        return Icons.folder_outlined;
    }
  }
}

/// 二进制文件信息里的一行键值。
class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: Text(
              label,
              style: TextStyle(fontSize: 11, color: colors.textSecondary),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: TextStyle(fontSize: 12, color: colors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}
