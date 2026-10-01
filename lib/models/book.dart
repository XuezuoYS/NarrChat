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

  /// 「记忆总结轮次合并」受支持的档位（单一真源）：
  /// 0 = 不开启；固定数值 = 每个合并项包含的轮次数（5 → 1-5、6-10）。
  static const List<int> memorySummaryRoundTiers = [0, 5, 10];

  /// 把库内原始值收敛为受支持档位：不属于 [memorySummaryRoundTiers] → 0。
  static int normalizeMemorySummaryRounds(int? raw) =>
      memorySummaryRoundTiers.contains(raw) ? raw! : 0;

  /// 记忆总结轮次合并档位：0 = 不开启，5 / 10 = 每个合并项包含的轮次数。
  ///
  /// 取值收敛发生在**库边界**（[fromMap] / [toMap]）：库中若存在未支持的数值
  /// （脏数据 / 已移除的档位），读取即按 0 执行，写回一律为受支持档位。
  /// 直接构造只接受受支持档位（UI 仅提供 0 / 5 / 10）。
  final int memorySummaryRounds;

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
    this.memorySummaryRounds = 0,
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
      memorySummaryRounds: normalizeMemorySummaryRounds(
        map['memory_summary_rounds'] as int?,
      ),
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
      'memory_summary_rounds': normalizeMemorySummaryRounds(memorySummaryRounds),
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
    int? memorySummaryRounds,
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
      memorySummaryRounds: memorySummaryRounds ?? this.memorySummaryRounds,
      roleHierarchy: roleHierarchy ?? this.roleHierarchy,
      roleCategories: roleCategories ?? this.roleCategories,
    );
  }
}
