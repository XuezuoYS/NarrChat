import '../utils/timestamp_format.dart';

/// 世界书条目（`world_book_entries` 表，随书库）。
///
/// 与 R2 的差别：身份从自增 `id` 换成 `uuid`（跨设备稳定），
/// `is_active` 改名为 `is_using`，并补了 `updated_at`。
class WorldBookRow {
  const WorldBookRow({
    required this.uuid,
    this.keyword = '',
    this.content = '',
    this.isUsing = false,
    required this.createdAt,
    required this.updatedAt,
  });

  final String uuid;

  /// 触发关键词，多个用 `,` `，` `、` `;` `；` 分隔。
  final String keyword;

  /// 命中后注入提示词的内容。
  final String content;

  final bool isUsing;

  final DateTime createdAt;
  final DateTime updatedAt;

  /// 拆分为单个关键词列表（与 R2 的拆分规则保持一致）。
  List<String> get keywords => keyword
      .split(RegExp(r'[,，、;；]'))
      .map((k) => k.trim())
      .where((k) => k.isNotEmpty)
      .toList();

  factory WorldBookRow.fromRow(Map<String, Object?> row) {
    final now = DateTime.now().toUtc();
    return WorldBookRow(
      uuid: (row['uuid'] as String?) ?? '',
      keyword: (row['keyword'] as String?) ?? '',
      content: (row['content'] as String?) ?? '',
      isUsing: ((row['is_using'] as int?) ?? 0) != 0,
      createdAt: parseTimestampOr(row['created_at'], now),
      updatedAt: parseTimestampOr(row['updated_at'], now),
    );
  }

  Map<String, Object?> toRow() {
    return {
      'uuid': uuid,
      'keyword': keyword,
      'content': content,
      'is_using': isUsing ? 1 : 0,
      'created_at': formatTimestamp(createdAt),
      'updated_at': formatTimestamp(updatedAt),
    };
  }

  WorldBookRow copyWith({
    String? keyword,
    String? content,
    bool? isUsing,
    DateTime? updatedAt,
  }) {
    return WorldBookRow(
      uuid: uuid,
      keyword: keyword ?? this.keyword,
      content: content ?? this.content,
      isUsing: isUsing ?? this.isUsing,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
