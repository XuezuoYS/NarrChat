import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/cloud_sync_provider.dart';
import '../services/sync/sync_models.dart';
import '../theme/app_theme.dart';

/// 应用级云同步结果悬浮气泡（挂在主界面顶层 [Stack]，与 [SyncHud] 同层，
/// 展示于标题栏下方居中位置）。
///
/// - **临时提示**（成功 / 取消类，[SyncResultToast.persistent] 为 false）：
///   悬浮约 2 秒后自动消失，不提供关闭按钮；
/// - **失败提示**（[SyncToastKind.error]）：驻留，等待用户点击「关闭」手动关闭；
/// - **内容可复制**：正文为 [SelectableText]，可长按 / 拖动选择并复制（含报错详情）；
/// - **多条目堆叠**：数据 / 图片平面先后结束的消息纵向堆叠
///   （最多 [CloudSyncProvider.maxResultToasts] 条），按先到先走顺序移出；
/// - **避让同步 HUD**：任一平面同步中（HUD 可见）时下移一排，避免互相遮挡
///   （HUD 被用户拖动后不跟随，属可接受的偶发重叠）。
class SyncResultBubble extends StatelessWidget {
  const SyncResultBubble({super.key});

  /// 同步进行中（HUD 可见）时结果气泡的下移间距（与 GenerationBanner 避让一致）。
  static const double _hudClearance = 44;

  /// 单条提示最大宽度（宽屏下限制，避免横跨整个窗口）。
  static const double _maxBubbleWidth = 520;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<CloudSyncProvider>();
    final toasts = provider.resultToasts;
    if (toasts.isEmpty) return const SizedBox.shrink();

    final hudVisible = provider.dataSyncState == SyncState.syncing ||
        provider.imageSyncState == SyncState.syncing;
    final media = MediaQuery.of(context);
    // 默认位与同步 HUD 相同（标题栏下方 + 8）；HUD 可见时再下移一排。
    final top = media.padding.top +
        kToolbarHeight +
        8 +
        (hudVisible ? _hudClearance : 0);
    final maxWidth = media.size.width - 48 < _maxBubbleWidth
        ? media.size.width - 48
        : _maxBubbleWidth;

    return Stack(
      children: [
        Positioned(
          top: top,
          left: 0,
          right: 0,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final t in toasts)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: maxWidth),
                      child: _SyncToastItem(
                        key: ValueKey(t.id),
                        toast: t,
                        onDismiss: () => provider.dismissSyncResult(t.id),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 单条结果气泡：图标 + 可复制文案（失败类带「关闭」按钮）。
class _SyncToastItem extends StatefulWidget {
  const _SyncToastItem({
    super.key,
    required this.toast,
    required this.onDismiss,
  });

  final SyncResultToast toast;
  final VoidCallback onDismiss;

  @override
  State<_SyncToastItem> createState() => _SyncToastItemState();
}

class _SyncToastItemState extends State<_SyncToastItem> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (!widget.toast.persistent) {
      // 成功 / 取消类提示：悬浮 2 秒后自动消失。
      _timer = Timer(const Duration(seconds: 2), widget.onDismiss);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color) = switch (widget.toast.kind) {
      SyncToastKind.success => (
          Icons.cloud_done_outlined,
          context.narrColors.success,
        ),
      SyncToastKind.error => (Icons.error_outline, scheme.error),
      SyncToastKind.info => (Icons.info_outline, scheme.onSurfaceVariant),
    };
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(12),
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(icon, size: 16, color: color),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: SelectableText(
                widget.toast.message,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.3,
                  color: scheme.onSurface,
                ),
              ),
            ),
            if (widget.toast.persistent)
              IconButton(
                visualDensity: VisualDensity.compact,
                iconSize: 16,
                tooltip: '关闭',
                onPressed: widget.onDismiss,
                icon: const Icon(Icons.close, size: 16),
              ),
          ],
        ),
      ),
    );
  }
}
