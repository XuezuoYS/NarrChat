/// 世界书条目模型，对应数据库 `world_book_entries` 表。
///
/// 每条目包含一个或多个关键词（用逗号/顿号分隔）与命中后注入 System Prompt 的内容。
class WorldBookEntry {
  final int? id;
  final int bookId;

  /// 触发关键词，多个可用逗号 `,`、顿号 `、`、分号 `;` 分隔。
  final String keyword;

  /// 命中后注入 System Prompt 的内容。
  final String content;

  /// 是否启用（停用的条目不参与扫描）。
  final bool isActive;

  final DateTime? createdAt;

  const WorldBookEntry({
    this.id,
    required this.bookId,
    required this.keyword,
    required this.content,
    this.isActive = true,
    this.createdAt,
  });

  /// 拆分为单个关键词列表。
  List<String> get keywords => keyword
      .split(RegExp(r'[,，、;；]'))
      .map((k) => k.trim())
      .where((k) => k.isNotEmpty)
      .toList();

  factory WorldBookEntry.fromMap(Map<String, Object?> map) {
    return WorldBookEntry(
      id: map['id'] as int?,
      bookId: (map['book_id'] as int?) ?? 0,
      keyword: (map['keyword'] as String?) ?? '',
      content: (map['content'] as String?) ?? '',
      isActive: (map['is_active'] as int? ?? 1) == 1,
      createdAt: map['created_at'] == null
          ? null
          : DateTime.tryParse(map['created_at'] as String),
    );
  }

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'book_id': bookId,
      'keyword': keyword,
      'content': content,
      'is_active': isActive ? 1 : 0,
      'created_at': createdAt?.toIso8601String(),
    };
  }

  WorldBookEntry copyWith({
    int? id,
    int? bookId,
    String? keyword,
    String? content,
    bool? isActive,
    DateTime? createdAt,
  }) {
    return WorldBookEntry(
      id: id ?? this.id,
      bookId: bookId ?? this.bookId,
      keyword: keyword ?? this.keyword,
      content: content ?? this.content,
      isActive: isActive ?? this.isActive,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}
