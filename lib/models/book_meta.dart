import '../utils/image_path_utils.dart';
import '../utils/timestamp_format.dart';

/// 单本书的元信息（`book_meta` 表，单行）。
///
/// 这本书的**书名信源**就在这里；`library.books.title` 与 `library_cache`
/// 里的书名都是可重建的副本，改名时三处一起写。
///
/// 时间语义：`updated_at` 是这本书「最近一次内容变更」——设置、轮次、分支、
/// 世界书、Mod 挂载全部计入。它是云备份冲突时的默认裁决依据。
class BookMeta {
  const BookMeta({
    required this.bookUuid,
    this.masterUuid = '',
    this.title = '',
    this.category = '',
    required this.createdAt,
    required this.updatedAt,
    this.baseSetting = '',
    this.writingRequirements = '',
    this.writingStyle = '',
    this.globalPrePrompt = '',
    this.globalPostPrompt = '',
    this.historyRounds = 1,
    this.memorySummaryRounds = 0,
    this.roleHierarchy = '',
    this.roleHierarchyDetail = '',
    this.bookCoverImg,
  });

  /// 与文件名、`library.books.book_uuid` 一致，用于校验。
  final String bookUuid;

  /// 继承自 library 的全局 UUID，用于校验「几个库是不是同一套数据」。
  final String masterUuid;

  final String title;
  final String category;
  final DateTime createdAt;
  final DateTime updatedAt;

  final String baseSetting;
  final String writingRequirements;
  final String writingStyle;
  final String globalPrePrompt;
  final String globalPostPrompt;
  final int historyRounds;
  final int memorySummaryRounds;
  final String roleHierarchy;
  final String roleHierarchyDetail;

  /// 自定义封面的图片相对路径，格式与 `user_images` 的元素一致
  /// （`img/<哈希>.<扩展名>`，相对 `user_data/`）。
  ///
  /// `null` = 没有自定义封面，首页走默认封面样式；库里这一列允许为 NULL。
  final String? bookCoverImg;

  factory BookMeta.fromRow(Map<String, Object?> row) {
    final now = DateTime.now().toUtc();
    return BookMeta(
      bookUuid: (row['book_uuid'] as String?) ?? '',
      masterUuid: (row['master_uuid'] as String?) ?? '',
      title: (row['title'] as String?) ?? '',
      category: (row['category'] as String?) ?? '',
      createdAt: parseTimestampOr(row['created_at'], now),
      updatedAt: parseTimestampOr(row['updated_at'], now),
      baseSetting: (row['base_setting'] as String?) ?? '',
      writingRequirements: (row['writing_requirements'] as String?) ?? '',
      writingStyle: (row['writing_style'] as String?) ?? '',
      globalPrePrompt: (row['global_pre_prompt'] as String?) ?? '',
      globalPostPrompt: (row['global_post_prompt'] as String?) ?? '',
      historyRounds: (row['history_rounds'] as int?) ?? 1,
      memorySummaryRounds: (row['memory_summary_rounds'] as int?) ?? 0,
      roleHierarchy: (row['role_hierarchy'] as String?) ?? '',
      roleHierarchyDetail: (row['role_hierarchy_detail'] as String?) ?? '',
      bookCoverImg: cleanImagePath(row['book_cover_img']),
    );
  }

  /// 整行写入（新建书库时用）；`database_version` 由调用方补。
  Map<String, Object?> toRow() {
    return {
      'master_uuid': masterUuid,
      'book_uuid': bookUuid,
      'title': title,
      'category': category,
      'created_at': formatTimestamp(createdAt),
      'updated_at': formatTimestamp(updatedAt),
      ...settingsRow(),
    };
  }

  /// 设置列（不含身份、时间戳与版本镜像）。改设置时只写这一份。
  Map<String, Object?> settingsRow() {
    return {
      'title': title,
      'category': category,
      'base_setting': baseSetting,
      'writing_requirements': writingRequirements,
      'writing_style': writingStyle,
      'global_pre_prompt': globalPrePrompt,
      'global_post_prompt': globalPostPrompt,
      'history_rounds': historyRounds,
      'memory_summary_rounds': memorySummaryRounds,
      'role_hierarchy': roleHierarchy,
      'role_hierarchy_detail': roleHierarchyDetail,
      'book_cover_img': bookCoverImg,
    };
  }

  BookMeta copyWith({
    String? masterUuid,
    String? title,
    String? category,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? baseSetting,
    String? writingRequirements,
    String? writingStyle,
    String? globalPrePrompt,
    String? globalPostPrompt,
    int? historyRounds,
    int? memorySummaryRounds,
    String? roleHierarchy,
    String? roleHierarchyDetail,
    String? bookCoverImg,
    bool clearBookCoverImg = false,
  }) {
    return BookMeta(
      bookUuid: bookUuid,
      masterUuid: masterUuid ?? this.masterUuid,
      title: title ?? this.title,
      category: category ?? this.category,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      baseSetting: baseSetting ?? this.baseSetting,
      writingRequirements: writingRequirements ?? this.writingRequirements,
      writingStyle: writingStyle ?? this.writingStyle,
      globalPrePrompt: globalPrePrompt ?? this.globalPrePrompt,
      globalPostPrompt: globalPostPrompt ?? this.globalPostPrompt,
      historyRounds: historyRounds ?? this.historyRounds,
      memorySummaryRounds: memorySummaryRounds ?? this.memorySummaryRounds,
      roleHierarchy: roleHierarchy ?? this.roleHierarchy,
      roleHierarchyDetail: roleHierarchyDetail ?? this.roleHierarchyDetail,
      bookCoverImg: clearBookCoverImg
          ? null
          : (bookCoverImg ?? this.bookCoverImg),
    );
  }
}
