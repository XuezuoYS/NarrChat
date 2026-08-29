import '../utils/constants.dart';
import 'role_category.dart';

/// 书籍模型，对应数据库 `books` 表。
///
/// 身份：[uuid] 即数据库主键，本地与跨设备唯一，不存在第二个 id。
class Book {
  /// 数据库主键（UUID v4）。本地新建时由 [BookDao.insertBook] 生成；
  /// 空串仅表示「未落库的草稿」，已落库实例必非空。
  final String uuid;

  final String title;
  final String category;
  final String baseSetting;

  /// 文笔要求描述（写作规则/风格要求，区别于 [writingStyle] 文笔参考段落）。
  final String writingRequirements;

  /// 文笔参考段落（风格范例文本，仅注入 system）。
  final String writingStyle;
  final String globalPrePrompt;
  final String globalPostPrompt;
  final int historyRounds;
  final String roleHierarchy;

  /// 角色类别及其详细描述格式模板（存储于 role_hierarchy_detail 列，JSON）。
  final List<RoleCategory> roleCategories;

  const Book({
    this.uuid = '',
    required this.title,
    this.category = '',
    this.baseSetting = '',
    this.writingRequirements = '',
    this.writingStyle = '',
    this.globalPrePrompt = '',
    this.globalPostPrompt = '',
    this.historyRounds = 1,
    this.roleHierarchy = '',
    this.roleCategories = const [],
  });

  factory Book.fromMap(Map<String, Object?> map) {
    return Book(
      uuid: (map['uuid'] as String?) ?? '',
      title: (map['title'] as String?) ?? '',
      category: (map['category'] as String?) ?? '',
      baseSetting: (map['base_setting'] as String?) ?? '',
      writingRequirements: (map['writing_requirements'] as String?) ?? '',
      writingStyle: (map['writing_style'] as String?) ?? '',
      globalPrePrompt: (map['global_pre_prompt'] as String?) ?? '',
      globalPostPrompt: (map['global_post_prompt'] as String?) ?? '',
      historyRounds: (map['history_rounds'] as int?) ?? 1,
      roleHierarchy: (map['role_hierarchy'] as String?) ?? '',
      roleCategories:
          Constants.decodeRoleCategories(map['role_hierarchy_detail'] as String?),
    );
  }

  Map<String, Object?> toMap() {
    return {
      'uuid': uuid,
      'title': title,
      'category': category,
      'base_setting': baseSetting,
      'writing_requirements': writingRequirements,
      'writing_style': writingStyle,
      'global_pre_prompt': globalPrePrompt,
      'global_post_prompt': globalPostPrompt,
      'history_rounds': historyRounds,
      'role_hierarchy': roleHierarchy,
      'role_hierarchy_detail': Constants.encodeRoleCategories(roleCategories),
    };
  }

  Book copyWith({
    String? uuid,
    String? title,
    String? category,
    String? baseSetting,
    String? writingRequirements,
    String? writingStyle,
    String? globalPrePrompt,
    String? globalPostPrompt,
    int? historyRounds,
    String? roleHierarchy,
    List<RoleCategory>? roleCategories,
  }) {
    return Book(
      uuid: uuid ?? this.uuid,
      title: title ?? this.title,
      category: category ?? this.category,
      baseSetting: baseSetting ?? this.baseSetting,
      writingRequirements: writingRequirements ?? this.writingRequirements,
      writingStyle: writingStyle ?? this.writingStyle,
      globalPrePrompt: globalPrePrompt ?? this.globalPrePrompt,
      globalPostPrompt: globalPostPrompt ?? this.globalPostPrompt,
      historyRounds: historyRounds ?? this.historyRounds,
      roleHierarchy: roleHierarchy ?? this.roleHierarchy,
      roleCategories: roleCategories ?? this.roleCategories,
    );
  }
}
