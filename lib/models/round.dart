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
  final int tokensIn;
  final int tokensOut;

  /// 本轮实际发送的模型名（`{{model}}` 解析值，如 `deepseek-v4-pro`）。
  final String modelName;
  final DateTime? createdAt;

  /// 用户消息附带的图片（相对路径数组，`img/<hash>.png`）。
  final List<String> userImages;

  /// AI 返回附带的图片（相对路径数组；为未来图像生成预留，本轮仅存储/展示）。
  final List<String> aiImages;

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
    this.tokensIn = 0,
    this.tokensOut = 0,
    this.modelName = '',
    this.createdAt,
    this.userImages = const [],
    this.aiImages = const [],
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
      tokensIn: (map['tokens_in'] as int?) ?? 0,
      tokensOut: (map['tokens_out'] as int?) ?? 0,
      modelName: (map['model_name'] as String?) ?? '',
      createdAt: map['created_at'] == null
          ? null
          : DateTime.tryParse(map['created_at'] as String),
      userImages: _decodeImages(map['user_images']),
      aiImages: _decodeImages(map['ai_images']),
    );
  }

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'book_uuid': bookUuid,
      'round_index': roundIndex,
      'user_input': userInput,
      'ai_narrative': aiNarrative,
      'world_state': worldState,
      'character_state': characterState,
      'memory_summary': memorySummary,
      'current_time': currentTime,
      'recommended_action': recommendedAction,
      'tokens_in': tokensIn,
      'tokens_out': tokensOut,
      'model_name': modelName,
      'user_images': jsonEncode(userImages),
      'ai_images': jsonEncode(aiImages),
      'created_at': createdAt?.toIso8601String(),
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
    String? modelName,
    DateTime? createdAt,
    List<String>? userImages,
    List<String>? aiImages,
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
      modelName: modelName ?? this.modelName,
      createdAt: createdAt ?? this.createdAt,
      userImages: userImages ?? this.userImages,
      aiImages: aiImages ?? this.aiImages,
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
}
