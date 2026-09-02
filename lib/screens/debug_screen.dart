import 'package:flutter/material.dart';

import '../services/debug_database_service.dart';
import '../services/update_check_service.dart';
import '../theme/app_theme.dart';
import '../utils/release_info.dart';
import '../widgets/update_available_dialog.dart';
import 'database_inspect_screen.dart';

/// 「调试」页面：隐藏的调试选项菜单（由设置→关于页连点版本号进入）。
///
/// 目前提供三个入口：查看当前数据库版本；查看当前数据库结构、内容和表；
/// 触发「发现新版本」提示框（调试用，即使版本相同或更旧也触发）。
/// 后续调试功能可在此追加选项。
class DebugScreen extends StatelessWidget {
  /// [databaseService] 供测试注入；缺省使用真实 sqlite 实现。
  const DebugScreen({super.key, this.databaseService, this.updateService});

  final DebugDatabaseService? databaseService;

  /// 更新检查服务（供测试注入替身；缺省使用真实 GitHub 实现）。
  final UpdateCheckService? updateService;

  /// 打开调试页。
  static Future<void> open(BuildContext context) {
    return Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const DebugScreen()));
  }

  void _openDatabaseInspect(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DatabaseInspectScreen(
          service: databaseService ?? SqliteDebugDatabaseService(),
        ),
      ),
    );
  }

  /// 展示当前数据库版本：代码期望的 schema 版本 + 库文件实际 `user_version`；
  /// 读取失败（库被占用 / 损坏等）时以 SnackBar 提示。
  Future<void> _showDatabaseVersion(BuildContext context) async {
    final service = databaseService ?? SqliteDebugDatabaseService();
    try {
      final version = await service.readVersion();
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('数据库版本'),
          content: Text(
            '应用代码 schema 版本：${version.expectedVersion}\n'
            '数据库文件版本（user_version）：${version.actualVersion}',
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('读取数据库版本失败：$e')),
      );
    }
  }

  /// 触发「发现新版本」提示框（调试用）：不管开关与版本比较，绕过 24h 节流，
  /// 仅演示远端最新 Release 的提示框；检查失败 / 无发布时以 SnackBar 提示。
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('检查更新失败：$reason')),
        );
      case UpToDate() || NoRelease():
        // forceShow 下正常不会走到这里（仓库有发布即返回 UpdateAvailable）；
        // 保留分支仅为穷尽枚举并给出可读反馈。
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('未获取到 GitHub 发布信息')),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    return Scaffold(
      backgroundColor: colors.background,
      appBar: AppBar(title: const Text('调试')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _DebugOptionCard(
            icon: Icons.info_outline,
            label: '查看当前数据库版本',
            onTap: () => _showDatabaseVersion(context),
          ),
          const SizedBox(height: 12),
          _DebugOptionCard(
            icon: Icons.storage_outlined,
            label: '查看当前数据库结构、内容和表',
            onTap: () => _openDatabaseInspect(context),
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
                Icon(Icons.chevron_right, size: 18, color: colors.textSecondary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
