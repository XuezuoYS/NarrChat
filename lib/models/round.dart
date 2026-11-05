import 'dart:convert';

import 'round_generation.dart';

/// 轮次模型，对应数据库 `rounds` 表，通过 [bookUuid] 关联书籍。
class Round {
  /// 本轮自增主键（子表保留 int id，仅本地行标识，不参与同步身份）。
  final int? id;

  /// R3 身份：这一"代"的 uuid（跨设备稳定）。
  ///
  /// 与 [id] 的区别：R2 的 `id` 是投影行号，重建就会变；R3 没有投影表，
  /// 界面上的"一轮"就是活动链上的某一代，身份就是它。
  final String uuid;

  /// 上一轮当时活动代的 uuid；`null` = 链首。
  final String? fatherUuid;

  /// 所属分支；`''` = 默认分支。
  final String branchUuid;

  /// 组内序号（第几代，可跳步）。
  final int roundSerialNum;

  /// 组内是否当前选中。
  final bool isUsing;

  /// 提示级别原始值（`''` 按 info 处理）。
  final String messageStatus;

  /// 提示文本；空 = 不显示提示框。
  final String message;

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
    this.uuid = '',
    this.fatherUuid,
    this.branchUuid = '',
    this.roundSerialNum = 1,
    this.isUsing = true,
    this.messageStatus = '',
    this.message = '',
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

  /// 是否为失败代（`message_status = 'error'`）：不可续写、不可分叉。
  bool get isError => RoundMessageStatus.isError(messageStatus);

  /// 归一化后的提示级别（空串按 info）。
  String get effectiveMessageStatus => RoundMessageStatus.normalize(messageStatus);

  /// 是否带提示框。
  bool get hasMessage => message.trim().isNotEmpty;

  /// 由 R3 的"代"构造界面用的轮次。
  factory Round.fromGeneration(
    RoundGeneration generation, {
    String bookUuid = '',
  }) {
    return Round(
      uuid: generation.uuid,
      fatherUuid: generation.fatherUuid,
      branchUuid: generation.branchUuid,
      roundSerialNum: generation.roundSerialNum,
      isUsing: generation.isUsing,
      messageStatus: generation.meta.messageStatus == ''
          ? RoundMessageStatus.info
          : generation.meta.messageStatus,
      message: generation.meta.message,
      bookUuid: bookUuid,
      roundIndex: generation.roundIndex,
      userInput: generation.userInput,
      aiNarrative: generation.aiNarrative,
      worldState: generation.worldState,
      characterState: generation.characterState,
      memorySummary: generation.memorySummary,
      currentTime: generation.currentTime,
      recommendedAction: generation.recommendedAction,
      tokensIn: generation.tokensIn,
      tokensOut: generation.tokensOut,
      cachedTokensIn: generation.tokensCachedIn,
      modelName: generation.modelName,
      createdAt: generation.operatedAt,
      userImages: generation.userImages,
      aiImages: generation.aiImages,
    );
  }

  /// 回写成 R3 的"代"（分叉快照 / 迁移用）。
  RoundGeneration toGeneration() {
    return RoundGeneration(
      meta: RoundMeta(
        uuid: uuid,
        fatherUuid: fatherUuid,
        branchUuid: branchUuid,
        roundIndex: roundIndex,
        roundSerialNum: roundSerialNum,
        isUsing: isUsing,
        operatedAt: createdAt ?? DateTime.now().toUtc(),
        messageStatus: messageStatus,
        message: message,
      ),
      modelName: modelName,
      tokensIn: tokensIn,
      tokensCachedIn: cachedTokensIn,
      tokensOut: tokensOut,
      userInput: userInput,
      aiNarrative: aiNarrative,
      worldState: worldState,
      characterState: characterState,
      memorySummary: memorySummary,
      currentTime: currentTime,
      recommendedAction: recommendedAction,
      userImages: userImages,
      aiImages: aiImages,
    );
  }

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
    String? uuid,
    String? fatherUuid,
    String? branchUuid,
    int? roundSerialNum,
    bool? isUsing,
    String? messageStatus,
    String? message,
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
      uuid: uuid ?? this.uuid,
      fatherUuid: fatherUuid ?? this.fatherUuid,
      branchUuid: branchUuid ?? this.branchUuid,
      roundSerialNum: roundSerialNum ?? this.roundSerialNum,
      isUsing: isUsing ?? this.isUsing,
      messageStatus: messageStatus ?? this.messageStatus,
      message: message ?? this.message,
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
