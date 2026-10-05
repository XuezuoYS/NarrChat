import 'dart:convert';

/// 轮次模型，对应数据库 `rounds` 表，通过 [bookUuid] 关联书籍。
class Round {
  /// 本轮自增主键（子表保留 int id，仅本地行标识，不参与同步身份）。
  final int? id;

  /// 所属书籍 uuid（`rounds.book_uuid`，FK → `books.uuid`）。
  final String bookUuid;
  final int roundIndex;
  final String userInput;
  final String aiNarrative;
  final String worldState;
  final String characterState;
  final String memorySummary;
  final String currentTime;
  final String recommendedAction;

  /// 输入 token（提示词侧用量，含缓存命中部分）。
  ///
  /// `null` = **无数据**（模型未返回 usage / 历史轮次未记录），界面显示「（无）」；
  /// 与 `0`（模型确实报了 0）区分，故读写都保留 null，不回落 0。
  final int? tokensIn;

  /// 输出 token（补全侧用量）；`null` 语义同 [tokensIn]。
  final int? tokensOut;

  /// 缓存命中的输入 token（DeepSeek `usage.prompt_cache_hit_tokens` /
  /// OpenAI `usage.prompt_tokens_details.cached_tokens`）；`null` = 模型未返回该字段。
  final int? cachedTokensIn;

  /// 本轮实际发送的模型名（`{{model}}` 解析值，如 `deepseek-v4-pro`）。
  final String modelName;
  final DateTime? createdAt;

  /// 用户消息附带的图片（相对路径数组，`img/<hash>.png`）。
  final List<String> userImages;

  /// AI 返回附带的图片（相对路径数组；为未来图像生成预留，本轮仅存储/展示）。
  final List<String> aiImages;

  /// 本行对应的 `round_stack` 行 uuid（该轮「当前应用代」的锚点）。
  ///
  /// 空串 = 尚未采纳（老库升级 / 老客户端写入），由采纳流程补建；
  /// 版本树（切换 / 采纳 / 指纹）靠它把投影行与历史代对上。
  final String useStackUuid;

  const Round({
    this.id,
    required this.bookUuid,
    required this.roundIndex,
    this.userInput = '',
    this.aiNarrative = '',
    this.worldState = '',
    this.characterState = '',
    this.memorySummary = '',
    this.currentTime = '',
    this.recommendedAction = '',
    this.tokensIn,
    this.tokensOut,
    this.cachedTokensIn,
    this.modelName = '',
    this.createdAt,
    this.userImages = const [],
    this.aiImages = const [],
    this.useStackUuid = '',
  });

  factory Round.fromMap(Map<String, Object?> map) {
    return Round(
      id: map['id'] as int?,
      bookUuid: (map['book_uuid'] as String?) ?? '',
      roundIndex: (map['round_index'] as int?) ?? 0,
      userInput: (map['user_input'] as String?) ?? '',
      aiNarrative: (map['ai_narrative'] as String?) ?? '',
      worldState: (map['world_state'] as String?) ?? '',
      characterState: (map['character_state'] as String?) ?? '',
      memorySummary: (map['memory_summary'] as String?) ?? '',
      currentTime: (map['current_time'] as String?) ?? '',
      recommendedAction: (map['recommended_action'] as String?) ?? '',
      tokensIn: map['tokens_in'] as int?,
      tokensOut: map['tokens_out'] as int?,
      cachedTokensIn: map['cached_tokens_in'] as int?,
      modelName: (map['model_name'] as String?) ?? '',
      createdAt: map['created_at'] == null
          ? null
          : DateTime.tryParse(map['created_at'] as String),
      userImages: _decodeImages(map['user_images']),
      aiImages: _decodeImages(map['ai_images']),
      useStackUuid: (map['use_stack_uuid'] as String?) ?? '',
    );
  }

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'book_uuid': bookUuid,
      'round_index': roundIndex,
      ...contentMap(),
      // 老 schema（v18 及更早的库 / 老备份）没有该列：空锚点时不写该键，
      // 让列取默认值（等价于空串），避免写入老库直接报“no column”。
      if (useStackUuid.isNotEmpty) 'use_stack_uuid': useStackUuid,
      'created_at': createdAt?.toIso8601String(),
    };
  }

  /// 内容列（与 `round_stack` 同形，**唯一来源**）：不含 `id` / `book_uuid` /
  /// `round_index` / 时间戳 / 版本树锚点。
  ///
  /// 「原地修改」写 `rounds` 与写 `round_stack` 共用本映射；内容指纹也按同一
  /// 字段集比对（时间戳不参与）。
  Map<String, Object?> contentMap() {
    return {
      'user_input': userInput,
      'ai_narrative': aiNarrative,
      'world_state': worldState,
      'character_state': characterState,
      'memory_summary': memorySummary,
      'current_time': currentTime,
      'recommended_action': recommendedAction,
      'tokens_in': tokensIn,
      'tokens_out': tokensOut,
      'cached_tokens_in': cachedTokensIn,
      'model_name': modelName,
      'user_images': jsonEncode(userImages),
      'ai_images': jsonEncode(aiImages),
    };
  }

  static List<String> _decodeImages(Object? raw) {
    if (raw is! String || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.map((e) => e.toString()).toList();
      }
    } catch (_) {
      // 非法 JSON 视为空。
    }
    return const [];
  }

  /// 按数据库列名写回单个可编辑字段（白名单外的字段原样返回）。
  ///
  /// 供侧边栏「保存快照」与 `RoundProvider.updateRoundField` 共用，
  /// 避免列名 → 模型字段的映射在 UI / Provider 两处漂移。
  Round withField(String field, String value) => switch (field) {
        RoundField.worldState => copyWith(worldState: value),
        RoundField.characterState => copyWith(characterState: value),
        RoundField.memorySummary => copyWith(memorySummary: value),
        RoundField.currentTime => copyWith(currentTime: value),
        RoundField.aiNarrative => copyWith(aiNarrative: value),
        RoundField.userInput => copyWith(userInput: value),
        _ => this,
      };

  Round copyWith({
    int? id,
    String? bookUuid,
    int? roundIndex,
    String? userInput,
    String? aiNarrative,
    String? worldState,
    String? characterState,
    String? memorySummary,
    String? currentTime,
    String? recommendedAction,
    int? tokensIn,
    int? tokensOut,
    int? cachedTokensIn,
    String? modelName,
    DateTime? createdAt,
    List<String>? userImages,
    List<String>? aiImages,
    String? useStackUuid,
  }) {
    return Round(
      id: id ?? this.id,
      bookUuid: bookUuid ?? this.bookUuid,
      roundIndex: roundIndex ?? this.roundIndex,
      userInput: userInput ?? this.userInput,
      aiNarrative: aiNarrative ?? this.aiNarrative,
      worldState: worldState ?? this.worldState,
      characterState: characterState ?? this.characterState,
      memorySummary: memorySummary ?? this.memorySummary,
      currentTime: currentTime ?? this.currentTime,
      recommendedAction: recommendedAction ?? this.recommendedAction,
      tokensIn: tokensIn ?? this.tokensIn,
      tokensOut: tokensOut ?? this.tokensOut,
      cachedTokensIn: cachedTokensIn ?? this.cachedTokensIn,
      modelName: modelName ?? this.modelName,
      createdAt: createdAt ?? this.createdAt,
      userImages: userImages ?? this.userImages,
      aiImages: aiImages ?? this.aiImages,
      useStackUuid: useStackUuid ?? this.useStackUuid,
    );
  }
}

/// `rounds` 表可被侧边栏编辑的字段名（数据库列名）。
///
/// [SidebarPanel] 与 [RoundProvider.updateRoundField] 白名单共用，
/// 避免 UI / Provider / 数据库三处字符串漂移。
class RoundField {
  RoundField._();

  static const String worldState = 'world_state';
  static const String characterState = 'character_state';
  static const String memorySummary = 'memory_summary';
  static const String currentTime = 'current_time';
  static const String aiNarrative = 'ai_narrative';
  static const String userInput = 'user_input';

  /// 可编辑字段白名单（侧边栏「保存快照」与 `RoundProvider.updateRoundField` 共用）。
  static const Set<String> editable = {
    worldState,
    characterState,
    memorySummary,
    currentTime,
    aiNarrative,
    userInput,
  };
}
