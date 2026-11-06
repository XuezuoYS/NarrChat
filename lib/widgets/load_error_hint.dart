import 'package:flutter/material.dart';

import 'app_empty_hint.dart';

/// 调试页各阅读器复用的加载失败提示：说明原因 + 重试按钮。
class LoadErrorHint extends StatelessWidget {
  const LoadErrorHint({
    super.key,
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppEmptyHint(icon: Icons.error_outline, text: message),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}
