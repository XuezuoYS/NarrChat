import 'dart:convert';

import 'package:flutter/material.dart';

import '../services/debug_file_service.dart';
import '../theme/app_theme.dart';
import '../widgets/island_bar.dart';
import '../widgets/json_view.dart';
import '../widgets/load_error_hint.dart';
import '../widgets/markdown_preview.dart';
import '../widgets/narr_chat_app_bar.dart';

/// 「JSON / 文本」阅读器：只读显示一个文件的内容。
///
/// [formatJson] 为 true 时，先尝试按 2 空格缩进格式化（解析失败不阻止查看，
/// 直接显示原文并在顶部说明失败原因），正文交给 [JsonView] 做 JSON 语法着色；
/// 其它文本文件保持纯文本展示（不做任何语法着色）。
class DebugTextViewScreen extends StatefulWidget {
  const DebugTextViewScreen({
    super.key,
    required this.fileService,
    required this.entry,
    this.formatJson = false,
  });

  final DebugFileService fileService;
  final DebugFileEntry entry;
  final bool formatJson;

  @override
  State<DebugTextViewScreen> createState() => _DebugTextViewScreenState();
}

class _DebugTextViewScreenState extends State<DebugTextViewScreen> {
  String? _content;
  String? _error;
  String? _jsonError;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _jsonError = null;
    });
    try {
      final raw = await widget.fileService.readTextFile(
        widget.entry.relativePath,
      );
      var content = raw;
      String? jsonError;
      if (widget.formatJson) {
        // 这里刻意自己格式化（而不是用 `tryPrettyPrintJson`）：要把解析失败的
        // **具体原因**展示给用户，而 JsonView 的格式化是静默回退的。
        try {
          content = const JsonEncoder.withIndent('  ').convert(jsonDecode(raw));
        } catch (error) {
          jsonError = 'JSON 解析失败：$error';
        }
      }
      if (!mounted) return;
      setState(() {
        _content = content;
        _jsonError = jsonError;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    return IslandAwareScaffold(
      backgroundColor: colors.background,
      appBarBuilder: (context, extraRow) => NarrChatAppBar(
        extraRowHeight: extraRow,
        title: widget.entry.name,
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh, size: 20),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return LoadErrorHint(message: '文件读取失败：$_error', onRetry: _load);
    }

    final content = _content ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PathLine(text: widget.entry.relativePath),
        if (_jsonError != null) _JsonErrorBanner(message: _jsonError!),
        const Divider(height: 1),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: _buildContent(context, content),
          ),
        ),
      ],
    );
  }

  /// 正文渲染：空文件给提示；JSON 文件走 [JsonView]（语法着色，文本已在本页
  /// 格式化好，故关掉它自己的再格式化）；其它文件保持纯文本。
  Widget _buildContent(BuildContext context, String content) {
    final colors = context.narrColors;
    if (content.isEmpty) {
      return SelectableTextArea(
        child: Text('（空文件）', style: _monoStyle(colors)),
      );
    }
    if (widget.formatJson) {
      return JsonView(data: content, prettyPrint: false);
    }
    return SelectableTextArea(child: Text(content, style: _monoStyle(colors)));
  }

  /// 纯文本展示的等宽样式（与 [JsonView] 默认样式一致，切换时字号不跳）。
  TextStyle _monoStyle(NarrChatColors colors) => TextStyle(
        fontSize: 12,
        height: 1.5,
        fontFamily: 'monospace',
        color: colors.textPrimary,
      );
}

class _PathLine extends StatelessWidget {
  const _PathLine({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11, color: context.narrColors.textSecondary),
      ),
    );
  }
}

/// JSON 解析失败提示：只说明原因，正文仍显示原文。
class _JsonErrorBanner extends StatelessWidget {
  const _JsonErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        message,
        style: TextStyle(fontSize: 12, color: scheme.onErrorContainer),
      ),
    );
  }
}
