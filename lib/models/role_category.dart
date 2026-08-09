/// 角色类别（含该类别在角色状态中的详细描述格式模板）。
///
/// 例如：主角 -> 「- 姓名：\n- 当前状态：」
/// 该模板会注入 System Prompt，让 AI 按此格式组织角色状态。
class RoleCategory {
  final String name;
  final String format;

  const RoleCategory({required this.name, this.format = ''});

  factory RoleCategory.fromMap(Map<String, dynamic> map) {
    return RoleCategory(
      name: (map['name'] as String?) ?? '',
      format: (map['format'] as String?) ?? '',
    );
  }

  Map<String, dynamic> toMap() => {'name': name, 'format': format};

  RoleCategory copyWith({String? name, String? format}) {
    return RoleCategory(
      name: name ?? this.name,
      format: format ?? this.format,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RoleCategory && other.name == name && other.format == format;

  @override
  int get hashCode => Object.hash(name, format);
}
