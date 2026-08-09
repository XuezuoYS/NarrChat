import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/cloud_sync_provider.dart';
import '../services/webdav_service.dart';
import '../theme/app_theme.dart';

/// 云同步（WebDAV）设置面板。
///
/// - 连接设置：服务器地址 / 登录用户名 / 密码（安全存储）/ 存储文件夹 /
///   备份用户名 / 保留历史版本 / 每轮结束后自动上传；
/// - 云端备份：立即上传、刷新列表、选择版本下载；
/// - 下载时弹出提示框：删除本地数据（整体恢复）或合并本地数据。
class CloudSyncPanel extends StatefulWidget {
  const CloudSyncPanel({super.key});

  @override
  State<CloudSyncPanel> createState() => _CloudSyncPanelState();
}

class _CloudSyncPanelState extends State<CloudSyncPanel> {
  late final TextEditingController _url;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _folder;
  late final TextEditingController _userName;
  late final TextEditingController _keepVersions;
  late bool _autoUpload;
  bool _obscurePassword = true;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    final provider = context.read<CloudSyncProvider>();
    _url = TextEditingController(text: provider.webdavUrl);
    _username = TextEditingController(text: provider.webdavUsername);
    _password = TextEditingController(text: provider.webdavPassword);
    _folder = TextEditingController(text: provider.folder);
    _userName = TextEditingController(text: provider.userName);
    _keepVersions = TextEditingController(text: '${provider.keepVersions}');
    _autoUpload = provider.autoUpload;
  }

  @override
  void dispose() {
    _url.dispose();
    _username.dispose();
    _password.dispose();
    _folder.dispose();
    _userName.dispose();
    _keepVersions.dispose();
    super.dispose();
  }

  int? get _keepVersionsValue => int.tryParse(_keepVersions.text.trim());

  Future<void> _save() async {
    final keep = _keepVersionsValue;
    if (keep == null || keep < 1 || keep > 99) {
      _showSnack('保留历史版本需为 1 ~ 99 的整数');
      return;
    }
    setState(() => _isSaving = true);
    final provider = context.read<CloudSyncProvider>();
    final ok = await provider.save(
      webdavUrl: _url.text,
      webdavUsername: _username.text,
      webdavPassword: _password.text,
      folder: _folder.text,
      keepVersions: keep,
      autoUpload: _autoUpload,
      userName: _userName.text,
    );
    if (!mounted) return;
    setState(() => _isSaving = false);
    _showSnack(ok ? '设置已保存' : '保存失败：${provider.error ?? '未知错误'}');
  }

  Future<void> _upload() async {
    final provider = context.read<CloudSyncProvider>();
    final ok = await provider.upload();
    if (!mounted) return;
    _showSnack(ok ? '上传成功' : '上传失败：${provider.error ?? '未知错误'}');
  }

  Future<void> _refresh() async {
    final provider = context.read<CloudSyncProvider>();
    await provider.refreshBackups();
    if (!mounted) return;
    if (provider.error != null) {
      _showSnack('刷新失败：${provider.error}');
    }
  }

  Future<void> _testConnection() async {
    final provider = context.read<CloudSyncProvider>();
    final result = await provider.testConnection(
      url: _url.text,
      username: _username.text,
      password: _password.text,
      folder: _folder.text,
    );
    if (!mounted) return;
    _showSnack(result == null ? '连接成功：WebDAV 服务器可用' : '连接失败：$result');
  }

  Future<void> _download(WebDavFile file) async {
    final provider = context.read<CloudSyncProvider>();
    final tempPath = await provider.downloadBackup(file.name);
    if (!mounted) return;
    if (tempPath == null) {
      _showSnack('下载失败：${provider.error ?? '未知错误'}');
      return;
    }
    // 弹出提示框：删除本地数据（整体恢复）还是合并本地数据。
    final mode = await showDialog<_DownloadApplyMode>(
      context: context,
      builder: (context) => _DownloadApplyDialog(file: file),
    );
    if (mode == null) {
      _cleanupTemp(tempPath);
      return;
    }
    final ok = mode == _DownloadApplyMode.replace
        ? await provider.applyReplace(tempPath)
        : await provider.applyMerge(tempPath);
    _cleanupTemp(tempPath);
    if (!mounted) return;
    if (ok) {
      if (mode == _DownloadApplyMode.merge) {
        final r = provider.lastMergeResult;
        _showSnack(
          '合并完成：新增书籍 ${r?.booksAdded ?? 0}、'
          '轮次 ${r?.roundsAdded ?? 0}、世界书 ${r?.worldBookAdded ?? 0}、'
          'Mod ${r?.modsAdded ?? 0}',
        );
      } else {
        _showSnack('已用所选备份替换本地数据');
      }
    } else {
      _showSnack('处理失败：${provider.error ?? '未知错误'}');
    }
  }

  void _cleanupTemp(String path) {
    try {
      File(path).delete();
    } catch (_) {
      // 临时文件清理失败可忽略。
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<CloudSyncProvider>();
    final colors = context.narrColors;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '云同步',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        Text(
          '通过 WebDAV 将书籍、角色设定与剧情进度备份到云端，支持多设备迁移。',
          style: TextStyle(fontSize: 12, color: colors.textSecondary),
        ),
        const SizedBox(height: 20),
        // ---------- 连接设置 ----------
        Text(
          '连接设置',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: colors.textPrimary,
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _url,
          decoration: const InputDecoration(
            labelText: 'WebDAV 服务器地址',
            hintText: 'https://dav.example.com/dav/',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _username,
                decoration: const InputDecoration(
                  labelText: '登录用户名',
                  hintText: 'WebDAV 账号',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _password,
                obscureText: _obscurePassword,
                decoration: InputDecoration(
                  labelText: '登录密码',
                  hintText: '（保存至系统安全存储）',
                  border: const OutlineInputBorder(),
                  isDense: true,
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscurePassword
                          ? Icons.visibility_off
                          : Icons.visibility,
                    ),
                    tooltip: _obscurePassword ? '显示' : '隐藏',
                    onPressed: () =>
                        setState(() => _obscurePassword = !_obscurePassword),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _folder,
                decoration: const InputDecoration(
                  labelText: '存储文件夹',
                  hintText: 'narrchat',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _userName,
                decoration: const InputDecoration(
                  labelText: '备份用户名',
                  hintText: 'user',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _keepVersions,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '保留历史版本',
                  hintText: '5',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '备份文件名格式：narrchat_{备份用户名}_{yyyy-MM-dd_HH-mm-ss}.db；'
          '仅保留最新「保留历史版本」份。',
          style: TextStyle(fontSize: 11, color: colors.textSecondary),
        ),
        const SizedBox(height: 4),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('每轮生成结束后自动上传'),
          subtitle: const Text('关闭时仅在上方手动上传'),
          value: _autoUpload,
          onChanged: (v) => setState(() => _autoUpload = v),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            OutlinedButton.icon(
              onPressed: provider.isBusy ? null : _testConnection,
              icon: const Icon(Icons.wifi_tethering_outlined, size: 18),
              label: const Text('测试连接'),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              onPressed: _isSaving ? null : _save,
              icon: const Icon(Icons.save_outlined, size: 18),
              label: Text(_isSaving ? '保存中…' : '保存设置'),
            ),
          ],
        ),
        const Divider(height: 32),
        // ---------- 云端备份 ----------
        Text(
          '云端备份',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: colors.textPrimary,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            FilledButton.icon(
              onPressed: provider.isBusy ? null : _upload,
              icon: const Icon(Icons.cloud_upload_outlined, size: 18),
              label: const Text('立即上传'),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: provider.isBusy ? null : _refresh,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('刷新列表'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (provider.isBusy) ...[
          const LinearProgressIndicator(minHeight: 2),
          const SizedBox(height: 8),
        ],
        if (provider.error != null) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: colors.historyBackground,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: colors.historyHeader),
            ),
            child: Text(
              provider.error!,
              style: TextStyle(fontSize: 12, color: colors.textPrimary),
            ),
          ),
          const SizedBox(height: 8),
        ],
        if (provider.backupsLoaded) _buildBackupList(context, provider),
      ],
    );
  }

  Widget _buildBackupList(BuildContext context, CloudSyncProvider provider) {
    final colors = context.narrColors;
    if (provider.backups.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: colors.background,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: colors.divider),
        ),
        child: Text(
          '云端暂无备份，点击「立即上传」创建第一份备份。',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: colors.textSecondary),
        ),
      );
    }
    return Column(
      children: [
        for (final file in provider.backups)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: colors.background,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: colors.divider),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.insert_drive_file_outlined,
                  size: 20,
                  color: colors.textSecondary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        file.name,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: colors.textPrimary,
                        ),
                      ),
                      Text(
                        _formatBackupMeta(file),
                        style: TextStyle(
                          fontSize: 11,
                          color: colors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '下载并恢复此版本',
                  icon: const Icon(Icons.cloud_download_outlined, size: 20),
                  color: Theme.of(context).colorScheme.primary,
                  onPressed: provider.isBusy ? null : () => _download(file),
                ),
              ],
            ),
          ),
      ],
    );
  }

  String _formatBackupMeta(WebDavFile file) {
    final parts = <String>[];
    final modified = file.lastModified;
    if (modified != null) {
      final t = modified.toLocal();
      final ts =
          '${t.year}-${_two(t.month)}-${_two(t.day)} '
          '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';
      parts.add(ts);
    }
    if (file.size > 0) parts.add(_formatSize(file.size));
    return parts.join(' · ');
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _formatSize(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '$bytes B';
  }
}

enum _DownloadApplyMode { replace, merge }

/// 下载备份后的处理方式选择框：删除本地数据（整体恢复）或合并本地数据。
class _DownloadApplyDialog extends StatelessWidget {
  final WebDavFile file;

  const _DownloadApplyDialog({required this.file});

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    final meta = <String>[];
    final modified = file.lastModified;
    if (modified != null) {
      final t = modified.toLocal();
      meta.add(
        '${t.year}-${_two(t.month)}-${_two(t.day)} '
        '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}',
      );
    }
    if (file.size > 0) meta.add(_formatSize(file.size));
    final metaText = meta.join(' · ');

    return AlertDialog(
      title: const Text('恢复备份'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              file.name,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: colors.textPrimary,
              ),
            ),
            if (metaText.isNotEmpty)
              Text(
                metaText,
                style: TextStyle(fontSize: 11, color: colors.textSecondary),
              ),
            const SizedBox(height: 14),
            Text(
              '请选择如何处理本地数据：',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: colors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            _OptionTile(
              icon: Icons.delete_outline,
              title: '删除本地数据并恢复',
              subtitle: '用该备份整体覆盖本地数据（无法撤销）。',
            ),
            const SizedBox(height: 8),
            _OptionTile(
              icon: Icons.merge_outlined,
              title: '合并本地数据',
              subtitle: '保留本地与备份中不重复的数据，冲突时保留本地。',
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () =>
              Navigator.of(context).pop(_DownloadApplyMode.merge),
          child: const Text('合并'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(context).pop(_DownloadApplyMode.replace),
          child: const Text('删除并恢复'),
        ),
      ],
    );
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _formatSize(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '$bytes B';
  }
}

class _OptionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _OptionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.divider),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: colors.textSecondary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(fontSize: 11, color: colors.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
