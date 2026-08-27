import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/cloud_sync_provider.dart';
import '../screens/database_merge_screen.dart';
import '../services/database_merge_service.dart';
import '../services/sync/sync_models.dart';
import '../services/webdav_service.dart';
import '../theme/app_theme.dart';
import '../utils/focus_utils.dart';
import 'settings_form_state.dart';
import 'sync_restore_dialog.dart';

/// 云同步（WebDAV）设置面板 —— 重新设计版。
///
/// 视觉语言跟随 DeepSeek 极简风，用分区卡片 + 统一的品牌渐变点缀，
/// 亮/暗主题全部走 [NarrChatColors] 自适应色，不写死颜色。
///
/// 功能分区：
/// - 状态卡片：连接状态 / 同步模式 / 设备标识 / 上次同步时间；
/// - 同步模式：全自动（默认）或手动「同步」按钮；
/// - 连接设置：服务器 / 用户名 / 密码 / 文件夹，测试连接 / 删除连接；
/// - 云端备份：统一「同步」、保留历史版本、版本列表（下载→合并/替换）；
/// - 图片：说明随同步自动多端同步、删除可在云端同步删除。
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
    if (provider.isConfigured) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        context.read<CloudSyncProvider>().refreshBackups();
      });
    }
  }

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
    setState(() {
      _form.webdavUrl.clear();
      _form.webdavUsername.clear();
      _form.webdavPassword.clear();
      _form.webdavFolder.text = CloudSyncProvider.defaultFolder;
      _form.webdavKeepVersions.text = '${CloudSyncProvider.defaultKeepVersions}';
      _form.syncMode = SyncMode.auto;
    });
    _showSnack('已删除连接');
  }

  Future<void> _sync() async {
    // 结果提示（完成 / 失败 / 取消）统一由 provider 的全局 toast 展示。
    await context.read<CloudSyncProvider>().sync();
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
    final mode = await showSyncRestoreDialog(context, file: file);
    if (mode == null) {
      _cleanupTemp(tempPath);
      return;
    }
    if (mode == SyncRestoreMode.replace) {
      final ok = await provider.applyReplace(tempPath);
      _cleanupTemp(tempPath);
      if (!mounted) return;
      _showSnack(ok ? '已用所选备份替换本地数据' : '处理失败：${provider.error ?? '未知错误'}');
      return;
    }
    final DatabaseMergePlan plan;
    try {
      plan = await DatabaseMergeService.buildPlanFromBackup(tempPath);
    } catch (e) {
      _cleanupTemp(tempPath);
      if (!mounted) return;
      _showSnack('解析备份失败：$e');
      return;
    }
    _cleanupTemp(tempPath);
    if (!mounted) return;
    await DatabaseMergeScreen.open(
      context,
      plan: plan,
      onApply: (p, bd, md) => provider.applyMergePlan(p, bd, md),
    );
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
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        Text(
          '把书籍、角色设定与剧情进度备份到 WebDAV，多设备自动同步。',
          style: TextStyle(fontSize: 13, color: colors.textSecondary),
        ),
        const SizedBox(height: 20),
        _buildStatusHero(context, provider),
        const SizedBox(height: 16),
        _buildSyncModeCard(context),
        const SizedBox(height: 16),
        _buildConnectionCard(context, provider),
        const SizedBox(height: 16),
        _buildBackupCard(context, provider),
        const SizedBox(height: 16),
        _buildImageNote(context),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // 状态卡片
  // ---------------------------------------------------------------------------
  Widget _buildStatusHero(BuildContext context, CloudSyncProvider provider) {
    final colors = context.narrColors;
    final configured = provider.isConfigured;
    final state = provider.syncState;
    final (icon, title, subtitle) = _statusHint(configured, state, colors);

    return Material(
      color: colors.surface,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: colors.divider),
          borderRadius: BorderRadius.circular(18),
        ),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 左侧品牌渐变竖向色块。
              Container(width: 6, decoration: const BoxDecoration(gradient: NarrChatTheme.brandGradient)),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              gradient: NarrChatTheme.brandGradient,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(icon, color: Colors.white, size: 22),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  title,
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                    color: colors.textPrimary,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  subtitle,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: colors.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          _statusBadge(context, state, configured),
                        ],
                      ),
                      if (configured) ...[
                        const SizedBox(height: 16),
                        _StatStrip(
                          stats: [
                            _Stat(
                              icon: Icons.folder_outlined,
                              label: '文件夹',
                              value: provider.folder.isEmpty ? '—' : provider.folder,
                            ),
                            _Stat(
                              icon: Icons.storage_outlined,
                              label: '保留版本',
                              value: '${provider.keepVersions}',
                            ),
                            _Stat(
                              icon: Icons.devices_outlined,
                              label: '设备标识',
                              value: _shortDevice(provider.deviceId),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  (IconData, String, String) _statusHint(
    bool configured,
    SyncState state,
    NarrChatColors colors,
  ) {
    if (!configured) {
      return (Icons.cloud_off_outlined, '未连接', '填写下方连接信息后进行测试，即可开始云端同步。');
    }
    switch (state) {
      case SyncState.syncing:
        return (Icons.sync, '正在同步', '正在将数据同步到云端…');
      case SyncState.success:
        return (Icons.cloud_done_outlined, '已同步', '本地与云端数据一致。');
      case SyncState.error:
        return (Icons.error_outline, '同步失败', '请检查网络与连接设置。');
      case SyncState.idle:
        return (Icons.cloud_outlined, '已连接', '点击「同步」或等待自动同步。');
    }
  }

  Widget _statusBadge(BuildContext context, SyncState state, bool configured) {
    final colors = context.narrColors;
    final (label, color) = switch ((configured, state)) {
      (false, _) => ('未连接', colors.textSecondary),
      (true, SyncState.syncing) => ('同步中', NarrChatTheme.primary),
      (true, SyncState.success) => ('已同步', colors.success),
      (true, SyncState.error) => ('失败', Theme.of(context).colorScheme.error),
      (true, SyncState.idle) => ('就绪', colors.success),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 同步模式卡片
  // ---------------------------------------------------------------------------
  Widget _buildSyncModeCard(BuildContext context) {
    final colors = context.narrColors;
    return _sectionCard(
      icon: Icons.autorenew,
      title: '同步模式',
      subtitle: '决定何时把本地数据同步到云端，并拉取远端变更。',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Segmented(
            value: _form.syncMode == SyncMode.auto ? 0 : 1,
            options: const [
              _SegOption(
                icon: Icons.sync,
                label: '全自动',
                desc: '连接后自动同步，无需手动操作',
              ),
              _SegOption(
                icon: Icons.touch_app_outlined,
                label: '手动',
                desc: '仅在你点击「同步」时同步',
              ),
            ],
            onChanged: (i) => setState(
              () => _form.syncMode = i == 0 ? SyncMode.auto : SyncMode.manual,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            _form.syncMode == SyncMode.auto
                ? '全自动：应用启动 / 每轮生成结束后自动推送本地变更，并自动拉取远端非冲突变更；仅在真冲突时弹合并确认。'
                : '手动：仅在你点击「同步」时推送与拉取一次，适合希望完全掌控上传时机的场景。',
            style: TextStyle(fontSize: 12, color: colors.textSecondary),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 连接设置卡片
  // ---------------------------------------------------------------------------
  Widget _buildConnectionCard(BuildContext context, CloudSyncProvider provider) {
    final colors = context.narrColors;
    return _sectionCard(
      icon: Icons.link,
      title: '连接设置',
      subtitle: '填写你的 WebDAV 服务器。密码存入系统安全存储，不明文落盘。',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _form.webdavUrl,
            onTapOutside: unfocusOnTapOutside,
            decoration: const InputDecoration(
              labelText: 'WebDAV 服务器地址',
              hintText: 'https://dav.example.com/dav/',
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _form.webdavUsername,
                  onTapOutside: unfocusOnTapOutside,
                  decoration: const InputDecoration(labelText: '登录用户名'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _form.webdavPassword,
                  onTapOutside: unfocusOnTapOutside,
                  obscureText: _form.obscurePassword,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: '登录密码',
                    hintText: '安全存储',
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
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _form.webdavKeepVersions,
                  onTapOutside: unfocusOnTapOutside,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  maxLength: 2,
                  decoration: const InputDecoration(
                    labelText: '保留历史版本',
                    hintText: '5',
                    counterText: '',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '云端保留最近「保留历史版本」份快照，便于回溯误操作。',
            style: TextStyle(fontSize: 11, color: colors.textSecondary),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: provider.isBusy ? null : _testConnection,
                icon: const Icon(Icons.wifi_tethering_outlined, size: 18),
                label: const Text('测试连接'),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: provider.isConfigured && !provider.isBusy
                    ? _disconnect
                    : null,
                style: TextButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.error,
                ),
                icon: const Icon(Icons.link_off, size: 18),
                label: const Text('删除连接'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 云端备份卡片
  // ---------------------------------------------------------------------------
  Widget _buildBackupCard(BuildContext context, CloudSyncProvider provider) {
    return _sectionCard(
      icon: Icons.cloud_outlined,
      title: '云端备份',
      subtitle: '一键同步本地与云端；也可从某个历史版本（第 N 代快照）合并或恢复本地数据。',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              FilledButton.icon(
                onPressed: provider.isBusy ? null : _sync,
                icon: const Icon(Icons.sync, size: 18),
                label: const Text('同步'),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: provider.isBusy ? null : _refresh,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('刷新'),
              ),
            ],
          ),
          if (provider.isBusy) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(minHeight: 2),
          ],
          if (provider.error != null) ...[
            const SizedBox(height: 12),
            _ErrorBox(message: provider.error!),
          ],
          const SizedBox(height: 16),
          if (provider.backupsLoaded) _buildBackupList(context, provider),
        ],
      ),
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
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: colors.divider),
        ),
        child: Text(
          '云端暂无备份。点击「同步」创建第一份，或等待自动同步。',
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
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: colors.background,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: colors.divider),
            ),
            child: Row(
              children: [
                Icon(Icons.insert_drive_file_outlined, size: 20, color: colors.textSecondary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        snapshotLabelOf(file),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: colors.textPrimary,
                        ),
                      ),
                      Text(
                        snapshotMetaOf(file),
                        style: TextStyle(fontSize: 11, color: colors.textSecondary),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '下载并恢复此版本',
                  icon: const Icon(Icons.cloud_download_outlined, size: 20),
                  color: NarrChatTheme.primary,
                  onPressed: provider.isBusy ? null : () => _download(file),
                ),
              ],
            ),
          ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // 图片说明卡片
  // ---------------------------------------------------------------------------
  Widget _buildImageNote(BuildContext context) {
    final colors = context.narrColors;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.divider),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.image_outlined, size: 20, color: colors.textSecondary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '图片自动同步',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '随同步自动在多个设备间补齐。在「存储管理 → 图片管理」删除某图时，'
                  '将同时从云端及其它设备删除；若之后再添加同一图片，会自动恢复。',
                  style: TextStyle(fontSize: 12, color: colors.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 布局部件
  // ---------------------------------------------------------------------------
  Widget _sectionCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required Widget child,
  }) {
    final colors = context.narrColors;
    return Material(
      color: colors.surface,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: colors.divider),
          borderRadius: BorderRadius.circular(16),
        ),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: NarrChatTheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Icon(icon, size: 18, color: NarrChatTheme.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: colors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(fontSize: 12, color: colors.textSecondary),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 子组件
// ---------------------------------------------------------------------------

class _Stat {
  final IconData icon;
  final String label;
  final String value;

  const _Stat({required this.icon, required this.label, required this.value});
}

/// 状态卡片内的一行统计：单张背景卡 + 竖线分割，避免紧凑拥挤。
class _StatStrip extends StatelessWidget {
  final List<_Stat> stats;

  const _StatStrip({required this.stats});

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.divider),
      ),
      child: Row(
        children: [
          for (var i = 0; i < stats.length; i++) ...[
            if (i > 0)
              Container(width: 1, height: 32, color: colors.divider),
            Expanded(child: _StatCell(item: stats[i])),
          ],
        ],
      ),
    );
  }
}

class _StatCell extends StatelessWidget {
  final _Stat item;

  const _StatCell({required this.item});

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(item.icon, size: 14, color: colors.textSecondary),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: colors.textSecondary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            item.value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: colors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

class _SegOption {
  final IconData icon;
  final String label;
  final String desc;

  const _SegOption({required this.icon, required this.label, required this.desc});
}

/// 同步模式分段选择：用一块圆角高亮在左右选项间**弹性滑动**（底部高亮片动画），
/// 选项只显示图标 + 短标签（单行），避免窄屏溢出；详细说明在控件下方单独展示。
class _Segmented extends StatelessWidget {
  final int value;
  final List<_SegOption> options;
  final ValueChanged<int> onChanged;

  const _Segmented({
    required this.value,
    required this.options,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.divider),
      ),
      child: SizedBox(
        height: 92,
        child: Stack(
          children: [
            // 弹性滑动的底部高亮片。
            AnimatedAlign(
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOutCubic,
              alignment: value == 0
                  ? Alignment.centerLeft
                  : Alignment.centerRight,
              child: FractionallySizedBox(
                widthFactor: 1 / options.length,
                heightFactor: 1,
                child: Padding(
                  padding: const EdgeInsets.all(3),
                  child: Container(
                    decoration: BoxDecoration(
                      color: colors.surface,
                      borderRadius: BorderRadius.circular(11),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.06),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // 前景选项：整个单元都是可点区域（SizedBox.expand）。
            Row(
              children: [
                for (var i = 0; i < options.length; i++)
                  Expanded(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(11),
                      onTap: () => onChanged(i),
                      child: SizedBox.expand(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 12,
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    options[i].icon,
                                    size: 22,
                                    color: i == value
                                        ? NarrChatTheme.primary
                                        : colors.textSecondary,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    options[i].label,
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700,
                                      color: i == value
                                          ? colors.textPrimary
                                          : colors.textSecondary,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(
                                options[i].desc,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 12,
                                  height: 1.3,
                                  color: colors.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  final String message;

  const _ErrorBox({required this.message});

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colors.historyBackground,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.historyHeader),
      ),
      child: Text(
        message,
        style: TextStyle(fontSize: 12, color: colors.textPrimary),
      ),
    );
  }
}

String _shortDevice(String id) {
  if (id.isEmpty) return '—';
  final parts = id.split('-');
  return parts.first.length <= 8 ? parts.first : parts.first.substring(0, 8);
}
