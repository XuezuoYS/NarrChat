import 'package:flutter/material.dart';

/// 类型徽标：带 12% 透明底色的圆角小标签（如「预置」/「自定义」）。
class TypeBadge extends StatelessWidget {
  final String text;
  final Color color;

  const TypeBadge({super.key, required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
