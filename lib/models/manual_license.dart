/// 手动补充的开放源代码许可证条目。
///
/// 用于收录非 pub 依赖方式置入的开放源代码（如复制的代码片段、内置字体/图标、
/// 打包的二进制等），避免许可证页遗漏。数据来自打包资源 `assets/manual_licenses.json`
/// （开发者维护），与 `LicenseRegistry` 自动收集的依赖许可证合并展示。
class ManualLicense {
  /// 库 / 软件名称。
  final String name;

  /// 许可证全文（多行文本，段落以空行分隔）。
  final String license;

  const ManualLicense({required this.name, required this.license});

  /// 从资源 JSON 条目解析；字段缺失时回退为空值。
  factory ManualLicense.fromJson(Map<String, dynamic> json) {
    return ManualLicense(
      name: ((json['name'] as String?) ?? '').trim(),
      license: ((json['license'] as String?) ?? '').trim(),
    );
  }
}
