import 'package:flutter/material.dart';

import '../services/debug_database_service.dart';
import '../services/debug_file_service.dart';
import '../services/update_check_service.dart';
import '../theme/app_theme.dart';
import '../utils/release_info.dart';
import '../widgets/app_notice_overlay.dart';
import '../widgets/island_bar.dart';
import '../widgets/narr_chat_app_bar.dart';
import '../widgets/update_available_dialog.dart';
import 'debug_files_screen.dart';

/// 「调试」页面：隐藏的调试选项菜单（由设置→关于页连点版本号进入）。
///
/// 目前提供三个入口：只读浏览全部数据文件；查看各数据库版本；
/// 触发「发现新版本」提示框（调试用，即使版本相同或更旧也触发）。
/// 后续调试功能可在此追加选项。
class DebugScreen extends StatelessWidget {
  /// [databaseService] / [fileService] 供测试注入；缺省使用真实实现。
  const DebugScreen({
    super.key,
    this.databaseService,
    this.fileService,
    this.updateService,
  });

  final DebugDatabaseService? databaseService;

  final DebugFileService? fileService;

  /// 更新检查服务（供测试注入替身；缺省使用真实 GitHub 实现）。
  final UpdateCheckService? updateService;

  /// 打开调试页。
  static Future<void> open(BuildContext context) {
    return Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const DebugScreen()));
  }

  /// 打开只读文件浏览：从应用数据根目录开始，按类型匹配阅读器。
  void _openDataFiles(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DebugFilesScreen(
          fileService: fileService ?? LocalDebugFileService(),
          databaseService: databaseService ?? SqliteDebugDatabaseService(),
        ),
      ),
    );
  }

  /// 展示各库版本：3.0 起数据分成多个库文件，逐个列出实际 `user_version`
  /// 与期望值；读取失败（库被占用 / 损坏等）时以悬浮通知提示。
  Future<void> _showDatabaseVersion(BuildContext context) async {
    final service = databaseService ?? SqliteDebugDatabaseService();
    try {
      final databases = await service.listDatabases();
      if (!context.mounted) return;
      final existing = databases.where((db) => db.exists).toList();
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('数据库版本'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('3.0 起数据分成多个库文件，各自带版本号：'),
                const SizedBox(height: 10),
                if (existing.isEmpty)
                  const Text('还没有任何库文件。', style: TextStyle(fontSize: 12))
                else
                  for (final db in existing)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        '${db.label}：${db.actualVersion}'
                        '${db.versionMatches ? '' : '（期望 ${db.expectedVersion}）'}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      context.notices.error('读取数据库版本失败：$e', copyable: true);
    }
  }

  /// 触发「发现新版本」提示框（调试用）：不管开关与版本比较，绕过 24h 节流，
  /// 仅演示远端最新 Release 的提示框；检查失败 / 无发布时以悬浮通知提示。
  /// 返回值（跳过版本等）不落盘，避免污染真实的启动检查状态。
  Future<void> _probeUpdateDialog(BuildContext context) async {
    final currentVersion = await ReleaseInfo.version();
    final result = await (updateService ?? UpdateCheckService()).check(
      currentVersion: currentVersion,
      forceShow: true,
    );
    if (!context.mounted) return;
    switch (result) {
      case UpdateAvailable(:final release):
        await showUpdateAvailableDialog(
          context,
          release: release,
          currentVersion: currentVersion,
        );
      case CheckFailed(:final reason):
        context.notices.error('检查更新失败：$reason');
      case UpToDate() || NoRelease():
        // forceShow 下正常不会走到这里（仓库有发布即返回 UpdateAvailable）；
        // 保留分支仅为穷尽枚举并给出可读反馈。
        context.notices.warning('未获取到 GitHub 发布信息');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    return IslandAwareScaffold(
      backgroundColor: colors.background,
      appBarBuilder: (context, extraRow) =>
          NarrChatAppBar(extraRowHeight: extraRow, title: '调试'),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _DebugOptionCard(
            icon: Icons.folder_open_outlined,
            label: '查看全部数据文件（只读）',
            onTap: () => _openDataFiles(context),
          ),
          const SizedBox(height: 12),
          _DebugOptionCard(
            icon: Icons.info_outline,
            label: '查看各数据库版本',
            onTap: () => _showDatabaseVersion(context),
          ),
          const SizedBox(height: 12),
          _DebugOptionCard(
            icon: Icons.system_update_alt,
            label: '触发检查到更新的提示框（即使版本相同或更旧也触发）',
            onTap: () => _probeUpdateDialog(context),
          ),
        ],
      ),
    );
  }
}

/// 调试选项卡片：图标 + 文案 + 尾箭头。
class _DebugOptionCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _DebugOptionCard({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.divider),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Icon(icon, size: 18, color: colors.textSecondary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(fontSize: 14, color: colors.textPrimary),
                  ),
                ),
                Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: colors.textSecondary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
