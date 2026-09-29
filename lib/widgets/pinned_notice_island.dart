import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/app_notice.dart';
import '../providers/book_provider.dart';
import '../providers/cloud_sync_provider.dart';
import '../providers/round_provider.dart';
import '../services/sync/sync_models.dart';
import '../theme/app_theme.dart';
import 'notice_visuals.dart';

/// 驻场通知渠道：顶部居中的「灵动岛」式常驻胶囊。
///
/// 统一承载三类常驻信息（取代原 `SyncHud` / `SyncResultBubble` / `GenerationBanner`）：
/// - **同步进度**：分平面阶段 / 计数 / 进度条；
/// - **同步结果**：成功 / 中性 3 秒、警告 5 秒、失败 15 秒后自动收起
///   （失败条目另有「已读」按钮可提前收起）；
/// - **正在生成**：`N本书正在生成……`，点击条目跳转对应书；
///
/// 交互：
/// - 收起态只有图标 + 一行主文案（无取消按钮）；
/// - 点击胶囊展开 200ms：展开区含分平面**取消**按钮、生成书列表、结果条目；
/// - **出现 / 消失都有 200ms 动画**（自顶部下移淡入、上移淡出）；
/// - 无任何内容时整体消失（收起态恢复为收起，不记忆展开状态）。
class PinnedNoticeIsland extends StatefulWidget {
  const PinnedNoticeIsland({super.key, required this.onOpenBook});

  /// 点击展开区里「正在生成的书」时回调（由接线方执行跳转）。
  final void Function(String bookUuid) onOpenBook;

  @override
  State<PinnedNoticeIsland> createState() => _PinnedNoticeIslandState();
}

class _PinnedNoticeIslandState extends State<PinnedNoticeIsland>
    with TickerProviderStateMixin {
  /// 展开动画时长（灵动岛式形变）。
  static const Duration _expandDuration = Duration(milliseconds: 200);

  /// 出现 / 消失动画时长。
  static const Duration _presenceDuration = Duration(milliseconds: 200);

  /// 展开态宽度上限（窄屏取窗口宽 - 24）。
  static const double _panelWidth = 360;

  /// 展开区高度上限占窗口比例（超出内部滚动）。
  static const double _panelMaxHeightRatio = 0.3;

  /// 出现 / 消失时的垂直位移（自上而下落入原位）。
  static const double _presenceSlide = 12;

  bool _expanded = false;
  late final AnimationController _expand = AnimationController(
    vsync: this,
    duration: _expandDuration,
    value: 1,
  );

  /// 出现度：0 = 完全隐藏，1 = 完全就位。由内容有无驱动（见 [_syncPresence]）。
  late final AnimationController _presence = AnimationController(
    vsync: this,
    duration: _presenceDuration,
  );

  /// 上一次期望的出现状态（避免每帧重复调度）。
  bool? _wantPresent;

  /// 消失动画期间用于继续渲染的最后一帧内容快照。
  _IslandContent? _snapshot;

  /// 结果条目 id → 自动撤销定时器（与是否展开无关）。
  final Map<int, Timer> _resultTimers = {};

  @override
  void dispose() {
    for (final t in _resultTimers.values) {
      t.cancel();
    }
    _resultTimers.clear();
    _expand.dispose();
    _presence.dispose();
    super.dispose();
  }

  /// 按「有无内容」驱动出现 / 消失动画。
  ///
  /// 在 build 中只登记期望值，真正的 `forward` / `reverse` 放到帧后执行：
  /// 动画控制器通知监听者，若在 build 中直接调用会触发「build 期间 setState」。
  void _syncPresence(bool wanted) {
    if (_wantPresent == wanted) return;
    _wantPresent = wanted;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (wanted) {
        _presence.forward();
        return;
      }
      _presence.reverse().whenComplete(() {
        // 淡出结束后回到收起态，下次出现从收起态开始。
        if (mounted) setState(() => _expanded = false);
      });
    });
  }

  /// 同步结果条目的自动撤销定时器：新条目起计时，已移除的条目取消计时。
  ///
  /// 计时不依赖展开态（收起时条目不在渲染树内，定时器仍归本 State），
  /// 因此「偶发异常下提示一直常驻」不再可能发生。
  void _syncResultTimers(List<SyncResultToast> toasts) {
    final ids = {for (final t in toasts) t.id};
    for (final id in _resultTimers.keys.toList()) {
      if (!ids.contains(id)) {
        _resultTimers.remove(id)?.cancel();
      }
    }
    for (final toast in toasts) {
      _resultTimers.putIfAbsent(
        toast.id,
        () => Timer(toast.dwell, () {
          _resultTimers.remove(toast.id);
          if (!mounted) return;
          context.read<CloudSyncProvider>().dismissSyncResult(toast.id);
        }),
      );
    }
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    if (_expanded) {
      _expand.forward(from: 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sync = context.watch<CloudSyncProvider>();
    // 收集「正在同步」的平面段（各段独立状态 / 进度 / 取消）。
    final activePlanes = <(SyncPlane, SyncProgressEvent?)>[
      if (sync.dataSyncState == SyncState.syncing)
        (SyncPlane.data, sync.dataProgress),
      if (sync.imageSyncState == SyncState.syncing)
        (SyncPlane.images, sync.imageProgress),
    ];
    // 只订阅「正在生成的书」这一低频信号（uuid 串接参与值比较）：
    // 流式增量不会重建本组件。
    final activeKeys = context.select<RoundProvider, String>(
      (p) => p.activeGenerationBookUuids.join('|'),
    );
    final generatingUuids = activeKeys.isEmpty
        ? const <String>[]
        : activeKeys.split('|');
    final toasts = sync.resultToasts;

    // 结果条目的自动撤销计时归本 State（与展开态无关：收起时也要到点兑现）。
    _syncResultTimers(toasts);

    final present = activePlanes.isNotEmpty ||
        generatingUuids.isNotEmpty ||
        toasts.isNotEmpty;
    // 出现 / 消失动画由「有无内容」驱动（帧后执行，见 _syncPresence）。
    _syncPresence(present);

    if (present) {
      _snapshot = _IslandContent(
        planes: activePlanes,
        generatingUuids: generatingUuids,
        toasts: toasts,
      );
    } else if (_presence.value == 0) {
      // 完全隐藏：不占位。
      return const SizedBox.shrink();
    }
    // 消失动画期间沿用最后一帧内容，避免内容「先消失再淡出」。
    final content = _snapshot;
    if (content == null) return const SizedBox.shrink();

    final media = MediaQuery.of(context);
    final panelWidth = math.min(_panelWidth, media.size.width - 24);

    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        // 标题栏（AppBar）下方 + 8：与页面标题/操作按钮错开。
        padding: EdgeInsets.only(
          top: media.padding.top + kToolbarHeight + 8,
          left: 12,
          right: 12,
        ),
        child: AnimatedBuilder(
          animation: _presence,
          builder: (context, child) {
            final t = Curves.easeOutCubic.transform(_presence.value);
            // 淡出播完且已无内容 → 从树上撤下（出现首帧仍保留内容，避免闪空）。
            if (t == 0 && !present) return const SizedBox.shrink();
            return Opacity(
              key: const ValueKey('island_presence'),
              opacity: t,
              child: Transform.translate(
                offset: Offset(0, -_presenceSlide * (1 - t)),
                child: child,
              ),
            );
          },
          child: _buildCard(
            context,
            content: content,
            panelWidth: panelWidth,
            panelMaxHeight: media.size.height * _panelMaxHeightRatio,
          ),
        ),
      ),
    );
  }

  /// 胶囊 / 展开面板本体（黑底卡片）。
  Widget _buildCard(
    BuildContext context, {
    required _IslandContent content,
    required double panelWidth,
    required double panelMaxHeight,
  }) {
    final body = _expanded
        ? SizedBox(
            width: panelWidth,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildHeader(context, expanded: true, content: content),
                SizeTransition(
                  sizeFactor: _expand,
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: panelMaxHeight),
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Divider(height: 1, color: kNoticeDivider),
                          for (final t in content.toasts)
                            _ResultRow(key: ValueKey('toast-${t.id}'), toast: t),
                          for (final (plane, progress) in content.planes)
                            _PlaneRow(
                              plane: plane,
                              text: _planeText(plane, progress),
                              fraction: progress?.fraction,
                            ),
                          for (final uuid in content.generatingUuids)
                            _GeneratingRow(
                              key: ValueKey('generating-$uuid'),
                              bookUuid: uuid,
                              onOpen: () {
                                setState(() => _expanded = false);
                                widget.onOpenBook(uuid);
                              },
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          )
        : _buildHeader(context, expanded: false, content: content);

    return Theme(
      // 通知表面恒为深色：覆盖选取高亮 / 光标 / 图标按钮前景色。
      data: noticeThemeOf(context),
      child: Material(
        elevation: 6,
        // 关掉 M3 表面着色，保持纯黑底。
        surfaceTintColor: Colors.transparent,
        color: kNoticeSurface,
        borderRadius: BorderRadius.circular(_expanded ? 16 : 999),
        clipBehavior: Clip.antiAlias,
        child: body,
      ),
    );
  }

  /// 胶囊头部：图标 + 主文案（+ 其他活动段计数）+ 展开/收起箭头。
  ///
  /// 主文案优先级：**最新同步结果 > 同步进度 > 正在生成**（其余活动段以 `+N` 提示）。
  Widget _buildHeader(
    BuildContext context, {
    required bool expanded,
    required _IslandContent content,
  }) {
    final activePlanes = content.planes;
    final generatingUuids = content.generatingUuids;
    final toasts = content.toasts;
    const textStyle = TextStyle(fontSize: 12.5, color: kNoticeTextPrimary);

    final Widget leading;
    final String text;
    int extraCount = 0;
    if (expanded) {
      // 展开态：头部只做**计数摘要**（细节在展开区各自成行，避免重复文案）。
      final parts = <String>[
        if (activePlanes.isNotEmpty) '同步中 ${activePlanes.length}',
        if (generatingUuids.isNotEmpty) '生成中 ${generatingUuids.length}',
        if (toasts.isNotEmpty) '结果 ${toasts.length}',
      ];
      text = parts.join(' · ');
      if (toasts.isNotEmpty) {
        final (icon, color) = noticeIconOf(toasts.last.kind);
        leading = Icon(icon, size: 16, color: color);
      } else {
        leading = _spinner();
      }
    } else if (toasts.isNotEmpty) {
      final latest = toasts.last;
      final (icon, color) = noticeIconOf(latest.kind);
      leading = Icon(icon, size: 16, color: color);
      text = latest.message;
      extraCount =
          (toasts.length - 1) + activePlanes.length + generatingUuids.length;
    } else if (activePlanes.isNotEmpty) {
      final (plane, progress) = activePlanes.first;
      leading = _spinner();
      text = _planeText(plane, progress);
      extraCount = (activePlanes.length - 1) + generatingUuids.length;
    } else {
      leading = _spinner();
      text = '${generatingUuids.length}本书正在生成……';
    }

    return InkWell(
      onTap: _toggle,
      // 深色底上的点击反馈：用白色低透明度，避免沿用浅色主题的深色水波纹。
      splashColor: kNoticeDivider,
      highlightColor: kNoticeDivider,
      child: Padding(
        padding: EdgeInsets.fromLTRB(10, 7, expanded ? 10 : 6, 7),
        child: Row(
          mainAxisSize: expanded ? MainAxisSize.max : MainAxisSize.min,
          children: [
            leading,
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                text,
                maxLines: expanded ? 2 : 1,
                overflow: TextOverflow.ellipsis,
                style: textStyle,
              ),
            ),
            if (extraCount > 0) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: kNoticeDivider,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '+$extraCount',
                  style: const TextStyle(
                    fontSize: 10,
                    color: kNoticeTextPrimary,
                  ),
                ),
              ),
            ],
            const SizedBox(width: 2),
            Icon(
              expanded ? Icons.expand_less : Icons.expand_more,
              size: 16,
              color: kNoticeTextSecondary,
            ),
          ],
        ),
      ),
    );
  }

  Widget _spinner() => SizedBox(
    width: 14,
    height: 14,
    child: CircularProgressIndicator(
      strokeWidth: 2,
      color: NarrChatTheme.primary,
    ),
  );

  /// 「数据同步 · 读取云端清单」/「图片同步 · 上传图片 3/30」。
  String _planeText(SyncPlane plane, SyncProgressEvent? progress) {
    final phase = progress?.phase;
    final label = progress?.label ?? '';
    final count = progress != null && progress.totalItems > 0
        ? '${progress.currentItem + 1}/${progress.totalItems}'
        : null;
    // Runner 的 label 已是人话描述（结尾省略号去掉）；缺失时回落到阶段名。
    final detail = label.isNotEmpty
        ? label.replaceFirst(RegExp(r'…$'), '')
        : (phase != null ? _phaseLabel(phase) : '');
    return [
      plane.label,
      if (detail.isNotEmpty) detail,
      ?count,
    ].join(' · ');
  }

  String _phaseLabel(SyncPhase phase) {
    return switch (phase) {
      SyncPhase.bootstrap => '初始化云端',
      SyncPhase.pullManifest => '读取清单',
      SyncPhase.pullSnapshot => '下载快照',
      SyncPhase.merge => '合并数据',
      SyncPhase.applyLocal => '落地合并',
      SyncPhase.pushSnapshot => '上传快照',
      SyncPhase.tombstoneMerge => '合并墓碑',
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

/// 结果条目：类型图标 + 可复制文案（失败类带「已读」）。
///
/// 自动撤销计时不在这里（归 [_PinnedNoticeIslandState]）：收起态条目不渲染，
/// 但计时必须照跑。
class _ResultRow extends StatelessWidget {
  const _ResultRow({super.key, required this.toast});

  final SyncResultToast toast;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = noticeIconOf(toast.kind);
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Icon(icon, size: 16, color: color),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: SelectableText(
                toast.message,
                style: const TextStyle(
                  fontSize: 12.5,
                  height: 1.3,
                  color: kNoticeTextPrimary,
                ),
              ),
            ),
          ),
          if (toast.kind == NoticeKind.error)
            TextButton(
              // 「已读」= 提前收起（15 秒到点也会无条件收起）。
              onPressed: () =>
                  context.read<CloudSyncProvider>().dismissSyncResult(toast.id),
              style: TextButton.styleFrom(
                foregroundColor: kNoticeTextPrimary,
                visualDensity: VisualDensity.compact,
                minimumSize: const Size(0, 28),
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              child: const Text('已读', style: TextStyle(fontSize: 12)),
            ),
        ],
      ),
    );
  }
}

/// 同步平面段：转圈 + 「平面名 · 阶段 · 计数」+ 进度条 + 本平面取消按钮。
class _PlaneRow extends StatelessWidget {
  const _PlaneRow({
    required this.plane,
    required this.text,
    required this.fraction,
  });

  final SyncPlane plane;
  final String text;
  final double? fraction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 5, 4, 5),
      child: Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: NarrChatTheme.primary,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: kNoticeTextPrimary,
                  ),
                ),
                if (fraction != null) ...[
                  const SizedBox(height: 3),
                  LinearProgressIndicator(
                    value: fraction!.clamp(0.0, 1.0),
                    minHeight: 3,
                    color: kNoticeTextPrimary,
                    backgroundColor: kNoticeDivider,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            iconSize: 16,
            tooltip: '取消${plane.label}',
            color: kNoticeTextSecondary,
            onPressed: () => context.read<CloudSyncProvider>().cancelSync(plane),
            icon: const Icon(Icons.close, size: 16),
          ),
        ],
      ),
    );
  }
}

/// 「正在生成的书」条目：spinner + 书名，点击跳转对应书。
class _GeneratingRow extends StatelessWidget {
  const _GeneratingRow({super.key, required this.bookUuid, required this.onOpen});

  final String bookUuid;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final books = context.watch<BookProvider>().books;
    String title = bookUuid;
    for (final b in books) {
      if (b.uuid == bookUuid) {
        title = b.title;
        break;
      }
    }
    return InkWell(
      onTap: onOpen,
      splashColor: kNoticeDivider,
      highlightColor: kNoticeDivider,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 7, 8, 7),
        child: Row(
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: kNoticeTextSecondary,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12.5,
                  color: kNoticeTextPrimary,
                ),
              ),
            ),
            const Icon(
              Icons.chevron_right,
              size: 16,
              color: kNoticeTextSecondary,
            ),
          ],
        ),
      ),
    );
  }
}

/// 驻场岛一帧内容快照（消失动画期间继续渲染最后一帧，避免内容先消失再淡出）。
class _IslandContent {
  const _IslandContent({
    required this.planes,
    required this.generatingUuids,
    required this.toasts,
  });

  final List<(SyncPlane, SyncProgressEvent?)> planes;
  final List<String> generatingUuids;
  final List<SyncResultToast> toasts;
}
