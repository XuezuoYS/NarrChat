/// 首页默认封面用的内置插画（2:3 资源）。
///
/// 只有书籍没有自定义封面时才会用到；具体挑哪一张由
/// `DefaultCoverStyle`（固定插画 / 插画适配）决定。
enum CoverIllustration {
  /// 插画 1：通用插画，也是「插画适配」两方都不沾时的兜底。
  illustration1('assets/girl1.png'),

  /// 插画 2：偏古风题材。
  illustration2('assets/girl2.png'),

  /// 插画 3：偏现代题材。
  illustration3('assets/girl3.png');

  const CoverIllustration(this.asset);

  /// 资源路径（已在 `pubspec.yaml` 登记）。
  final String asset;

  /// 分类里命中任一关键词即算「古风题材」→ 插画 2。
  static const List<String> ancientKeywords = ['玄幻', '仙侠', '武侠', '古风'];

  /// 分类里命中任一关键词即算「现代题材」→ 插画 3。
  static const List<String> modernKeywords = ['现代', '都市', '科幻', '魔幻'];

  /// 按书籍分类挑插画。
  ///
  /// 规则：只命中古风题材 → [illustration2]；只命中现代题材 →
  /// [illustration3]；两方都命中或都不命中 → [illustration1]。
  ///
  /// [category] 是书籍设置里的分类原文，按「包含关键词」判断（分类常写成
  /// 「玄幻」「东方玄幻」这类短句，不要求完全相等）。
  static CoverIllustration forCategory(String category) {
    final ancient = ancientKeywords.any(
      (keyword) => category.contains(keyword),
    );
    final modern = modernKeywords.any((keyword) => category.contains(keyword));
    if (ancient == modern) return illustration1;
    return ancient ? illustration2 : illustration3;
  }
}
