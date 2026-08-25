import 'package:flutter/material.dart';

import '../services/debug_database_service.dart';
import '../theme/app_theme.dart';
import 'database_inspect_screen.dart';

/// 「调试」页面：隐藏的调试选项菜单（由设置→关于页连点版本号进入）。
///
/// 目前提供一个入口——查看当前数据库结构、内容和表；后续调试功能可在此追加选项。
class DebugScreen extends StatelessWidget {
  /// [databaseService] 供测试注入；缺省使用真实 sqlite 实现。
  const DebugScreen({super.key, this.databaseService});

  final DebugDatabaseService? databaseService;

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
            icon: Icons.storage_outlined,
            label: '查看当前数据库结构、内容和表',
            onTap: () => _openDatabaseInspect(context),
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
