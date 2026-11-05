/// 世界书条目模型，对应数据库 `world_book_entries` 表。
///
/// 每条目包含一个或多个关键词（用逗号/顿号分隔）与命中后注入 System Prompt 的内容。
///
/// 身份迁移：R2 用自增 `id`（仅本地行号），R3 换成跨设备稳定的 [uuid]。
/// 两个字段同时保留是为了让切换期两套读写都能编译，切换完成后 [id] 会删掉。
class WorldBookEntry {
  /// 条目自增主键（子表保留 int id，仅本地行标识）。
  final int? id;

  /// R3 身份（跨设备稳定）。
  final String uuid;

  /// 所属书籍 uuid（`world_book_entries.book_uuid`，FK → `books.uuid`）。
  final String bookUuid;

  /// 触发关键词，多个可用逗号 `,`、顿号 `、`、分号 `;` 分隔。
  final String keyword;

  /// 命中后注入 System Prompt 的内容。
  final String content;

  /// 是否启用（停用的条目不参与扫描）。
  final bool isActive;

  final DateTime? createdAt;

  /// R3 的更新时间（R2 没有这一列，读 R2 时为 null）。
  final DateTime? updatedAt;

  const WorldBookEntry({
    this.id,
    this.uuid = '',
    required this.bookUuid,
    required this.keyword,
    required this.content,
    this.isActive = true,
    this.createdAt,
    this.updatedAt,
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
      uuid: (map['uuid'] as String?) ?? '',
      bookUuid: (map['book_uuid'] as String?) ?? '',
      keyword: (map['keyword'] as String?) ?? '',
      content: (map['content'] as String?) ?? '',
      isActive: (map['is_active'] as int? ?? 1) == 1,
      createdAt: _parseTime(map['created_at']),
      updatedAt: _parseTime(map['updated_at']),
    );
  }

  /// 时间列在不同版本里形态不同：R2 的 `updated_at` 是 epoch 毫秒，
  /// R3 与 `created_at` 是 ISO 文本；两种都要能读。
  static DateTime? _parseTime(Object? raw) {
    if (raw is int) {
      if (raw <= 0) return null;
      return DateTime.fromMillisecondsSinceEpoch(raw, isUtc: true);
    }
    if (raw is String && raw.isNotEmpty) return DateTime.tryParse(raw);
    return null;
  }

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'book_uuid': bookUuid,
      'keyword': keyword,
      'content': content,
      'is_active': isActive ? 1 : 0,
      'created_at': createdAt?.toIso8601String(),
    };
  }

  WorldBookEntry copyWith({
    int? id,
    String? uuid,
    String? bookUuid,
    String? keyword,
    String? content,
    bool? isActive,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return WorldBookEntry(
      id: id ?? this.id,
      uuid: uuid ?? this.uuid,
      bookUuid: bookUuid ?? this.bookUuid,
      keyword: keyword ?? this.keyword,
      content: content ?? this.content,
      isActive: isActive ?? this.isActive,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
