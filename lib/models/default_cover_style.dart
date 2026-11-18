import 'cover_illustration.dart';

/// 首页在书籍未设置封面时使用的默认封面样式。
///
/// 声明顺序就是设置页下拉的展示顺序：无插画 → 插画适配 → 插画1/2/3。
/// 无论选哪种样式，都不会盖掉书籍自己的封面（`book_meta.book_cover_img`）。
enum DefaultCoverStyle {
  /// 无插画：程序生成含书名的灰底简约封面。
  noIllustration('无插画', 'none'),

  /// 插画适配：按书籍分类自动挑插画，规则见
  /// [CoverIllustration.forCategory]（古风 → 插画2，现代 → 插画3，其余插画1）。
  adaptive('插画适配', 'adaptive'),

  /// 内置插画 1（assets/girl1.png），也是默认样式。
  illustration1('插画1', 'illustration1'),

  /// 内置插画 2（assets/girl2.png）。
  illustration2('插画2', 'illustration2'),

  /// 内置插画 3（assets/girl3.png）。
  illustration3('插画3', 'illustration3');

  const DefaultCoverStyle(this.label, this.storageValue);

  /// 设置页展示文案。
  final String label;

  /// 本地配置文件中的存储值。
  final String storageValue;

  /// 默认样式：插画 1。
  static const DefaultCoverStyle defaultStyle = illustration1;

  /// 这本书实际使用的插画。
  ///
  /// [category] 为书籍分类，供「插画适配」挑图；返回 null 表示不加载插画
  /// （[noIllustration] 走程序生成的封面）。
  CoverIllustration? illustrationFor(String category) => switch (this) {
    noIllustration => null,
    adaptive => CoverIllustration.forCategory(category),
    illustration1 => CoverIllustration.illustration1,
    illustration2 => CoverIllustration.illustration2,
    illustration3 => CoverIllustration.illustration3,
  };

  /// 从本地配置解析；未知值（含手改出的怪值）回退 [defaultStyle]。
  static DefaultCoverStyle fromStorageValue(String? value) => switch (value) {
    'none' => noIllustration,
    'adaptive' => adaptive,
    'illustration2' => illustration2,
    'illustration3' => illustration3,
    // 'illustration1' 与未知值都落到默认样式。
    _ => defaultStyle,
  };
}
