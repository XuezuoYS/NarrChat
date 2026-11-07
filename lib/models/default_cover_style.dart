/// 首页在书籍未设置封面时使用的默认封面样式。
enum DefaultCoverStyle {
  /// 内置插画 1（assets/girl1.png）。
  illustration1('插画1', 'illustration1'),

  /// 无插画：程序生成含书名的灰底简约封面。
  noIllustration('无插画', 'none');

  const DefaultCoverStyle(this.label, this.storageValue);

  /// 设置页展示文案。
  final String label;

  /// 本地配置文件中的存储值。
  final String storageValue;

  /// 从本地配置解析；未知值回退 [illustration1]。
  static DefaultCoverStyle fromStorageValue(String? value) =>
      value == 'none' ? noIllustration : illustration1;
}
