import 'package:flutter/material.dart';

/// 书籍设置页「退出但还有未保存改动」的处理方式。
enum BookSettingsExitChoice {
  /// 保存全部草稿后退出设置页。
  saveAndExit,

  /// 留在设置页继续编辑（取消退出）。
  continueEditing,

  /// 丢弃草稿直接退出。
  discard,
}

/// 书籍设置页的退出确认弹窗。
///
/// 返回 null 表示弹窗被系统返回键关闭（只关弹窗、不退出页面），
/// 调用方应把它当作「继续编辑」处理。
Future<BookSettingsExitChoice?> showBookSettingsExitDialog(
  BuildContext context,
) {
  return showDialog<BookSettingsExitChoice>(
    context: context,
    // 只能通过三个按钮明确选择；点遮罩不关闭，避免误触丢草稿。
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      key: const ValueKey('book_settings_exit_dialog'),
      title: const Text('有设置未保存'),
      content: const Text(
        '当前书籍设置中有更改尚未保存。\n'
        '可以保存后退出，也可以丢弃这些更改直接退出。',
      ),
      actions: [
        TextButton(
          key: const ValueKey('book_settings_exit_continue'),
          onPressed: () =>
              Navigator.of(ctx).pop(BookSettingsExitChoice.continueEditing),
          child: const Text('继续编辑'),
        ),
        TextButton(
          key: const ValueKey('book_settings_exit_discard'),
          onPressed: () =>
              Navigator.of(ctx).pop(BookSettingsExitChoice.discard),
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(ctx).colorScheme.error,
          ),
          child: const Text('仍然退出'),
        ),
        FilledButton(
          key: const ValueKey('book_settings_exit_save'),
          onPressed: () =>
              Navigator.of(ctx).pop(BookSettingsExitChoice.saveAndExit),
          child: const Text('保存并退出设置'),
        ),
      ],
    ),
  );
}
