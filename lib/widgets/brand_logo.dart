import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 品牌 Logo：品牌渐变圆角方块 + 星芒图标，可选附带「NarrChat」文字。
///
/// 统一 AppBar 标题、聊天空状态、关于面板、AI 头像等处的品牌标识，
/// 避免各处重复实现「渐变方块 + auto_awesome 图标」。
class BrandLogo extends StatelessWidget {
  /// 方块边长。
  final double size;

  /// 图标尺寸。
  final double iconSize;

  /// 方块圆角（默认按边长比例的 8/28 ≈ 0.2857，与原有各处视觉一致）。
  final double radius;

  /// 附带文字（如「NarrChat」）；为 null 时仅显示 Logo 方块。
  final String? title;

  /// 文字字号（仅 [title] 非空时生效，默认 17）。
  final double titleSize;

  const BrandLogo({
    super.key,
    this.size = 28,
    this.iconSize = 16,
    double? radius,
    this.title,
    this.titleSize = 17,
  }) : radius = radius ?? size * 8 / 28;

  @override
  Widget build(BuildContext context) {
    final logo = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: NarrChatTheme.brandGradient,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Icon(Icons.auto_awesome, size: iconSize, color: Colors.white),
    );
    final t = title;
    if (t == null) return logo;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        logo,
        const SizedBox(width: 10),
        Text(
          t,
          style: TextStyle(
            fontSize: titleSize,
            fontWeight: FontWeight.w700,
            color: context.narrColors.textPrimary,
          ),
        ),
      ],
    );
  }
}
