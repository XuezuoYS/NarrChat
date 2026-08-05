import 'dart:convert';

import '../models/role_category.dart';

/// 全局常量与工具函数。
class Constants {
  Constants._();

  /// 默认的角色分类排序（书籍设置对话框中可拖拽调整、增删）。
  static const List<String> defaultRoleHierarchy = [
    '主角',
    '女主角',
    '次要女主角',
    '其它重要人物',
    'NPC',
  ];

  /// 默认角色类别（含每个类别的详细描述格式模板，供 AI 组织角色状态）。
  static const List<RoleCategory> defaultRoleCategories = [
    RoleCategory(
      name: '主角',
      format: '- 姓名：\n- 修为：\n- 心性：\n- 目标：\n- 当前状态：',
    ),
    RoleCategory(
      name: '女主角',
      format: '- 姓名：\n- 修为：\n- 心性：\n- 立场：\n- 当前状态：',
    ),
    RoleCategory(
      name: '次要女主角',
      format: '- 姓名：\n- 修为：\n- 与主角关系：\n- 当前状态：',
    ),
    RoleCategory(
      name: '其它重要人物',
      format: '- 姓名：\n- 身份：\n- 与主角关系：\n- 当前状态：',
    ),
    RoleCategory(
      name: 'NPC',
      format: '- 姓名：\n- 身份：\n- 当前状态：',
    ),
  ];

  /// AI 回复必须输出的 6 个二级标题区块名（顺序无关，按标题匹配）。
  static const List<String> aiSections = [
    '剧情演绎',
    '世界状态',
    '角色状态',
    '记忆总结',
    '当前时间',
    '推荐行动',
  ];

  /// 将角色分类列表拼接为数据库存储的层级排序字符串。
  static String joinRoleHierarchy(List<String> roles) {
    return roles.where((r) => r.trim().isNotEmpty).map((r) => r.trim()).join(' > ');
  }

  /// 将数据库存储的层级排序字符串拆分为角色分类列表；为空时返回默认列表。
  static List<String> splitRoleHierarchy(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return List.of(defaultRoleHierarchy);
    }
    final parts = raw
        .split(RegExp(r'\s*>\s*'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    return parts.isEmpty ? List.of(defaultRoleHierarchy) : parts;
  }

  /// 将角色类别列表序列化为 JSON 字符串（存入 role_hierarchy_detail 列）。
  static String encodeRoleCategories(List<RoleCategory> categories) {
    return jsonEncode(categories.map((c) => c.toMap()).toList());
  }

  /// 将 JSON 字符串反序列化为角色类别列表；为空或解析失败时返回默认列表。
  static List<RoleCategory> decodeRoleCategories(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return List.of(defaultRoleCategories);
    }
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      final result = list
          .map((e) => RoleCategory.fromMap(e as Map<String, dynamic>))
          .where((c) => c.name.isNotEmpty)
          .toList();
      return result.isEmpty ? List.of(defaultRoleCategories) : result;
    } catch (_) {
      return List.of(defaultRoleCategories);
    }
  }
}
