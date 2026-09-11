import 'package:flutter/material.dart';

/// 提示词输入框的灰色小字提示：`请尽量避免使用 #/##`。
///
/// 背景：正文契约只允许固定的几个二级标题（`## 剧情演绎` 等），用户文案里的
/// `#`/`##` 会与这些区块标题混淆，也会破坏提示词自身的结构（层级倒挂 / 被当成
/// 标题解析）。该约束**不写进提示词正文**（见 `prompt_formats.dart` /
/// `prompt_sections.dart` 的文案约定注释），只在这里与源码注释中体现。
///
/// 使用处：书籍设置各页（书籍概览 / 角色类别 / 基础设定 / 世界书 / 文笔参考 /
/// Mod 管理）与 Mod 编辑对话框（[ModDetailDialog]）。
class PromptInputHint extends StatelessWidget {
  /// 提示文案（多处共用，改一处同步生效）。
  static const String text = '请尽量避免使用 #/##';

  const PromptInputHint({super.key});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        color: Theme.of(context).colorScheme.outline,
      ),
    );
  }
}
