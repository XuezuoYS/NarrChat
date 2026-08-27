import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/cloud_sync_provider.dart';
import '../services/sync/sync_models.dart';
import '../theme/app_theme.dart';

/// 同步状态章（小胶囊）：在首页 / 书库头部展示当前云同步状态。
///
/// - 未连接：灰点 + 「未连接」；
/// - 同步中：品牌色 + 「同步中…」；
/// - 已同步：绿色 + 「已同步」；
/// - 同步失败：红 + 「同步失败」（可点开看原因）。
///
/// 点击交给 [onTap]（通常跳转到云同步设置页）。颜色走 [NarrChatColors] 自适应主题。
class SyncStatusChip extends StatelessWidget {
  final VoidCallback? onTap;

  const SyncStatusChip({super.key, this.onTap});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<CloudSyncProvider>();
    final configured = provider.isConfigured;
    if (!configured) return const SizedBox.shrink();

    final (label, color) = switch (provider.syncState) {
      SyncState.syncing => ('同步中…', NarrChatTheme.primary),
      SyncState.success => ('已同步', context.narrColors.success),
      SyncState.error => ('同步失败', Theme.of(context).colorScheme.error),
      SyncState.idle => ('已连接', context.narrColors.success),
    };

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
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
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
