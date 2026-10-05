import 'dart:convert';

import 'round.dart';

/// 版本树 `round_stack` 的一行：某一轮的**一代**生成快照。
///
/// - [uuid]：本行身份（跨设备 / 整库恢复后稳定），投影行 [Round.useStackUuid] 指向它；
/// - [fatherUuid]：上一轮当时活动代的 uuid；`null` = 根（第零轮 / 链首）；
/// - [roundSerialNum]：同一 `(book, round_index, father)` 分组内的存活次序（可跳步，
///   物理删除后可复用；身份一律靠 [uuid]）；
/// - [roundState]：`'use'` = 分组内选中记忆；`null` = 闲置。
///
/// 内容列与 `rounds` 同形（除时间列）：`round_created_at` 是 epoch 毫秒，
/// 与 `rounds.created_at`（ISO 文本）在 DAO / 模型边界互转（见 [fromRound] / [toRound]）。
class RoundStackRow {
  final String uuid;
  final String bookUuid;
  final String? fatherUuid;
  final int roundIndex;
  final int roundSerialNum;
  final String? roundState;

  /// 本代创建时间；`null` = 库内 `0`（历史行无时间戳 / 第零轮兜底）。
  final DateTime? roundCreatedAt;

  final String userInput;
  final String aiNarrative;
  final String worldState;
  final String characterState;
  final String memorySummary;
  final String currentTime;
  final String recommendedAction;
  final int? tokensIn;
  final int? tokensOut;
  final int? cachedTokensIn;
  final String modelName;
  final List<String> userImages;
  final List<String> aiImages;

  const RoundStackRow({
    required this.uuid,
    required this.bookUuid,
    this.fatherUuid,
    required this.roundIndex,
    required this.roundSerialNum,
    this.roundState,
    this.roundCreatedAt,
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
    this.userImages = const [],
    this.aiImages = const [],
  });

  /// 是否已在本分组内被选中（`round_state = 'use'`）。
  bool get isUse => roundState == 'use';

  factory RoundStackRow.fromMap(Map<String, Object?> map) {
    return RoundStackRow(
      uuid: (map['uuid'] as String?) ?? '',
      bookUuid: (map['book_uuid'] as String?) ?? '',
      fatherUuid: normalizeFather(map['father_uuid'] as String?),
      roundIndex: (map['round_index'] as int?) ?? 0,
      roundSerialNum: (map['round_serial_num'] as int?) ?? 0,
      roundState: _normalizeState(map['round_state'] as String?),
      roundCreatedAt: _decodeTime(map['round_created_at']),
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
      userImages: _decodeImages(map['user_images']),
      aiImages: _decodeImages(map['ai_images']),
    );
  }

  Map<String, Object?> toMap() {
    return {
      'uuid': uuid,
      'book_uuid': bookUuid,
      'father_uuid': fatherUuid,
      'round_index': roundIndex,
      'round_serial_num': roundSerialNum,
      'round_state': roundState,
      'round_created_at': roundCreatedAt?.millisecondsSinceEpoch ?? 0,
      ...contentMap(),
    };
  }

  /// 内容列（与 `rounds` 同形，**唯一来源**）：不含身份 / 父 / 序号 / 状态 /
  /// 创建时间，供「原地修改」与内容指纹共用。
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

  /// 由投影行（`rounds`）复制出一代：[uuid] 由调用方分配（新建代 / 复用代）。
  factory RoundStackRow.fromRound(
    Round round, {
    required String uuid,
    String? fatherUuid,
    required int roundSerialNum,
    String? roundState,
  }) {
    return RoundStackRow(
      uuid: uuid,
      bookUuid: round.bookUuid,
      fatherUuid: normalizeFather(fatherUuid),
      roundIndex: round.roundIndex,
      roundSerialNum: roundSerialNum,
      roundState: _normalizeState(roundState),
      roundCreatedAt: round.createdAt,
      userInput: round.userInput,
      aiNarrative: round.aiNarrative,
      worldState: round.worldState,
      characterState: round.characterState,
      memorySummary: round.memorySummary,
      currentTime: round.currentTime,
      recommendedAction: round.recommendedAction,
      tokensIn: round.tokensIn,
      tokensOut: round.tokensOut,
      cachedTokensIn: round.cachedTokensIn,
      modelName: round.modelName,
      userImages: round.userImages,
      aiImages: round.aiImages,
    );
  }

  /// 还原为投影行（`rounds`）；[id] 由调用方按库内自增 id 提供（新插入时为 null）。
  Round toRound({int? id}) {
    return Round(
      id: id,
      bookUuid: bookUuid,
      roundIndex: roundIndex,
      userInput: userInput,
      aiNarrative: aiNarrative,
      worldState: worldState,
      characterState: characterState,
      memorySummary: memorySummary,
      currentTime: currentTime,
      recommendedAction: recommendedAction,
      tokensIn: tokensIn,
      tokensOut: tokensOut,
      cachedTokensIn: cachedTokensIn,
      modelName: modelName,
      createdAt: roundCreatedAt,
      userImages: userImages,
      aiImages: aiImages,
      useStackUuid: uuid,
    );
  }

  RoundStackRow copyWith({
    String? uuid,
    String? bookUuid,
    String? fatherUuid,
    bool clearFather = false,
    int? roundIndex,
    int? roundSerialNum,
    String? roundState,
    bool clearState = false,
    DateTime? roundCreatedAt,
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
    List<String>? userImages,
    List<String>? aiImages,
  }) {
    return RoundStackRow(
      uuid: uuid ?? this.uuid,
      bookUuid: bookUuid ?? this.bookUuid,
      fatherUuid: clearFather ? null : (fatherUuid ?? this.fatherUuid),
      roundIndex: roundIndex ?? this.roundIndex,
      roundSerialNum: roundSerialNum ?? this.roundSerialNum,
      roundState: clearState ? null : _normalizeState(roundState ?? this.roundState),
      roundCreatedAt: roundCreatedAt ?? this.roundCreatedAt,
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
      userImages: userImages ?? this.userImages,
      aiImages: aiImages ?? this.aiImages,
    );
  }

  /// `''` / 空白视为「无父」（根），统一为 `null`，避免 `IS NULL` 与 `= ''` 两套语义。
  static String? normalizeFather(String? raw) {
    final value = raw?.trim() ?? '';
    return value.isEmpty ? null : value;
  }

  /// `round_state` 只允许 `'use'` 或 null（其它脏值一律按闲置处理）。
  static String? _normalizeState(String? raw) => raw == 'use' ? 'use' : null;

  /// epoch 毫秒 → [DateTime]；`0` / 非正整数视为无时间戳。
  static DateTime? _decodeTime(Object? raw) {
    final ms = raw is int ? raw : (raw is num ? raw.toInt() : 0);
    return ms > 0 ? DateTime.fromMillisecondsSinceEpoch(ms) : null;
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
}

/// `round_stack` 的元数据投影（**不含正文**）：控件显隐 / 计数 / 归一化判定专用。
///
/// 读正文的路径只有采纳 / 切换 / 指纹，UI 热路径一律走本类型，避免把每代全文
/// 拉进内存。
class RoundStackMeta {
  final String uuid;
  final String bookUuid;
  final String? fatherUuid;
  final int roundIndex;
  final int roundSerialNum;
  final String? roundState;
  final DateTime? roundCreatedAt;

  const RoundStackMeta({
    required this.uuid,
    required this.bookUuid,
    this.fatherUuid,
    required this.roundIndex,
    required this.roundSerialNum,
    this.roundState,
    this.roundCreatedAt,
  });

  bool get isUse => roundState == 'use';

  factory RoundStackMeta.fromMap(Map<String, Object?> map) {
    return RoundStackMeta(
      uuid: (map['uuid'] as String?) ?? '',
      bookUuid: (map['book_uuid'] as String?) ?? '',
      fatherUuid: RoundStackRow.normalizeFather(map['father_uuid'] as String?),
      roundIndex: (map['round_index'] as int?) ?? 0,
      roundSerialNum: (map['round_serial_num'] as int?) ?? 0,
      roundState: map['round_state'] == 'use' ? 'use' : null,
      roundCreatedAt: RoundStackRow._decodeTime(map['round_created_at']),
    );
  }
}

/// 某一轮「可切换版本」的元数据（供对话页气泡 footer 的代次控件）。
class RoundVersionInfo {
  /// 当前应用代号（= 投影行指向的那一代的 `round_serial_num`）；
  /// `null` = 投影行不存在（失败态 / 老库尚未采纳），界面显示「临时」。
  final int? currentSerial;

  /// 分组内最大存活代号。
  final int latestSerial;

  /// 分组内存活代数。
  final int aliveCount;

  /// 当前应用代 uuid（投影行指向；无投影行时为 `null`）。
  final String? currentUuid;

  /// 上一代 uuid（无则 `null`）。
  final String? prevUuid;

  /// 下一代 uuid（无则 `null`）。
  final String? nextUuid;

  /// [prevUuid] / [nextUuid] 的代号（tooltip 用；无则 `null`）。
  final int? prevSerial;
  final int? nextSerial;

  const RoundVersionInfo({
    required this.currentSerial,
    required this.latestSerial,
    required this.aliveCount,
    this.currentUuid,
    this.prevUuid,
    this.nextUuid,
    this.prevSerial,
    this.nextSerial,
  });

  /// 是否显示控件（单代不显示）。
  bool get switchable => aliveCount >= 2;
}

/// 一次采纳（`rounds` 为准收敛版本树）的结果报告。
class RoundStackAdoptionReport {
  /// 命中同内容代而复用的次数（不新建）。
  final int reused;

  /// 新建代的次数。
  final int created;

  /// 因 `rounds` 缺口而删除的「匹配到的父」子树次数。
  final int removedSubtree;

  /// 清理的孤儿行数。
  final int purgedOrphans;

  /// 归一化自愈（多 use / 无 use / 重复序号）改动的行数。
  final int normalized;

  const RoundStackAdoptionReport({
    this.reused = 0,
    this.created = 0,
    this.removedSubtree = 0,
    this.purgedOrphans = 0,
    this.normalized = 0,
  });

  bool get hasChanges =>
      reused > 0 ||
      created > 0 ||
      removedSubtree > 0 ||
      purgedOrphans > 0 ||
      normalized > 0;
}
