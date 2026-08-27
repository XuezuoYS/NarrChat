import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/cloud_sync_provider.dart';
import '../services/sync/sync_models.dart';
import '../theme/app_theme.dart';

/// 同步状态章（小胶囊）：在首页 / 书库头部展示当前云同步状态。
///
/// 聚合两平面（数据 / 图片）为单枚指示，文案区分平面：
/// - 未连接：灰点 + 「未连接」；
/// - 仅数据平面同步中：「数据同步中…」；仅图片：「图片同步中…」；两者：「同步中…」；
/// - 任一失败：红 + 「同步失败」（可点开看原因）；
/// - 已同步：绿色 + 「已同步」；
/// - 空闲：「已连接」。
///
/// 点击交给 [onTap]（通常跳转到云同步设置页）。颜色走 [NarrChatColors] 自适应主题。
/// 各平面的详细进度看应用级悬浮 HUD（分平面段独立显示）。
class SyncStatusChip extends StatelessWidget {
  final VoidCallback? onTap;

  const SyncStatusChip({super.key, this.onTap});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<CloudSyncProvider>();
    final configured = provider.isConfigured;
    if (!configured) return const SizedBox.shrink();

    final (label, color) = _aggregate(provider, context);

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

  /// 两平面聚合：syncing（文案带平面名）> error > success > idle。
  static (String, Color) _aggregate(CloudSyncProvider provider, BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = context.narrColors;
    final data = provider.dataSyncState;
    final images = provider.imageSyncState;
    final dataSyncing = data == SyncState.syncing;
    final imageSyncing = images == SyncState.syncing;
    if (dataSyncing || imageSyncing) {
      final label = dataSyncing && imageSyncing
          ? '同步中…'
          : dataSyncing
          ? '${SyncPlane.data.label}中…'
          : '${SyncPlane.images.label}中…';
      return (label, NarrChatTheme.primary);
    }
    if (data == SyncState.error || images == SyncState.error) {
      return ('同步失败', scheme.error);
    }
    if (data == SyncState.success || images == SyncState.success) {
      return ('已同步', colors.success);
    }
    return ('已连接', colors.success);
  }
}
