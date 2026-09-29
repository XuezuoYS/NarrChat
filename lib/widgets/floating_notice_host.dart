import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/app_notice.dart';
import '../services/app_notice_center.dart';
import 'notice_visuals.dart';

/// 悬浮通知渠道宿主：窗口正中半透明悬浮弹出（挂在应用顶层 [Stack]）。
///
/// 时序（常量见 [AppNoticeCenter]）：进入 200ms → 常驻 3s（可被调用点覆盖）
/// → 消失动画 1000ms；点击或按住划过立即进入消失动画，**鼠标悬停不触发**。
/// 单槽位：一次只显示一条，队列与去重由 [AppNoticeCenter] 负责。
class FloatingNoticeHost extends StatelessWidget {
  const FloatingNoticeHost({super.key});

  @override
  Widget build(BuildContext context) {
    final center = context.watch<AppNoticeCenter>();
    final notice = center.current;
    if (notice == null) return const SizedBox.shrink();
    // 空白区域不拦截指针：Align/Padding 自身不参与命中测试。
    return Align(
      alignment: Alignment.center,
      child: _FloatingNoticeCard(
        key: ValueKey(notice.id),
        notice: notice,
        exiting: center.isExiting,
        onDismiss: center.dismissCurrent,
        onExited: () => center.completeDismissal(notice.id),
      ),
    );
  }
}

/// 单条悬浮通知：按 [AppNoticeCenter] 的退出标记播放动画并在播完后回报中心。
class _FloatingNoticeCard extends StatefulWidget {
  const _FloatingNoticeCard({
    super.key,
    required this.notice,
    required this.exiting,
    required this.onDismiss,
    required this.onExited,
  });

  final AppNotice notice;
  final bool exiting;
  final VoidCallback onDismiss;
  final VoidCallback onExited;

  @override
  State<_FloatingNoticeCard> createState() => _FloatingNoticeCardState();
}

class _FloatingNoticeCardState extends State<_FloatingNoticeCard>
    with SingleTickerProviderStateMixin {
  /// 进入动画宽度上限（宽屏下不横跨整个窗口）。
  static const double _maxWidth = 520;

  /// 移动端阈值：窄屏用近满宽，保证文本可查阅。
  static const double _narrowWidth = 600;

  /// 高度上限占窗口比例：超出后内容可滚动（非选择态），避免遮满屏幕。
  static const double _maxHeightRatio = 0.45;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppNoticeCenter.enterDuration,
    value: 1,
  );

  @override
  void initState() {
    super.initState();
    _controller.forward(from: 0);
    if (widget.exiting) _playExit();
  }

  @override
  void didUpdateWidget(covariant _FloatingNoticeCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.exiting && !oldWidget.exiting) _playExit();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 播放 1s 消失动画；播完回报中心移除本条并接上队列下一条。
  ///
  /// 用 [AnimationController.animateBack] 而非 `reverse()`：无论当前动画进度
  /// 如何（例如进入动画尚未播完就被点击），消失动画都保证走满 1 秒。
  void _playExit() {
    _controller.animateBack(0, duration: AppNoticeCenter.exitDuration).whenComplete(() {
      // 未挂载说明宿主已被整体移除（中心另有兜底定时器），不再回报。
      if (mounted) widget.onExited();
    });
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final maxWidth = media.size.width < _narrowWidth
        ? media.size.width - 24
        : math.min(_maxWidth, media.size.width - 32);
    final (icon, color) = noticeIconOf(widget.notice.kind);
    const textStyle = TextStyle(
      fontSize: 13,
      height: 1.35,
      color: kNoticeTextPrimary,
    );

    return FadeTransition(
      opacity: _controller,
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.96, end: 1).animate(
          CurvedAnimation(parent: _controller, curve: Curves.easeOut),
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: maxWidth,
            maxHeight: media.size.height * _maxHeightRatio,
          ),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            // 点击 / 按住划过 → 提前消失动画；悬停不做任何事。
            onTap: widget.onDismiss,
            onPanStart: (_) => widget.onDismiss(),
            onPanUpdate: (_) => widget.onDismiss(),
            child: Theme(
              // 通知表面恒为深色：覆盖选取高亮 / 光标 / 图标按钮前景色。
              data: noticeThemeOf(context),
              child: Material(
                elevation: 8,
                // 关掉 M3 表面着色，保证黑色半透明不被色调覆盖。
                surfaceTintColor: Colors.transparent,
                color: kNoticeSurfaceTranslucent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(kNoticeRadius),
                  side: const BorderSide(color: kNoticeBorder),
                ),
                clipBehavior: Clip.antiAlias,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    14,
                    10,
                    widget.notice.copyable ? 4 : 14,
                    10,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 1),
                        child: Icon(icon, size: 16, color: color),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: SingleChildScrollView(
                          child: widget.notice.copyable
                              ? SelectableText(
                                  widget.notice.message,
                                  style: textStyle,
                                )
                              : Text(widget.notice.message, style: textStyle),
                        ),
                      ),
                      if (widget.notice.copyable) ...[
                        const SizedBox(width: 4),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          iconSize: 16,
                          tooltip: '关闭',
                          color: kNoticeTextSecondary,
                          onPressed: widget.onDismiss,
                          icon: const Icon(Icons.close, size: 16),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
