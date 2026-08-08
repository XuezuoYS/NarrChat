import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 「未来开发」占位面板（用于尚未实现的功能模块）。
class ComingSoonPanel extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;

  const ComingSoonPanel({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
        decoration: BoxDecoration(
          color: const Color(0xFFF7F7F8),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: NarrChatTheme.divider),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: NarrChatTheme.textSecondary),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: NarrChatTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '未来开发',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              description,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 12,
                color: NarrChatTheme.textSecondary,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
