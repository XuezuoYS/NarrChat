import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 通用空态提示：圆角描边容器 + 图标 + 居中文字。
///
/// 用于各面板（Mod / 世界书等）无数据时的占位提示，统一样式。
class AppEmptyHint extends StatelessWidget {
  final IconData icon;
  final String text;

  const AppEmptyHint({super.key, required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.divider),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 40,
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
          const SizedBox(height: 8),
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.textSecondary, height: 1.5),
          ),
        ],
      ),
    );
  }
}
