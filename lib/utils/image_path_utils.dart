/// 图片相对路径（`img/<哈希>.<扩展名>`，相对 `user_data/`）的归一化工具。
///
/// 同一份路径会出现在好几处（书库 `book_meta.book_cover_img`、列表缓存
/// `library_cache.book_index.book_cover_img`、`Book` 模型），统一由这里收敛，
/// 避免各写一遍导致「空串」与「NULL」语义漂移：两者都表示**没有图片**。
library;

/// 归一化图片路径：非字符串 / 纯空白一律视为「没有图片」（`null`）。
///
/// 只做 trim 与空值收敛，不校验目录前缀——非法路径（逃逸出 `img/`）的容错
/// 在真正读文件那一层（`ImageStore` 会抛 `ImageFormatException`，界面显示占位）。
String? cleanImagePath(Object? raw) {
  if (raw is! String) return null;
  final trimmed = raw.trim();
  return trimmed.isEmpty ? null : trimmed;
}
