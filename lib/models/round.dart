/// 轮次模型，对应数据库 `rounds` 表，通过 [bookId] 关联书籍。
class Round {
  final int? id;
  final int bookId;
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
  final DateTime? createdAt;

  const Round({
    this.id,
    required this.bookId,
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
    this.createdAt,
  });

  factory Round.fromMap(Map<String, Object?> map) {
    return Round(
      id: map['id'] as int?,
      bookId: (map['book_id'] as int?) ?? 0,
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
      createdAt: map['created_at'] == null
          ? null
          : DateTime.tryParse(map['created_at'] as String),
    );
  }

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'book_id': bookId,
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
      'created_at': createdAt?.toIso8601String(),
    };
  }

  Round copyWith({
    int? id,
    int? bookId,
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
    DateTime? createdAt,
  }) {
    return Round(
      id: id ?? this.id,
      bookId: bookId ?? this.bookId,
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
      createdAt: createdAt ?? this.createdAt,
    );
  }
}
