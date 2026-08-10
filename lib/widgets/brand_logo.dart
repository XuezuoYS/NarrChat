import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 品牌 Logo：应用图标的圆角图像（assets/app_icon_rounded.png），可选附带「NarrChat」文字。
///
/// 统一 AppBar 标题、聊天空状态、关于面板、AI 头像等处的品牌标识，
/// 与应用图标（app_icon.ico）视觉一致。
class BrandLogo extends StatelessWidget {
  /// 图像边长。
  final double size;

  /// 附带文字（如「NarrChat」）；为 null 时仅显示 Logo 图像。
  final String? title;

  /// 文字字号（仅 [title] 非空时生效，默认 17）。
  final double titleSize;

  const BrandLogo({
    super.key,
    this.size = 28,
    this.title,
    this.titleSize = 17,
  });

  @override
  Widget build(BuildContext context) {
    final logo = Image.asset(
      'assets/app_icon_rounded.png',
      width: size,
      height: size,
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
