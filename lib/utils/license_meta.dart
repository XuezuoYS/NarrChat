/// 从许可证正文提取「许可证名称」次级标题的轻量工具。
library;

/// 由许可证正文生成次级标题：取**首个非空行**（去除首尾空白）的整行内容。
///
/// 任何情况下都仅匹配第一行有字的部分：不向下扫描后续行、不拼接作者，
/// 避免选到正文中的句子（如版权行、条款说明等）；无任何非空行时返回空字符串。
String licenseSubtitle(String text) {
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isNotEmpty) return line;
  }
  return '';
}
