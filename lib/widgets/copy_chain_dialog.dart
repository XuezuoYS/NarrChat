import 'package:flutter/material.dart';

import '../models/branch_copy.dart';
import '../models/round.dart';
import 'markdown_preview.dart';

/// 拷贝完成后的选择。
enum CopyChainChoice {
  /// 切到新分支并定位到被拷贝的那一轮。
  jump,

  /// 留在当前分支，新分支保留在分支列表里。
  stay,
}

/// 一次拷贝的结果 + 用户选择。
class CopyChainOutcome {
  const CopyChainOutcome({required this.choice, required this.result});

  final CopyChainChoice choice;
  final BranchCopyResult result;
}

/// 执行拷贝的入口。
///
/// 由对话页适配 `RoundProvider`（把 null 结果转成异常），对话框本身不依赖
/// Provider —— 这样对话框可以在测试里注入可控的 Completer，逐帧断言三种状态。
typedef CopyChainRunner = Future<BranchCopyResult> Function(
  void Function(int done, int total)? onProgress,
);

/// 弹出「从此代拷贝链至新的分支」对话框。
///
/// - 打开即显示「正在拷贝中」，拷贝在**首帧之后**启动（保证拷贝中状态可见）；
/// - 成功后同一对话框切换为完成态，提供「点击跳转 / 留在当前分支」；
/// - 失败显示可选中原因并可关闭；
/// - 拷贝中禁止点遮罩 / 返回键关闭，避免把界面带走而拷贝还在后台写库。
Future<CopyChainOutcome?> showCopyChainDialog(
  BuildContext context, {
  required Round round,
  required CopyChainRunner copy,
}) {
  return showDialog<CopyChainOutcome>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _CopyChainDialog(round: round, copy: copy),
  );
}

class _CopyChainDialog extends StatefulWidget {
  const _CopyChainDialog({required this.round, required this.copy});

  final Round round;
  final CopyChainRunner copy;

  @override
  State<_CopyChainDialog> createState() => _CopyChainDialogState();
}

class _CopyChainDialogState extends State<_CopyChainDialog> {
  bool _copying = true;
  int _done = 0;
  int _total = 0;
  BranchCopyResult? _result;
  String? _error;

  @override
  void initState() {
    super.initState();
    // 放首帧之后：拷贝极快时也不会让对话框一出现就已经完成。
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    if (!mounted) return;
    try {
      final result = await widget.copy(_onProgress);
      if (!mounted) return;
      setState(() {
        _copying = false;
        _result = result;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _copying = false;
        _error = _describeError(error);
      });
    }
  }

  void _onProgress(int done, int total) {
    if (!mounted || !_copying) return;
    setState(() {
      _done = done;
      _total = total;
    });
  }

  /// `StateError` 只取正文，避免界面上出现「Bad state:」；其它异常原样展示。
  ///
  /// 兜底再剥一次前缀：Provider 的 `error` 可能已经被 `toString()` 过，
  /// 外面再包一层 `StateError` 时文本里会残留 Dart 的异常类名。
  static String _describeError(Object error) {
    final text = error is StateError ? error.message : error.toString();
    return text.startsWith('Bad state: ')
        ? text.substring('Bad state: '.length)
        : text;
  }

  String get _title {
    if (_copying) return '正在拷贝中';
    return _result == null ? '拷贝失败' : '拷贝完成';
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_copying,
      child: AlertDialog(
        key: const ValueKey('copy-chain-dialog'),
        title: Text(_title),
        content: SizedBox(
          width: 360,
          child: _copying ? _buildCopying(context) : _buildResult(context),
        ),
        actions: _buildActions(context),
      ),
    );
  }

  Widget _buildCopying(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // 确定进度（未知总数时停在 0）：不使用无限动画，对话框打开时界面保持安静。
    final progress = _total > 0 ? _done / _total : 0.0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '正在拷贝第 ${widget.round.roundIndex} 轮'
          '第 ${widget.round.roundSerialNum} 代及其全部子代…',
          style: TextStyle(
            fontSize: 13,
            height: 1.5,
            color: colors.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 14),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            key: const ValueKey('copy-chain-progress'),
            value: progress,
            minHeight: 6,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _total > 0 ? '已拷贝 $_done / $_total 代' : '正在准备拷贝…',
          style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _buildResult(BuildContext context) {
    final result = _result;
    final colors = Theme.of(context).colorScheme;
    if (result == null) {
      return ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 200),
        child: SingleChildScrollView(
          child: SelectableTextArea(
            child: Text(
              _error ?? '拷贝失败',
              key: const ValueKey('copy-chain-error'),
              style: TextStyle(
                fontSize: 12.5,
                height: 1.5,
                color: colors.error,
              ),
            ),
          ),
        ),
      );
    }
    final range = result.firstRoundIndex == result.lastRoundIndex
        ? '第 ${result.firstRoundIndex} 轮'
        : '第 ${result.firstRoundIndex}–${result.lastRoundIndex} 轮';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.check_circle_outline, size: 18, color: colors.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '已创建分支「${result.branchName}」',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '共拷贝 ${result.generationCount} 代（$range）。',
          style: TextStyle(
            fontSize: 12.5,
            height: 1.5,
            color: colors.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  List<Widget> _buildActions(BuildContext context) {
    if (_copying) return const [];
    final result = _result;
    if (result == null) {
      return [
        FilledButton(
          key: const ValueKey('copy-chain-close'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ];
    }
    return [
      TextButton(
        key: const ValueKey('copy-chain-stay'),
        onPressed: () => Navigator.of(context).pop(
          CopyChainOutcome(choice: CopyChainChoice.stay, result: result),
        ),
        child: const Text('留在当前分支'),
      ),
      FilledButton(
        key: const ValueKey('copy-chain-jump'),
        onPressed: () => Navigator.of(context).pop(
          CopyChainOutcome(choice: CopyChainChoice.jump, result: result),
        ),
        child: const Text('点击跳转'),
      ),
    ];
  }
}
