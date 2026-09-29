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
import 'island_bar.dart';
import 'notice_visuals.dart';

/// 驻场通知渠道：**收起时嵌进顶栏、展开时脱离成悬浮卡片**的灵动岛式胶囊。
///
/// 统一承载三类常驻信息（取代原 `SyncHud` / `SyncResultBubble` / `GenerationBanner`）：
/// - **同步进度**：分平面阶段 / 计数 / 进度条；
/// - **同步结果**：成功 / 中性 3 秒、警告 5 秒、失败 15 秒后自动收起
///   （失败条目另有「已读」按钮可提前收起）；
/// - **正在生成**：`N本书正在生成……`，点击条目跳转对应书；
///
/// 与顶栏的协作（见 [IslandBarController]）：
/// - 顶栏把「槽位矩形」发布出来 → 收起态胶囊画在该矩形里（宽屏居中嵌入工具栏，
///   窄屏 / 预算不足时顶栏向下多出一行）；
/// - 点击胶囊 → 200ms 从槽位脱离到悬浮位置（顶栏下方 +8、居中、宽 `min(360, 窗口-24)`），
///   槽位处留下一枚小标记，点击标记即可把岛收回顶栏；
/// - 页面没有槽位（对话框 / 独立窗口 / 未接顶栏的页面）时退化为顶部悬浮。
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

  /// 「嵌入顶栏 → 脱离悬浮」动画时长。
  static const Duration _detachDuration = Duration(milliseconds: 200);

  /// 出现 / 消失时**宽度变化**的非线性曲线（手机厂商的岛多为「快出慢收」）。
  static const Curve _unfoldCurve = Curves.easeOutCubic;

  /// 展开态宽度上限（窄屏取窗口宽 - 24）。
  static const double _panelWidth = 360;

  /// 展开区高度上限占窗口比例（超出内部滚动）。
  static const double _panelMaxHeightRatio = 0.3;

  /// 出现 / 消失时的垂直位移（自顶部落入原位；嵌入态不做位移）。
  static const double _presenceSlide = 12;

  /// 悬浮时与顶栏（槽位下缘）的间距。
  static const double _floatGap = 10;

  bool _expanded = false;
  late final AnimationController _expand = AnimationController(
    vsync: this,
    duration: _expandDuration,
    value: 1,
  );

  /// 出现度：0 = 完全隐藏，1 = 完全就位。
  late final AnimationController _presence = AnimationController(
    vsync: this,
    duration: _presenceDuration,
  );

  /// 脱离度：0 = 嵌在顶栏槽位，1 = 悬浮。仅在有槽位时有效。
  ///
  /// 初值为 0（嵌入态）：槽位出现时不会先从悬浮位置闪一下再归位。
  late final AnimationController _detach = AnimationController(
    vsync: this,
    duration: _detachDuration,
  );

  /// 上一次期望的出现状态（避免每帧重复调度）。
  bool? _wantPresent;

  /// 上一次期望的脱离状态（避免每帧重复调度）。
  bool? _wantDetached;

  /// 上一次推送给顶栏控制器的「有无内容 / 是否展开」。
  bool? _pushedActive;
  bool? _pushedExpanded;

  /// 收起态时槽位的矩形（脱离动画的起点）。
  ///
  /// 岛一展开，顶栏就把槽位收缩为小标记（矩形随之变化），因此必须缓存
  /// 「收起时那次」的矩形，脱离动画才不会从 24px 的小标记位置开始。
  Rect? _embeddedRect;

  /// 隐藏动画期间用于继续渲染的最后一帧内容快照。
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
    _detach.dispose();
    super.dispose();
  }

  /// 同步结果条目的自动撤销定时器：新条目起计时，已移除的条目取消计时。
  ///
  /// 计时不依赖展开态 / 是否渲染（收起时条目不在渲染树内，定时器仍归本 State），
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

  /// 按「是否展开 + 是否有顶栏槽位」驱动脱离 / 归位动画。
  void _syncDetach(bool wanted) {
    if (_wantDetached == wanted) return;
    _wantDetached = wanted;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (wanted) {
        _detach.forward();
      } else {
        _detach.reverse();
      }
    });
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

    final present =
        activePlanes.isNotEmpty || generatingUuids.isNotEmpty || toasts.isNotEmpty;
    // 出现 / 消失动画由「有无内容」驱动（帧后执行，见 _syncPresence）。
    _syncPresence(present);

    // 岛的存在状态汇报给顶栏控制器（驱动顶栏附加行高度与槽位形态）；
    // 汇报会让统一顶栏重建，因此放到帧后执行，避免 build 期间标记重建。
    //
    // 「存在」的判据是 **有内容 或 仍在播放消失动画**：槽位必须留到岛完全收窄
    // 消失为止，否则消失动画会在中途被抽走锚点、退化成悬浮淡出；因此这一步
    // 必须放在「完全隐藏」的提前返回之前（否则永远收不回顶栏附加行）。
    final bar = IslandBarScope.maybeOf(context);
    _syncBarFlags(bar, present || _presence.value > 0);

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

    if (bar == null) {
      // 无岛宿主（独立窗口等）：直接走悬浮。
      _syncDetach(false);
      return _buildFloating(context, content, present);
    }
    return ListenableBuilder(
      listenable: Listenable.merge([bar.slotRect, bar.barRect]),
      builder: (context, child) {
        final slotRect = bar.slotRect.value;
        // 收起态记录槽位矩形（脱离动画的起点）。
        if (slotRect != null && !_expanded) _embeddedRect = slotRect;
        // 有槽位才存在「脱离」概念；无槽位时始终按悬浮处理。
        _syncDetach(_expanded && slotRect != null);
        if (slotRect == null) {
          _embeddedRect = null;
          return _buildFloating(context, content, present);
        }
        return _buildSlotAnchored(context, content, slotRect, bar, present);
      },
    );
  }

  /// 把「是否存在（有内容或仍在收窄）/ 是否展开」推给顶栏控制器
  /// （帧后执行，且仅在变化时推送）。
  void _syncBarFlags(IslandBarController? bar, bool active) {
    if (bar == null) return;
    if (_pushedActive == active && _pushedExpanded == _expanded) return;
    _pushedActive = active;
    _pushedExpanded = _expanded;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final controller = IslandBarScope.maybeOf(context);
      controller?.setIslandActive(active);
      controller?.setIslandExpanded(_expanded);
    });
  }

  // ---------------------------------------------------------------------------
  // 定位：嵌入顶栏槽位（并支持脱离为悬浮）
  // ---------------------------------------------------------------------------

  /// 槽位锚定：收起态画在槽位里；展开态从槽位脱离到悬浮位置，槽位处留小标记。
  Widget _buildSlotAnchored(
    BuildContext context,
    _IslandContent content,
    Rect slot,
    IslandBarController bar,
    bool present,
  ) {
    final media = MediaQuery.of(context);
    final panelWidth = math.min(_panelWidth, media.size.width - 24);
    // 脱离起点用「收起时缓存的槽位矩形」；顶栏此刻已把槽位收缩为小标记。
    //
    // 缓存缺失、或缓存到的是小标记尺寸（顶栏已收缩 / 刚切换页面）时，退化为
    // 悬浮形态：否则卡片会被挤进 24px 的标记槽位里而产生溢出。
    final cached = _embeddedRect;
    if (cached == null || cached.width < kIslandMinWidth) {
      return _buildFloating(context, content, present);
    }
    final embedded = cached;
    // 悬浮位置贴住顶栏下缘（顶栏矩形由统一顶栏汇报；缺失时退化为槽位下缘）。
    final barBottom = bar.barRect.value?.bottom ?? embedded.bottom;
    final floatTop = math.max(embedded.bottom, barBottom) + _floatGap;

    return AnimatedBuilder(
      animation: Listenable.merge([_presence, _detach]),
      builder: (context, _) {
        final t = Curves.easeOutCubic.transform(_detach.value);
        // 出现度：非线性宽度因子（0 = 宽度归零，1 = 完整宽度）。
        final unfold = _unfoldCurve.transform(_presence.value);
        // 目标宽度：收起态 = 槽位可用宽（卡片本身按内容成形），展开态 = 面板宽。
        final targetWidth = embedded.width + (panelWidth - embedded.width) * t;
        final top = embedded.top + (floatTop - embedded.top) * t;
        final radius = 999.0 + (kNoticeRadius - 999.0) * t;
        final elevation = 6.0 * t;
        return Stack(
          children: [
            if (unfold > 0)
              Positioned(
                // 目标矩形与悬浮矩形都水平居中，因此按目标宽居中摆放即可。
                left: media.size.width / 2 - targetWidth / 2,
                top: top,
                width: targetWidth,
                child: Center(
                  // 手机厂商的岛式动画：**非线性地改变岛的实际宽度**（自中心向
                  // 左右张开 / 自两侧向中心收窄），并由**圆角**裁剪成形——
                  // 因此任何时刻的轮廓都是一枚圆角胶囊，而不是直角遮罩。
                  child: ClipRRect(
                    key: const ValueKey('island_unfold_clip'),
                    borderRadius: BorderRadius.circular(radius),
                    child: Align(
                      key: const ValueKey('island_unfold'),
                      alignment: Alignment.center,
                      widthFactor: unfold,
                      child: _buildCard(
                        context,
                        content: content,
                        contentWidth: panelWidth,
                        panelMaxHeight:
                            media.size.height * _panelMaxHeightRatio,
                        radius: radius,
                        elevation: elevation,
                        borderOpacity: unfold,
                      ),
                    ),
                  ),
                ),
              ),
            // 展开脱离后：槽位处留下小标记（点击收回顶栏）；
            // 收回过程中随脱离度淡出，与「岛降回顶栏」连续衔接。
            if (t > 0)
              Positioned(
                left: slot.left,
                top: slot.top,
                width: slot.width,
                height: slot.height,
                child: Opacity(
                  // 与「岛降回顶栏」（t↓）和「岛整体收窄消失」（unfold↓）双重衔接。
                  opacity: t * unfold,
                  child: _buildMarker(context, content),
                ),
              ),
          ],
        );
      },
    );
  }

  /// 无顶栏槽位（对话框 / 未接顶栏的页面 / 独立窗口）时的退化形态：
  /// 顶部居中悬浮（与嵌入协作启用前一致）。
  Widget _buildFloating(
    BuildContext context,
    _IslandContent content,
    bool present,
  ) {
    final media = MediaQuery.of(context);
    final panelWidth = math.min(_panelWidth, media.size.width - 24);
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
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
            contentWidth: panelWidth,
            panelMaxHeight: media.size.height * _panelMaxHeightRatio,
            radius: _expanded ? 16 : 999,
            elevation: 6,
          ),
        ),
      ),
    );
  }

  /// 展开态槽位里的小标记：黑底 + 当前主图标（点击收回顶栏）。
  Widget _buildMarker(BuildContext context, _IslandContent content) {
    final leading = _headerSpec(context, expanded: false, content: content).leading;
    return Center(
      child: GestureDetector(
        onTap: _toggle,
        behavior: HitTestBehavior.opaque,
        child: Tooltip(
          message: '收回顶栏',
          child: Material(
            color: kNoticeSurface,
            shape: const StadiumBorder(side: BorderSide(color: kNoticeBorder)),
            child: SizedBox(
              width: kIslandMarkerSize,
              height: kIslandMarkerSize,
              child: Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: FittedBox(child: leading),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 卡片本体
  // ---------------------------------------------------------------------------

  /// 胶囊 / 展开面板本体（黑底卡片；[radius] / [elevation] 由脱离动画插值）。
  ///
  /// 卡片按**内容**成形（收起态即一枚胶囊），宽度动画由外层 [ClipRRect] +
  /// [Align] 完成：[borderOpacity] 让描边随展开度淡入，避免半开时只余上下两条边。
  Widget _buildCard(
    BuildContext context, {
    required _IslandContent content,
    required double contentWidth,
    required double panelMaxHeight,
    required double radius,
    required double elevation,
    double borderOpacity = 1,
  }) {
    final body = _expanded
        ? SizedBox(
            width: contentWidth,
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
        elevation: elevation,
        // 关掉 M3 表面着色，保持纯黑底。
        surfaceTintColor: Colors.transparent,
        color: kNoticeSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: BorderSide(
            color: Colors.white.withValues(alpha: 0.12 * borderOpacity),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: body,
      ),
    );
  }

  /// 头部内容规格：图标 + 主文案 + 其他活动段计数。
  ///
  /// 主文案优先级：**最新同步结果 > 同步进度 > 正在生成**（其余活动段以 `+N` 提示）；
  /// 展开态改为计数摘要（细节在展开区各自成行，避免重复文案）。
  ({Widget leading, String text, int extraCount}) _headerSpec(
    BuildContext context, {
    required bool expanded,
    required _IslandContent content,
  }) {
    final activePlanes = content.planes;
    final generatingUuids = content.generatingUuids;
    final toasts = content.toasts;

    final Widget leading;
    final String text;
    int extraCount = 0;
    if (expanded) {
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
    return (leading: leading, text: text, extraCount: extraCount);
  }

  /// 胶囊头部：图标 + 主文案（+ 其他活动段计数）+ 展开 / 收起箭头。
  Widget _buildHeader(
    BuildContext context, {
    required bool expanded,
    required _IslandContent content,
  }) {
    const textStyle = TextStyle(fontSize: 12.5, color: kNoticeTextPrimary);
    final spec = _headerSpec(context, expanded: expanded, content: content);

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
            spec.leading,
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                spec.text,
                maxLines: expanded ? 2 : 1,
                overflow: TextOverflow.ellipsis,
                style: textStyle,
              ),
            ),
            if (spec.extraCount > 0) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: kNoticeDivider,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '+${spec.extraCount}',
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

  Widget _spinner() => const SizedBox(
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
