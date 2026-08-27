import 'dart:convert';

/// Mod 世界书条目（关键词 + 内容），与书籍的世界书一致。
///
/// - 关键词非空：扫描本轮输入与最近历史轮次，命中任一关键词才注入；
/// - 关键词为空：恒定生效（无需命中，等同直接填写内容）。
class ModWorldBookEntry {
  /// 触发关键词，多个可用逗号 `,`、顿号 `、`、分号 `;` 分隔；留空表示恒定生效。
  final String keyword;

  /// 命中后注入 System Prompt 的内容。
  final String content;

  const ModWorldBookEntry({this.keyword = '', this.content = ''});

  /// 拆分为单个关键词列表。
  List<String> get keywords => keyword
      .split(RegExp(r'[,，、;；]'))
      .map((k) => k.trim())
      .where((k) => k.isNotEmpty)
      .toList();

  Map<String, dynamic> toJson() => {'keyword': keyword, 'content': content};

  factory ModWorldBookEntry.fromJson(Map<String, dynamic> json) {
    return ModWorldBookEntry(
      keyword: (json['keyword'] as String?) ?? '',
      content: (json['content'] as String?) ?? '',
    );
  }

  ModWorldBookEntry copyWith({String? keyword, String? content}) {
    return ModWorldBookEntry(
      keyword: keyword ?? this.keyword,
      content: content ?? this.content,
    );
  }

  /// 序列化为 JSON 数组字符串（存入 `mods.world_book` 列）。
  static String encodeList(List<ModWorldBookEntry> entries) {
    return jsonEncode(entries.map((e) => e.toJson()).toList());
  }

  /// 从 JSON 数组字符串还原条目列表。
  ///
  /// 兼容旧版：若存储的是非 JSON 的纯文本（旧格式 world_book 字符串），
  /// 则整体作为一条无关键词（恒定生效）的条目。
  static List<ModWorldBookEntry> decodeList(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .whereType<Map<String, dynamic>>()
          .map(ModWorldBookEntry.fromJson)
          .where((e) => e.content.trim().isNotEmpty)
          .toList();
    } catch (_) {
      // 旧版字符串格式：整段内容作为恒定生效条目。
      return raw.trim().isEmpty ? const [] : [ModWorldBookEntry(content: raw.trim())];
    }
  }
}

/// Mod（扩展）模型：对前置词、后置词、系统提示词与世界书的自定义内容包。
///
/// 当书籍启用了某个 Mod 后，向 AI 发送请求时会自动将其内容置入对应的提示词
/// 位置（与用户手动填写效果一致）。名称与简介仅用于辨识，不会发送给 AI。
///
/// - 预置 Mod：仅可查看、不可修改（[presetKey] 非空、[id] 为 null）；
/// - 用户自定义 Mod：可查看、编辑、导出与导入（[id] 非空、[presetKey] 为 null）。
class Mod {
  /// 用户自定义 Mod 的数据库主键；预置 Mod 为 null。
  final int? id;

  /// 跨设备同步身份（UUID v4，用户 Mod 才有）。本地插入时自动生成。
  final String uuid;

  /// 预置 Mod 的稳定标识（如 `web_novel_style`）；用户自定义 Mod 为 null。
  final String? presetKey;

  /// 名称（仅用于辨识，不发送给 AI）。
  final String name;

  /// 简介（仅用于辨识，不发送给 AI）。
  final String description;

  /// 前置词内容（发送请求时自动置入用户提示词的前置词区）。
  final String prePrompt;

  /// 后置词内容（发送请求时自动置入用户提示词的后置词区）。
  final String postPrompt;

  /// 系统提示词内容（自动追加到 System Prompt）。
  final String systemPrompt;

  /// 世界书条目（关键词 + 内容，与书籍世界书一致）：
  /// 关键词非空时命中才注入，关键词为空时恒定生效。
  final List<ModWorldBookEntry> worldBookEntries;

  final DateTime? createdAt;
  final DateTime? updatedAt;

  const Mod({
    this.id,
    this.uuid = '',
    this.presetKey,
    this.name = '',
    this.description = '',
    this.prePrompt = '',
    this.postPrompt = '',
    this.systemPrompt = '',
    this.worldBookEntries = const [],
    this.createdAt,
    this.updatedAt,
  });

  /// 是否为预置 Mod（仅可查看）。
  bool get isPreset => presetKey != null;

  /// 唯一引用标识：预置用 `preset:<key>`，用户自定义用 `user:<id>`。
  String get ref => isPreset ? 'preset:$presetKey' : 'user:$id';

  factory Mod.fromMap(Map<String, Object?> map) {
    return Mod(
      id: map['id'] as int?,
      uuid: (map['uuid'] as String?) ?? '',
      presetKey: null,
      name: (map['name'] as String?) ?? '',
      description: (map['description'] as String?) ?? '',
      prePrompt: (map['pre_prompt'] as String?) ?? '',
      postPrompt: (map['post_prompt'] as String?) ?? '',
      systemPrompt: (map['system_prompt'] as String?) ?? '',
      worldBookEntries: ModWorldBookEntry.decodeList(map['world_book'] as String?),
      createdAt: map['created_at'] == null
          ? null
          : DateTime.tryParse(map['created_at'] as String),
      updatedAt: map['updated_at'] == null
          ? null
          : DateTime.tryParse(map['updated_at'] as String),
    );
  }

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'uuid': uuid,
      'name': name,
      'description': description,
      'pre_prompt': prePrompt,
      'post_prompt': postPrompt,
      'system_prompt': systemPrompt,
      'world_book': ModWorldBookEntry.encodeList(worldBookEntries),
      'created_at': createdAt?.toIso8601String(),
      'updated_at': updatedAt?.toIso8601String(),
    };
  }

  Mod copyWith({
    int? id,
    String? uuid,
    String? presetKey,
    String? name,
    String? description,
    String? prePrompt,
    String? postPrompt,
    String? systemPrompt,
    List<ModWorldBookEntry>? worldBookEntries,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Mod(
      id: id ?? this.id,
      uuid: uuid ?? this.uuid,
      presetKey: presetKey ?? this.presetKey,
      name: name ?? this.name,
      description: description ?? this.description,
      prePrompt: prePrompt ?? this.prePrompt,
      postPrompt: postPrompt ?? this.postPrompt,
      systemPrompt: systemPrompt ?? this.systemPrompt,
      worldBookEntries: worldBookEntries ?? this.worldBookEntries,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// 导出 / 分享用的 JSON 结构（仅包含内容与辨识字段，不包含数据库 id）。
  Map<String, dynamic> toJson() {
    return {
      'type': 'narrchat_mod',
      'version': 1,
      'name': name,
      'description': description,
      'prePrompt': prePrompt,
      'postPrompt': postPrompt,
      'systemPrompt': systemPrompt,
      'worldBookEntries': worldBookEntries.map((e) => e.toJson()).toList(),
    };
  }

  /// 从导入的 JSON 还原 Mod；name 缺失或为空返回 null（导入时跳过）。
  ///
  /// 兼容旧版导出：`worldBook` 字符串（整体作为恒定生效条目）与
  /// `worldBookEntries`（关键词 + 内容数组）均支持。
  static Mod? fromJson(Map<String, dynamic> json) {
    final name = (json['name'] as String?)?.trim() ?? '';
    if (name.isEmpty) return null;
    var entries = <ModWorldBookEntry>[];
    final wbList = json['worldBookEntries'];
    if (wbList is List) {
      entries = wbList
          .whereType<Map<String, dynamic>>()
          .map(ModWorldBookEntry.fromJson)
          .where((e) => e.content.trim().isNotEmpty)
          .toList();
    } else {
      final wbStr = (json['worldBook'] as String?)?.trim() ?? '';
      if (wbStr.isNotEmpty) {
        entries = [ModWorldBookEntry(content: wbStr)];
      }
    }
    return Mod(
      name: name,
      description: (json['description'] as String?) ?? '',
      prePrompt: (json['prePrompt'] as String?) ?? '',
      postPrompt: (json['postPrompt'] as String?) ?? '',
      systemPrompt: (json['systemPrompt'] as String?) ?? '',
      worldBookEntries: entries,
    );
  }
}

/// 某本书启用 Mod 后，按置入顺序（自上而下）拼接好的四段内容。
///
/// 由 [PromptBuilder] 分别注入 System Prompt 与 User Prompt。
class ModsBundle {
  final String prePrompts;
  final String postPrompts;
  final String systemPrompts;
  final String worldBooks;

  const ModsBundle({
    this.prePrompts = '',
    this.postPrompts = '',
    this.systemPrompts = '',
    this.worldBooks = '',
  });

  static const ModsBundle empty = ModsBundle();

  bool get isEmpty =>
      prePrompts.isEmpty &&
      postPrompts.isEmpty &&
      systemPrompts.isEmpty &&
      worldBooks.isEmpty;
}

/// 书籍与 Mod 的关联配置（启用状态 + 置入顺序）。
class BookModConfig {
  final int? id;
  final int bookId;

  /// 预置 Mod 标识（仅预置 Mod 使用）。
  final String? presetKey;

  /// 用户自定义 Mod 的数据库 id（仅用户 Mod 使用）。
  final int? modId;

  final bool isEnabled;

  /// 置入顺序，越小越靠前（自上而下）。
  final int sortOrder;

  const BookModConfig({
    this.id,
    this.bookId = 0,
    this.presetKey,
    this.modId,
    this.isEnabled = true,
    this.sortOrder = 0,
  });

  /// 唯一引用标识，与 [Mod.ref] 对应。
  String get ref => presetKey != null ? 'preset:$presetKey' : 'user:$modId';

  factory BookModConfig.fromMap(Map<String, Object?> map) {
    return BookModConfig(
      id: map['id'] as int?,
      bookId: (map['book_id'] as int?) ?? 0,
      presetKey: map['preset_key'] as String?,
      modId: map['mod_id'] as int?,
      isEnabled: (map['is_enabled'] as int? ?? 1) == 1,
      sortOrder: (map['sort_order'] as int?) ?? 0,
    );
  }

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'book_id': bookId,
      'preset_key': presetKey,
      'mod_id': modId,
      'is_enabled': isEnabled ? 1 : 0,
      'sort_order': sortOrder,
    };
  }

  BookModConfig copyWith({
    int? id,
    int? bookId,
    String? presetKey,
    int? modId,
    bool? isEnabled,
    int? sortOrder,
  }) {
    return BookModConfig(
      id: id ?? this.id,
      bookId: bookId ?? this.bookId,
      presetKey: presetKey ?? this.presetKey,
      modId: modId ?? this.modId,
      isEnabled: isEnabled ?? this.isEnabled,
      sortOrder: sortOrder ?? this.sortOrder,
    );
  }
}
