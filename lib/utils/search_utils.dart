import '../models/mod.dart';

/// 将查询文本按空白（空格、换行等）拆分为多个小写关键词。
///
/// 用于「空格区分」的多关键词模糊搜索：`"AI 写作"` 会拆为 `['ai', '写作']`；
/// 纯空白或空串返回空列表。
List<String> splitKeywords(String query) {
  return query
      .trim()
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((k) => k.isNotEmpty)
      .toList();
}

/// 多关键词匹配：关键词之间为 AND 关系（全部命中才通过），
/// 每个关键词在任一给定字段中模糊命中（子串、大小写不敏感）即算通过。
bool matchesKeywords(List<String> keywords, List<String> fields) {
  if (keywords.isEmpty) return true;
  for (final keyword in keywords) {
    final k = keyword.toLowerCase();
    var hit = false;
    for (final field in fields) {
      if (field.toLowerCase().contains(k)) {
        hit = true;
        break;
      }
    }
    if (!hit) return false;
  }
  return true;
}

/// 判断 Mod 是否命中关键词（搜索范围为名称与简介）。
bool modMatchesKeywords(List<String> keywords, Mod? mod) {
  if (mod == null) return false;
  return matchesKeywords(keywords, [mod.name, mod.description]);
}
