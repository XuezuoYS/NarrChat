import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 本轮调试信息对话框。
///
/// 展示实际发给 AI 的**完整请求 JSON**（含 system / 历史 user/assistant / 当前 user
/// 的 messages 数组与全部参数），以及 AI 返回的原始文本（未经过 `##` 标题解析）。
/// 仅保留最新一轮的调试数据，用于排查问题。
class DebugPromptDialog extends StatelessWidget {
  final String requestBody;
  final String rawResponse;

  const DebugPromptDialog({
    super.key,
    required this.requestBody,
    required this.rawResponse,
  });

  static Future<void> show(
    BuildContext context, {
    required String requestBody,
    required String rawResponse,
  }) {
    return showDialog<void>(
      context: context,
      builder: (_) => DebugPromptDialog(
        requestBody: requestBody,
        rawResponse: rawResponse,
      ),
    );
  }

  /// 将请求体 JSON 格式化（缩进 2 空格）；解析失败时原样返回。
  static String _prettyJson(String raw) {
    if (raw.trim().isEmpty) return raw;
    try {
      final decoded = jsonDecode(raw);
      return const JsonEncoder.withIndent('  ').convert(decoded);
    } catch (_) {
      return raw;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.bug_report_outlined,
              size: 22, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          const Text('本轮调试信息'),
        ],
      ),
      content: SizedBox(
        width: 720,
        height: 540,
        child: DefaultTabController(
          length: 2,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const TabBar(
                tabs: [
                  Tab(text: '请求 JSON'),
                  Tab(text: 'AI 原始返回'),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: TabBarView(
                  children: [
                    _DebugSection(
                      title: '实际发出的请求 JSON（含完整 messages 历史与参数）',
                      text: _prettyJson(requestBody),
                      hint: 'messages 数组：system → 历史 user/assistant → 当前 user。',
                    ),
                    _DebugSection(
                      title: 'AI 原始返回（未解析）',
                      text: rawResponse,
                      hint: 'AI 返回的完整原文，未经 ## 标题解析。',
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

/// 单个调试区块：标题 + 复制按钮 + 可滚动原文。
class _DebugSection extends StatelessWidget {
  final String title;
  final String text;
  final String? hint;

  const _DebugSection({
    required this.title,
    required this.text,
    this.hint,
  });

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已复制'),
          duration: Duration(seconds: 1),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.code, size: 16, color: theme.colorScheme.outline),
            const SizedBox(width: 6),
            Text(
              title,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: () => _copy(context),
              icon: const Icon(Icons.copy_outlined, size: 15),
              label: const Text('复制'),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                textStyle: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
        if (hint != null) ...[
          const SizedBox(height: 2),
          Text(
            hint!,
            style: TextStyle(fontSize: 11, color: theme.colorScheme.outline),
          ),
        ],
        const SizedBox(height: 6),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: SelectableText(
                text.isEmpty ? '（无内容）' : text,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  height: 1.6,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
