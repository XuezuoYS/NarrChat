import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// 设置页统一版式组件：页面头 / 分区头 / 卡片 / 可展开卡片。
///
/// 圆角与动效统一取 [NarrChatTheme] 的常量
/// （cardRadius / controlRadius / motionFast / motionNormal / motionCurve），
/// 页面不要再手写其它圆角或曲线。
///
/// 布局约定：
/// - [SettingsPageHeader]：每个面板顶部（标题 + 一行描述）；
/// - [SettingsSection]：分区头在卡片外（大多数设置分区）；
/// - [SettingsCardHeader]：分区头在卡片内（云同步 / 字体设置等特色卡片）；
/// - [SettingsCard]：统一的圆角 + 1px 描边内容面；
/// - [SettingsExpandableCard]：可展开卡片（平台 / 模型），展开收起有动画。

/// 统一动效工具：系统开启「减少动画」时把时长压成 0。
abstract final class SettingsMotion {
  /// 按系统动画偏好返回实际时长。
  static Duration of(BuildContext context, Duration base) =>
      MediaQuery.disableAnimationsOf(context) ? Duration.zero : base;
}

/// 设置面板页头：标题（18 / w700）+ 可选描述（12 / 次要色）。
class SettingsPageHeader extends StatelessWidget {
  /// 面板标题。
  final String title;

  /// 标题下方的一行描述（可选）。
  final String? description;

  /// 标题右侧的自定义内容（可选）。
  final Widget? trailing;

  const SettingsPageHeader({
    super.key,
    required this.title,
    this.description,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: colors.textPrimary,
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
          if (description != null) ...[
            const SizedBox(height: 4),
            Text(
              description!,
              style: TextStyle(
                fontSize: 12,
                height: 1.4,
                color: colors.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 统一设置卡片：surface 填充 + 1px 描边 + 16 圆角（可覆盖用于特色卡）。
///
/// 用 [Material] 承载背景与描边（而不是带背景色的 [Container]），
/// 让卡片内 [InkWell] 的水波纹可见，也避免
/// 「ListTile background color or ink splashes may be invisible」断言。
class SettingsCard extends StatelessWidget {
  /// 卡片内容。
  final Widget child;

  /// 卡片内边距（默认 0：由内部设置行自行管理 14×12）。
  final EdgeInsetsGeometry padding;

  /// 卡片圆角（默认 [NarrChatTheme.cardRadius]）。
  final double radius;

  /// 卡片填充色（默认当前主题 surface）。
  final Color? color;

  /// 卡片描边色（默认当前主题 divider）。
  final Color? borderColor;

  /// 裁剪方式（默认抗锯齿裁剪，保证圆角外的水波纹/内容不外溢）。
  final Clip clipBehavior;

  const SettingsCard({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.radius = NarrChatTheme.cardRadius,
    this.color,
    this.borderColor,
    this.clipBehavior = Clip.antiAlias,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    final content = padding == EdgeInsets.zero
        ? child
        : Padding(padding: padding, child: child);
    return Material(
      color: color ?? Theme.of(context).colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
        side: BorderSide(color: borderColor ?? colors.divider),
      ),
      clipBehavior: clipBehavior,
      child: content,
    );
  }
}

/// 卡片内分区头：图标块 + 标题 + 副标题（+ 右侧自定义内容）。
///
/// 与 [SettingsSection] 共用同一套头部视觉，只是本组件由调用方放进卡片里
/// （云同步 / 字体设置的特色卡片保留「头部在卡内」的布局）。
class SettingsCardHeader extends StatelessWidget {
  /// 左侧图标（可选；有图标时渲染品牌浅底图标块）。
  final IconData? icon;

  /// 分区标题。
  final String title;

  /// 分区副标题（可选）。
  final String? subtitle;

  /// 右侧自定义内容（可选）。
  final Widget? trailing;

  const SettingsCardHeader({
    super.key,
    this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (icon != null) ...[
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: NarrChatTheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(icon, size: 18, color: NarrChatTheme.primary),
          ),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: colors.textPrimary,
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle!,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.4,
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: 12),
          trailing!,
        ],
      ],
    );
  }
}

/// 设置分区：分区头（卡片外）+ 内容。卡片由调用方按需使用 [SettingsCard]。
class SettingsSection extends StatelessWidget {
  /// 分区图标（可选）。
  final IconData? icon;

  /// 分区标题。
  final String title;

  /// 分区副标题（可选）。
  final String? subtitle;

  /// 头部右侧自定义内容（可选）。
  final Widget? trailing;

  /// 分区内容（通常是 [SettingsCard] 或一组卡片）。
  final Widget child;

  /// 与下一个分区之间的间距（默认 20）。
  final double bottomGap;

  const SettingsSection({
    super.key,
    this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    required this.child,
    this.bottomGap = 20,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsCardHeader(
          icon: icon,
          title: title,
          subtitle: subtitle,
          trailing: trailing,
        ),
        const SizedBox(height: 12),
        child,
        SizedBox(height: bottomGap),
      ],
    );
  }
}

/// 可展开卡片：头部整行可点，展开/收起有尺寸动画，箭头旋转。
///
/// 用于 API 设置的「平台 → 模型」层级：
/// - 平台卡传 [radius] = [NarrChatTheme.cardRadius]；
/// - 卡片内部嵌套的模型卡用默认 [NarrChatTheme.controlRadius]，
///   并通过 [showGuideLine] 保留左侧竖线层级。
class SettingsExpandableCard extends StatefulWidget {
  /// 头部内容（通常为标题行 + 状态标注）。
  final Widget title;

  /// 展开后显示的内容。
  final Widget child;

  /// 是否默认展开。
  final bool initiallyExpanded;

  /// 卡片圆角（默认 [NarrChatTheme.controlRadius]）。
  final double radius;

  /// 展开头部 InkWell 的 key（测试 / 自动化定位用）。
  final Key? headerKey;

  /// 是否在展开内容左侧绘制层级竖线。
  final bool showGuideLine;

  const SettingsExpandableCard({
    super.key,
    required this.title,
    required this.child,
    this.initiallyExpanded = false,
    this.radius = NarrChatTheme.controlRadius,
    this.headerKey,
    this.showGuideLine = false,
  });

  @override
  State<SettingsExpandableCard> createState() => _SettingsExpandableCardState();
}

class _SettingsExpandableCardState extends State<SettingsExpandableCard> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    final outlineVariant = Theme.of(context).colorScheme.outlineVariant;
    final duration = SettingsMotion.of(context, NarrChatTheme.motionNormal);
    return Material(
      color: Theme.of(context).colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(widget.radius),
        side: BorderSide(color: colors.divider),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            key: widget.headerKey,
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(widget.radius),
            hoverColor: NarrChatTheme.primary.withValues(alpha: 0.05),
            splashColor: NarrChatTheme.primary.withValues(alpha: 0.08),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
              child: Row(
                children: [
                  Expanded(child: widget.title),
                  const SizedBox(width: 8),
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0,
                    duration: duration,
                    curve: NarrChatTheme.motionCurve,
                    child: Icon(
                      Icons.expand_more,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: duration,
            curve: NarrChatTheme.motionCurve,
            alignment: Alignment.topCenter,
            child: _expanded
                ? Container(
                    width: double.infinity,
                    decoration: widget.showGuideLine
                        ? BoxDecoration(
                            border: Border(
                              left: BorderSide(
                                color: outlineVariant,
                                width: 2,
                              ),
                            ),
                          )
                        : null,
                    padding: const EdgeInsets.fromLTRB(16, 4, 14, 14),
                    child: widget.child,
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}
