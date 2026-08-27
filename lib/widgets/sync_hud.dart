import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/cloud_sync_provider.dart';
import '../providers/round_provider.dart';
import '../services/sync/sync_models.dart';
import '../theme/app_theme.dart';

/// 应用级同步悬浮 HUD（挂在 [Stack] 顶层）。
///
/// - 仅在 `CloudSyncProvider.syncState == syncing` 时出现；
/// - 默认**水平居中**、位于标题栏下方（不遮挡控件），展示 [SyncProgressEvent] 的
///   阶段 / 进度 / 当前文件；
/// - 提供「取消」按钮（回调 `CloudSyncProvider.cancelSync`），可拖动位置、可折叠；
/// - 左侧拖动手柄图标提示可拖动（桌面端悬停显示移动光标）；
/// - **不记忆拖动位置**：同步结束后 HUD 消失，下一次显示时回到默认初始位置；
/// - 当 `GenerationBanner` 可见（`RoundProvider.activeGenerationBookIds` 非空）时
///   自动下移一排，避免互相遮挡。
class SyncHud extends StatefulWidget {
  const SyncHud({super.key});

  @override
  State<SyncHud> createState() => _SyncHudState();
}

class _SyncHudState extends State<SyncHud> {
  /// 当前相对默认位置的拖动偏移（同步结束后重置为默认）。
  Offset _offset = Offset.zero;
  bool _collapsed = false;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<CloudSyncProvider>();
    if (provider.syncState != SyncState.syncing) {
      // 消失即复位：下一次显示回到默认位置（不记忆拖动位置）。
      _offset = Offset.zero;
      _collapsed = false;
      return const SizedBox.shrink();
    }

    final bannerVisible = context.watch<RoundProvider>().activeGenerationBookIds.isNotEmpty;
    final media = MediaQuery.of(context);
    final safeTop = media.padding.top;
    // 默认位：标题栏（AppBar）下方 + 8；拖动偏移附加；GenerationBanner 可见时再下移一排。
    final top = safeTop + kToolbarHeight + 8 + _offset.dy + (bannerVisible ? 44 : 0);

    // 水平居中 + 拖动偏移：整行居中，胶囊按 dx 平移（拖动后仍可回中）。
    return Stack(
      children: [
        Positioned(
          top: top,
          left: 0,
          right: 0,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Transform.translate(
                offset: Offset(_offset.dx, 0),
                child: MouseRegion(
                  cursor: SystemMouseCursors.move,
                  child: GestureDetector(
                    onPanUpdate: (d) => setState(() => _offset += d.delta),
                    child: _buildPill(context, provider, media.size.width),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPill(BuildContext context, CloudSyncProvider provider, double width) {
    final scheme = Theme.of(context).colorScheme;
    final progress = provider.progress;
    final label = progress?.label ?? '同步中…';
    final phase = progress?.phase;

    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(999),
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 拖动手柄：明确提示此框可拖动。
            Tooltip(
              message: '拖动可移动位置',
              child: Icon(
                Icons.drag_indicator,
                size: 16,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 2),
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: NarrChatTheme.primary,
              ),
            ),
            if (!_collapsed) ...[
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: width * 0.5 - 120),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${_phaseLabel(phase)}${label.isEmpty ? '' : ' · $label'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: scheme.onSurface),
                    ),
                    if (progress?.fraction != null) ...[
                      const SizedBox(height: 2),
                      SizedBox(
                        width: 180,
                        child: LinearProgressIndicator(
                          value: progress!.fraction!.clamp(0.0, 1.0),
                          minHeight: 3,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
            IconButton(
              visualDensity: VisualDensity.compact,
              iconSize: 16,
              tooltip: _collapsed ? '展开详情' : '收起详情',
              onPressed: () => setState(() => _collapsed = !_collapsed),
              icon: Icon(_collapsed ? Icons.expand_more : Icons.expand_less, size: 16),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              iconSize: 16,
              tooltip: '取消同步',
              onPressed: provider.cancelSync,
              icon: const Icon(Icons.close, size: 16),
            ),
          ],
        ),
      ),
    );
  }

  String _phaseLabel(SyncPhase? phase) {
    if (phase == null) return '';
    return switch (phase) {
      SyncPhase.bootstrap => '初始化云端',
      SyncPhase.pullManifest => '读取清单',
      SyncPhase.pullSnapshot => '下载快照',
      SyncPhase.merge => '合并数据',
      SyncPhase.applyLocal => '落地合并',
      SyncPhase.pushSnapshot => '上传快照',
      SyncPhase.pushImages => '上传图片',
      SyncPhase.pullImages => '下载图片',
      SyncPhase.deleteImages => '清理图片',
      SyncPhase.pushManifest => '提交清单',
      SyncPhase.updateCursor => '刷新游标',
      SyncPhase.acquireLock => '获取锁',
      SyncPhase.idle => '同步',
    };
  }
}
