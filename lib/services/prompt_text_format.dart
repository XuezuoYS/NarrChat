/// 提示词拼装的**三个纯函数**（不依赖 Flutter、不依赖任何模型）。
///
/// `prompt_v3_sections` 与 `prompt_v3_context` 都要把用户填写的字段塞进模板，
/// 归一化口径必须完全一致，所以抽在这里各取一份用，不在两处各写一遍：
///
/// - [blockText]：**多行字段**（书籍设定 / 世界书 / 文笔 / 类别格式 / Mod 文案 /
///   前后置词）只去首尾空白、保留内部换行——折叠换行会把用户写的结构压成一行；
/// - [lineText]：**单行字段**（书籍名 / 分类 / 角色层级 / 时间）折叠内部换行，
///   否则会破坏 `- 字段：值` 的结构；
/// - [joinParagraphs]：多段文本按「跳过空段、段间一个空行」拼起来。
library;

/// 多行字段：统一换行符 + 去首尾空白，**保留内部换行**。
String blockText(String? raw) =>
    (raw ?? '').replaceAll('\r\n', '\n').trim();

/// 单行字段：在多行归一化之后再折叠内部换行。
String lineText(String? raw) =>
    blockText(raw).replaceAll(RegExp(r'\s*\n\s*'), ' ');

/// 多段文本拼接：跳过空段、段间一个空行、各段保留自身换行。
String joinParagraphs(List<String?> parts) => parts
    .map(blockText)
    .where((part) => part.isNotEmpty)
    .join('\n\n');

/// 去掉文本末尾的空行（拼装时用 `writeln` 很容易多带一个换行）。
String trimRightText(String raw) {
  final lines = raw.split('\n');
  while (lines.isNotEmpty && lines.last.trim().isEmpty) {
    lines.removeLast();
  }
  return lines.join('\n');
}
