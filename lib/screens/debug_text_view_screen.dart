import 'dart:convert';

import 'package:flutter/material.dart';

import '../services/debug_file_service.dart';
import '../theme/app_theme.dart';
import '../widgets/island_bar.dart';
import '../widgets/load_error_hint.dart';
import '../widgets/markdown_preview.dart';
import '../widgets/narr_chat_app_bar.dart';

/// 「JSON / 文本」阅读器：只读显示一个文件的内容。
///
/// [formatJson] 为 true 时尝试按 2 空格缩进格式化；解析失败不阻止查看，
/// 直接显示原文并在顶部说明失败原因。
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

    final colors = context.narrColors;
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
            child: SelectableTextArea(
              child: Text(
                content.isEmpty ? '（空文件）' : content,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  fontFamily: 'monospace',
                  color: colors.textPrimary,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
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
