import 'package:flutter/widgets.dart';

/// 把 [insert] 写入输入框当前值 [value] 的落点规则（「推荐下一步」双击选项写入
/// 主输入框用；纯函数，便于单测）。
///
/// - **输入为空**：直接置入；
/// - **有文本但无光标**（选择区无效，如程序化赋值 / 草稿恢复后从未聚焦）：
///   追加到已输入文本末尾；
/// - **有文本且有光标**：在光标所在处插入；存在选中区时替换选中内容。
///
/// 返回值的光标统一落在插入内容之后；组合态（composing）清空，避免把插入文本
/// 并进输入法未上屏内容。**本函数不改动焦点、不触发发送**——聚焦由调用方决定。
TextEditingValue insertTextIntoValue(TextEditingValue value, String insert) {
  final text = value.text;
  final selection = value.selection;
  final hasCaret = selection.isValid && selection.start >= 0;

  if (text.isEmpty || !hasCaret) {
    // 空输入 = 置入；无光标 = 追加到末尾（含选择区无效的旧值）。
    final inserted = text + insert;
    return TextEditingValue(
      text: inserted,
      selection: TextSelection.collapsed(offset: inserted.length),
    );
  }

  // 光标（或选中区）可能来自更早的文本状态：夹到当前文本范围内再落点。
  final start = selection.start.clamp(0, text.length);
  final end = selection.end.clamp(start, text.length);
  final inserted = text.replaceRange(start, end, insert);
  return TextEditingValue(
    text: inserted,
    selection: TextSelection.collapsed(offset: start + insert.length),
  );
}
