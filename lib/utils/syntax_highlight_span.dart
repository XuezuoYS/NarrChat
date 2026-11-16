/// 语法高亮区间的最小契约：`[start, end)` 区间（含头不含尾）+ 词法单元类型。
///
/// 只描述「位置 + 词法单元」，不涉及颜色 / 字形 / Flutter，便于纯数据测试。
/// 各语言的区间类型（如 `MarkdownHighlightSpan` / `JsonHighlightSpan`）实现本接口
/// 后，就能共用同一套「区间 → TextSpan」的组装逻辑（见
/// `widgets/syntax_highlight.dart`），编辑器与预览的边界行为因此天然一致。
abstract interface class SyntaxHighlightSpan<T> {
  /// 区间起点（含）。
  int get start;

  /// 区间终点（不含）。
  int get end;

  /// 本区间对应的词法单元。
  T get token;
}
