import 'package:flutter/material.dart';

import '../models/round.dart';

/// 删除轮次选项。
enum DeleteRoundChoice { single, all }

/// “删除本轮”对话框：提供“仅删除本轮”与“删除本轮及后续所有轮次”两个选项。
Future<DeleteRoundChoice?> showDeleteRoundDialog(
  BuildContext context,
  Round round,
) {
  return showDialog<DeleteRoundChoice>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: Text('删除本轮（第 ${round.roundIndex} 轮）'),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.of(ctx).pop(DeleteRoundChoice.single),
          child: const Row(
            children: [
              Icon(Icons.delete_outline, size: 22),
              SizedBox(width: 12),
              Expanded(child: Text('仅删除本轮')),
            ],
          ),
        ),
        SimpleDialogOption(
          onPressed: () => Navigator.of(ctx).pop(DeleteRoundChoice.all),
          child: const Row(
            children: [
              Icon(Icons.delete_sweep_outlined, size: 22),
              SizedBox(width: 12),
              Expanded(child: Text('删除本轮及后续所有轮次')),
            ],
          ),
        ),
      ],
    ),
  );
}

/// 「删除此代」确认对话框（单代删除）。
///
/// 体验与「删除本轮」一致：同一个气泡扩展菜单入口 + 二次确认。
/// 文案如实交代落点（自动切换到第几代 / 本轮剩余几代）与代价
/// （以该代为基础生成的后续轮次内容一并移除且无法恢复）。
Future<bool> showDeleteGenerationConfirmDialog(
  BuildContext context, {
  required int roundIndex,
  required int currentSerial,
  required int fallbackSerial,
  required int remaining,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('删除此代'),
      content: Text(
        '将删除第 $roundIndex 轮的第 $currentSerial 代，'
        '并自动切换到第 $fallbackSerial 代（本轮剩余 $remaining 代）。\n'
        '以该代为基础生成的后续轮次内容会一并移除，且无法恢复。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(ctx).colorScheme.error,
          ),
          child: const Text('删除'),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// 「刷新本轮」二次确认对话框（**唯一入口的确认框**）。
///
/// 「刷新本轮」= 以该轮的用户输入在**同轮号**重新请求 AI（新增一代，旧代留在
/// 版本树可切回；生成期间界面按该轮截断展示）。气泡底部按钮、气泡右键菜单、
/// 失败条目按钮/菜单都走这一处
/// 文案：**不提示「会丢失后续内容」**——旧版本与后续轮次都保留在版本树里，
/// 切换代次即可取回，喊「丢失」只会吓人。
Future<bool> showRefreshRoundConfirmDialog(
  BuildContext context,
  int roundIndex,
) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('刷新本轮'),
      content: Text('将重新生成第 $roundIndex 轮，并以该轮的用户输入重新请求 AI。是否继续？'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('继续'),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// 删除书籍确认对话框。
///
/// 第一次确认说明影响范围：本机清空，云端只留最新一份备份（回收站可还原）。
Future<bool> showDeleteBookConfirmDialog(
  BuildContext context,
  String title,
) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('删除书籍'),
      content: Text(
        '确定删除书籍「$title」吗？本机数据（含全部轮次与设定）会被清除；'
        '云端备份只保留最近一次同步的版本，可在「云同步 → 已删除」中还原或彻底删除。'
        '从未同步到云端的书删除后无法还原。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(ctx).colorScheme.error,
          ),
          child: const Text('删除'),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// 删除书籍的**最后一道确认**：必须逐字输入当前书名才能正式删除。
///
/// 交互参考 GitHub 删库：确认按钮在输入匹配前保持禁用；另提供「一键填入」
/// 方便长书名 / 中文输入，但用户仍要主动点一次「永久删除」。
///
/// 书名按**原样**比较（不包书名号、不做 trim）：这正是这道确认的意义所在。
Future<bool> showDeleteBookFinalConfirmDialog(
  BuildContext context,
  String title,
) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (_) => _DeleteBookFinalConfirmDialog(title: title),
  );
  return result ?? false;
}

class _DeleteBookFinalConfirmDialog extends StatefulWidget {
  const _DeleteBookFinalConfirmDialog({required this.title});

  /// 当前书名（不带书名号）。
  final String title;

  @override
  State<_DeleteBookFinalConfirmDialog> createState() =>
      _DeleteBookFinalConfirmDialogState();
}

class _DeleteBookFinalConfirmDialogState
    extends State<_DeleteBookFinalConfirmDialog> {
  final TextEditingController _controller = TextEditingController();

  /// 空书名（脏数据兜底）时退化成输入「删除」，避免永远无法删掉。
  late final String _expected;

  bool get _matches => _controller.text == _expected;

  @override
  void initState() {
    super.initState();
    _expected = widget.title.isEmpty ? '删除' : widget.title;
    // 每次输入都刷新确认按钮的禁用状态。
    _controller.addListener(_onInputChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onInputChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onInputChanged() => setState(() {});

  void _fillTitle() {
    _controller.value = TextEditingValue(
      text: _expected,
      selection: TextSelection.collapsed(offset: _expected.length),
    );
  }

  void _submitIfMatched() {
    if (_matches) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: colors.error, size: 22),
          const SizedBox(width: 8),
          const Expanded(child: Text('最后确认')),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '此操作会清空本机数据，且本机数据删除后不可恢复。\n'
              '云端备份只保留最近一次同步的版本（从未同步过则没有备份）；'
              '需要时可在「云同步 → 已删除」中还原。',
              style: TextStyle(color: colors.error, height: 1.4),
            ),
            const SizedBox(height: 14),
            const Text('如需继续，请逐字输入下面的书名（不带书名号）：'),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: colors.errorContainer.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                _expected,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: colors.onErrorContainer,
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              autofocus: true,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submitIfMatched(),
              decoration: const InputDecoration(
                hintText: '输入书名',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _fillTitle,
                icon: const Icon(Icons.keyboard_alt_outlined, size: 18),
                label: const Text('一键填入'),
              ),
            ),
            Text(
              '需与书名完全一致（空格、标点都算）。',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).textTheme.bodySmall?.color,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _matches ? () => Navigator.of(context).pop(true) : null,
          style: FilledButton.styleFrom(backgroundColor: colors.error),
          child: const Text('永久删除'),
        ),
      ],
    );
  }
}
