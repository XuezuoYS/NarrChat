import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/cloud_sync_provider.dart';
import '../services/webdav_service.dart';
import '../theme/app_theme.dart';
import '../utils/formats.dart';
import '../utils/focus_utils.dart';
import 'settings_form_state.dart';

/// 云同步（WebDAV）设置面板。
///
/// - 连接设置：服务器地址 / 登录用户名 / 密码（安全存储）/ 存储文件夹 /
///   备份用户名 / 保留历史版本 / 每轮结束后自动上传；
/// - 云端备份：立即上传、刷新列表、选择版本下载；
/// - 下载时弹出提示框：删除本地数据（整体恢复）或合并本地数据。
///
/// 表单值由外层 [SettingsFormState] 持有（切换面板不丢失），
/// 由设置页右上角「保存」统一校验并落库；保存后不退出设置页。
class CloudSyncPanel extends StatefulWidget {
  final SettingsFormState form;

  const CloudSyncPanel({super.key, required this.form});

  @override
  State<CloudSyncPanel> createState() => _CloudSyncPanelState();
}

class _CloudSyncPanelState extends State<CloudSyncPanel> {
  SettingsFormState get _form => widget.form;

  @override
  void initState() {
    super.initState();
    final provider = context.read<CloudSyncProvider>();
    // 已配置 WebDAV 时，进入面板自动刷新云端备份列表。
    // 使用 post-frame 回调，避免在 build/initState 阶段触发 notifyListeners。
    if (provider.isConfigured) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        context.read<CloudSyncProvider>().refreshBackups();
      });
    }
  }

  /// 删除当前 WebDAV 连接：确认后清除本地保存的连接配置并重置表单。
  Future<void> _disconnect() async {
    final provider = context.read<CloudSyncProvider>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除连接'),
        content: const Text(
          '将清除本机保存的 WebDAV 连接配置（服务器地址、用户名、密码等），'
          '云端备份与本地书籍数据均不受影响。确定删除吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await provider.disconnect();
    if (!mounted) return;
    if (provider.error != null) {
      _showSnack('删除失败：${provider.error}');
      return;
    }
    // 同步清空表单并恢复默认值。
    setState(() {
      _form.webdavUrl.clear();
      _form.webdavUsername.clear();
      _form.webdavPassword.clear();
      _form.webdavFolder.text = CloudSyncProvider.defaultFolder;
      _form.webdavUserName.text = CloudSyncProvider.defaultUserName;
      _form.webdavKeepVersions.text = '${CloudSyncProvider.defaultKeepVersions}';
      _form.autoUpload = false;
    });
    _showSnack('已删除连接');
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
      url: _form.webdavUrl.text,
      username: _form.webdavUsername.text,
      password: _form.webdavPassword.text,
      folder: _form.webdavFolder.text,
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
    bool ok;
    try {
      ok = mode == _DownloadApplyMode.replace
          ? await provider.applyReplace(tempPath)
          : await provider.applyMerge(tempPath);
    } finally {
      // 无论成功失败都清理临时备份文件，避免残留占用磁盘。
      _cleanupTemp(tempPath);
    }
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
          controller: _form.webdavUrl,
          onTapOutside: unfocusOnTapOutside,
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
                controller: _form.webdavUsername,
                onTapOutside: unfocusOnTapOutside,
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
                controller: _form.webdavPassword,
                onTapOutside: unfocusOnTapOutside,
                obscureText: _form.obscurePassword,
                // 密码框：禁用输入法联想/自动更正，避免敏感信息被记录。
                enableSuggestions: false,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: '登录密码',
                  hintText: '（保存至系统安全存储）',
                  border: const OutlineInputBorder(),
                  isDense: true,
                  suffixIcon: IconButton(
                    icon: Icon(
                      _form.obscurePassword
                          ? Icons.visibility_off
                          : Icons.visibility,
                    ),
                    tooltip: _form.obscurePassword ? '显示' : '隐藏',
                    onPressed: () => setState(
                      () => _form.obscurePassword = !_form.obscurePassword,
                    ),
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
                controller: _form.webdavFolder,
                onTapOutside: unfocusOnTapOutside,
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
                controller: _form.webdavUserName,
                onTapOutside: unfocusOnTapOutside,
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
                controller: _form.webdavKeepVersions,
                onTapOutside: unfocusOnTapOutside,
                keyboardType: TextInputType.number,
                // 仅允许数字且最多 2 位（1~99），与保存时的范围校验一致。
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                maxLength: 2,
                decoration: const InputDecoration(
                  labelText: '保留历史版本',
                  hintText: '5',
                  border: OutlineInputBorder(),
                  isDense: true,
                  counterText: '',
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
          value: _form.autoUpload,
          onChanged: (v) => setState(() => _form.autoUpload = v),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            TextButton.icon(
              onPressed:
                  provider.isConfigured && !provider.isBusy ? _disconnect : null,
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
              icon: const Icon(Icons.link_off, size: 18),
              label: const Text('删除连接'),
            ),
            const Spacer(),
            OutlinedButton.icon(
              onPressed: provider.isBusy ? null : _testConnection,
              icon: const Icon(Icons.wifi_tethering_outlined, size: 18),
              label: const Text('测试连接'),
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
                        Formats.formatBackupMeta(
                          modified: file.lastModified,
                          size: file.size,
                        ),
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

}

enum _DownloadApplyMode { replace, merge }

/// 下载备份后的处理方式选择框：删除本地数据（整体恢复）或合并本地数据。
class _DownloadApplyDialog extends StatelessWidget {
  final WebDavFile file;

  const _DownloadApplyDialog({required this.file});

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    final metaText = Formats.formatBackupMeta(
      modified: file.lastModified,
      size: file.size,
    );

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
