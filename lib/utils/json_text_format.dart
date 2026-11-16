import 'dart:convert';

/// 把 JSON 文本格式化为缩进后的展示文本；解析失败返回 null。
///
/// 只做「解析 → 重新编码」这一件事，因此：
/// - 压缩成一行的 JSON 会展开成多行缩进结构；
/// - 本来就格式良好的 JSON 也会被规范化（缩进统一、字段顺序保留原顺序）；
/// - 空文本、半截 JSON、根本不是 JSON 的文本一律返回 null，由调用方决定
///   回退策略（如直接展示原文）。
///
/// 缩进口径与项目里既有的 `JsonEncoder.withIndent('  ')` 保持一致。
String? tryPrettyPrintJson(String raw, {int indent = 2}) {
  final source = raw.trim();
  if (source.isEmpty) return null;
  try {
    return JsonEncoder.withIndent(' ' * indent).convert(jsonDecode(source));
  } on FormatException {
    return null;
  }
}
