import 'dart:convert';

import 'round.dart';

/// 版本树 `round_stack` 的一行：某一轮的**一代**生成快照。
///
/// - [uuid]：本行身份（跨设备 / 整库恢复后稳定），投影行 [Round.useStackUuid] 指向它；
/// - [fatherUuid]：上一轮当时活动代的 uuid；`null` = 根（第零轮 / 链首）；
/// - [roundSerialNum]：同一 `(book, round_index, father)` 分组内的存活次序（可跳步，
///   物理删除后可复用；身份一律靠 [uuid]）；
/// - [roundState]：`'use'` = 分组内选中记忆；`'failed'` = **失败占位代**（该轮本该
///   产生却生成失败：内容全空、只带提示、不进活动链也不换代次控件）；`null` = 闲置。
///
/// 内容列与 `rounds` 同形（除时间列）：`round_created_at` 是 epoch 毫秒，
/// 与 `rounds.created_at`（ISO 文本）在 DAO / 模型边界互转（见 [fromRound] / [toRound]）。
///
/// [message] / [messageStatus] 是**本代的提示**（不是内容）：不进 [contentMap]、
/// 不进内容指纹，只在同步摘要里参与。级别白名单见 [normalizeStatus]。
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

  /// 本代的提示文本（多行用 `\n` 合并）；空 = 无提示。
  final String message;

  /// 提示级别：`'info'` / `'warning'` / `'error'`；`null` = 无级别（读时归一化）。
  final String? messageStatus;

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
    this.message = '',
    this.messageStatus,
  });

  /// 是否已在本分组内被选中（`round_state = 'use'`）。
  bool get isUse => roundState == 'use';

  /// 是否「失败占位代」：该轮本该产生但生成失败（只带提示，不参与活动链）。
  bool get isFailed => roundState == 'failed';

  /// 是否带提示文本（`null` / 纯空白一律视为无提示）。
  bool get hasMessage => hasMessageText(message);

  factory RoundStackRow.fromMap(Map<String, Object?> map) {
    final message = (map['message'] as String?) ?? '';
    return RoundStackRow(
      uuid: (map['uuid'] as String?) ?? '',
      bookUuid: (map['book_uuid'] as String?) ?? '',
      fatherUuid: normalizeFather(map['father_uuid'] as String?),
      roundIndex: (map['round_index'] as int?) ?? 0,
      roundSerialNum: (map['round_serial_num'] as int?) ?? 0,
      roundState: normalizeState(map['round_state'] as String?),
      roundCreatedAt: decodeTime(map['round_created_at']),
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
      message: message,
      // 无提示文本时级别无意义（脏数据自愈：读出来就是无级别）。
      messageStatus: hasMessageText(message)
          ? normalizeStatus(map['message_status'])
          : null,
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
      // 老 schema（v20 及更早的库 / 老备份）没有这两列：空提示时不写键，
      // 让列取默认值（等价于空串），避免写入老库直接报“no column”。
      // 同理：先清后插 / `INSERT OR REPLACE` 时「不写键」= 该行的提示被清空，
      // 正是「提示随行而行」的期望语义。
      if (hasMessage) 'message': clampMessage(message),
      if (messageStatus != null) 'message_status': messageStatus,
    };
  }

  /// 内容列（与 `rounds` 同形，**唯一来源**）：不含身份 / 父 / 序号 / 状态 /
  /// 创建时间，供「原地修改」与内容指纹共用。
  ///
  /// **提示（[message] / [messageStatus]）刻意不在其中**：它是「代」的附注而非内容，
  /// 进了内容指纹就会让「加一条提示」被采纳当成内容变化（同内容会长出新代）。
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
  ///
  /// [message] / [messageStatus]：新代的提示（生成结束时的常驻警告 / 失败原因）。
  factory RoundStackRow.fromRound(
    Round round, {
    required String uuid,
    String? fatherUuid,
    required int roundSerialNum,
    String? roundState,
    String message = '',
    String? messageStatus,
  }) {
    return RoundStackRow(
      uuid: uuid,
      bookUuid: round.bookUuid,
      fatherUuid: normalizeFather(fatherUuid),
      roundIndex: round.roundIndex,
      roundSerialNum: roundSerialNum,
      roundState: normalizeState(roundState),
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
      message: message,
      messageStatus: hasMessageText(message)
          ? normalizeStatus(messageStatus)
          : null,
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
    String? message,
    String? messageStatus,
    bool clearMessage = false,
  }) {
    final nextMessage = clearMessage ? '' : (message ?? this.message);
    return RoundStackRow(
      uuid: uuid ?? this.uuid,
      bookUuid: bookUuid ?? this.bookUuid,
      fatherUuid: clearFather ? null : (fatherUuid ?? this.fatherUuid),
      roundIndex: roundIndex ?? this.roundIndex,
      roundSerialNum: roundSerialNum ?? this.roundSerialNum,
      roundState: clearState ? null : normalizeState(roundState ?? this.roundState),
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
      message: nextMessage,
      messageStatus: hasMessageText(nextMessage)
          ? normalizeStatus(messageStatus ?? this.messageStatus)
          : null,
    );
  }

  /// `''` / 空白视为「无父」（根），统一为 `null`，避免 `IS NULL` 与 `= ''` 两套语义。
  static String? normalizeFather(String? raw) {
    final value = raw?.trim() ?? '';
    return value.isEmpty ? null : value;
  }

  /// `round_state` 白名单：`'use'`（选中记忆）/ `'failed'`（失败占位代）/ null（闲置）；
  /// 其它脏值一律按闲置处理。
  static String? normalizeState(String? raw) {
    final value = raw?.trim() ?? '';
    if (value == 'use') return 'use';
    if (value == 'failed') return 'failed';
    return null;
  }

  /// 提示文本是否非空（`null` / 纯空白 = 无提示）。
  static bool hasMessageText(String? raw) => raw != null && raw.trim().isNotEmpty;

  /// 提示文本的写入上限：超长提示会拖慢 B-tree 与云端快照，写入侧统一截断。
  static const int maxMessageLength = 4000;

  /// 写入侧归一化：超过 [maxMessageLength] 的部分丢弃并以省略号收尾。
  static String clampMessage(String raw) => raw.length <= maxMessageLength
      ? raw
      : '${raw.substring(0, maxMessageLength)}…';

  /// 提示级别白名单：`'info'` / `'warning'` / `'error'`（大小写与空白宽容）；
  /// 其余（含 `''`、`'success'`、任意脏值）= `null`（无级别）。
  static String? normalizeStatus(Object? raw) {
    if (raw is! String) return null;
    final value = raw.trim().toLowerCase();
    if (value == 'info' || value == 'warning' || value == 'error') return value;
    return null;
  }

  /// 提示文本的展示行（按 `\n` 拆分，丢弃空白行）。
  static List<String> messageLines(String raw) => [
        for (final line in raw.split('\n'))
          if (line.trim().isNotEmpty) line.trim(),
      ];

  /// epoch 毫秒 → [DateTime]；`0` / 非正整数视为无时间戳。
  static DateTime? decodeTime(Object? raw) {
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

  /// 是否「失败占位代」（只带提示、不参与活动链与代次控件）。
  bool get isFailed => roundState == 'failed';

  factory RoundStackMeta.fromMap(Map<String, Object?> map) {
    return RoundStackMeta(
      uuid: (map['uuid'] as String?) ?? '',
      bookUuid: (map['book_uuid'] as String?) ?? '',
      fatherUuid: RoundStackRow.normalizeFather(map['father_uuid'] as String?),
      roundIndex: (map['round_index'] as int?) ?? 0,
      roundSerialNum: (map['round_serial_num'] as int?) ?? 0,
      roundState: RoundStackRow.normalizeState(map['round_state'] as String?),
      roundCreatedAt: RoundStackRow.decodeTime(map['round_created_at']),
    );
  }
}

/// `round_stack` 上的一条「代级提示」（`message` / `message_status` 的最小投影）。
///
/// 提示是「代」的附注：随代持久化、随代云同步、随代删除；`books.failed_*`
/// 仍保留一份失败条目（旧版兼容），新版本一切提示以本类型所读的库列为准。
class RoundStackMessage {
  /// 所属代的 uuid（= `round_stack.uuid`）。
  final String uuid;

  /// 所属轮号。
  final int roundIndex;

  /// 是否「失败占位代」（`round_state = 'failed'`）：该轮本该产生却生成失败。
  final bool isFailure;

  /// 提示文本（多行用 `\n` 合并）。
  final String text;

  /// 级别：`'info'` / `'warning'` / `'error'`；`null` = 无级别。
  final String? status;

  const RoundStackMessage({
    required this.uuid,
    required this.roundIndex,
    this.isFailure = false,
    required this.text,
    this.status,
  });

  /// 展示行（按 `\n` 拆分、去空白行）。
  List<String> get lines => RoundStackRow.messageLines(text);

  factory RoundStackMessage.fromMap(Map<String, Object?> map) {
    final text = (map['message'] as String?) ?? '';
    return RoundStackMessage(
      uuid: (map['uuid'] as String?) ?? '',
      roundIndex: (map['round_index'] as int?) ?? 0,
      isFailure: RoundStackRow.normalizeState(map['round_state'] as String?) ==
          'failed',
      text: text,
      status: RoundStackRow.hasMessageText(text)
          ? RoundStackRow.normalizeStatus(map['message_status'])
          : null,
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
