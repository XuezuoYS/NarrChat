import 'dart:convert';

import '../utils/timestamp_format.dart';

/// 提示级别白名单。
///
/// 文档约定：`''` 一律按 `info` 处理；脏值同样按 `info` 处理，避免 UI 拿到
/// 未知级别后既不敢显示又不敢忽略。
class RoundMessageStatus {
  RoundMessageStatus._();

  static const String info = 'info';
  static const String warning = 'warning';
  static const String error = 'error';

  /// 归一化级别：只认 `info` / `warning` / `error`，其余（含空串）落到 `info`。
  static String normalize(Object? raw) {
    final value = (raw is String ? raw : '').trim().toLowerCase();
    if (value == warning || value == error) return value;
    return info;
  }

  static bool isError(Object? raw) => normalize(raw) == error;
}

/// 一代的**元信息**（轻量索引）：不含任何正文列。
///
/// 全书几千轮也只需这一个列表就能算出活动链、进度与跳转目标，
/// 因此它是列表 / 轨道 / 窗口化三处的共同数据基础。
class RoundMeta {
  const RoundMeta({
    required this.uuid,
    this.fatherUuid,
    this.branchUuid = '',
    required this.roundIndex,
    required this.roundSerialNum,
    required this.isUsing,
    required this.operatedAt,
    this.messageStatus = '',
    this.message = '',
    this.hasImages = false,
  });

  /// 本代身份（跨设备稳定，参与同步摘要）。
  final String uuid;

  /// 上一轮**当时活动代**的 uuid；`null` = 链首（分支头 / 根）。
  final String? fatherUuid;

  /// 所属分支；`''` = 默认分支。
  final String branchUuid;

  /// 本代所属轮号（从根算的全局深度）。
  final int roundIndex;

  /// 本组内第 X 代（可跳步；物理删除后允许复用）。
  final int roundSerialNum;

  /// 组内是否当前选中。
  final bool isUsing;

  /// 创建时间；用户手动编辑时刷新。不参与云备份摘要。
  final DateTime operatedAt;

  /// 原始级别文本（未归一化，摘要与调试要看原值）。
  final String messageStatus;

  /// 提示文本；空 = 不显示提示框。
  final String message;

  /// 本轮任一方向是否带图片（只用于进度估算与气泡占位，不参与身份）。
  final bool hasImages;

  bool get isRoot => fatherUuid == null || fatherUuid!.isEmpty;

  bool get isError => RoundMessageStatus.isError(messageStatus);

  String get effectiveMessageStatus => RoundMessageStatus.normalize(messageStatus);

  bool get hasMessage => message.trim().isNotEmpty;

  /// 解析轻量行。`has_images` 可以由 SQL 直接算（推荐），缺列时按图片列兜底。
  factory RoundMeta.fromRow(Map<String, Object?> row) {
    final hasImagesRaw = row['has_images'];
    final hasImages = hasImagesRaw is int
        ? hasImagesRaw != 0
        : _nonEmptyJsonArray(row['user_images']) ||
            _nonEmptyJsonArray(row['ai_images']);
    final father = row['father_uuid'] as String?;
    return RoundMeta(
      uuid: (row['uuid'] as String?) ?? '',
      fatherUuid: (father == null || father.isEmpty) ? null : father,
      branchUuid: (row['branch_uuid'] as String?) ?? '',
      roundIndex: (row['round_index'] as int?) ?? 0,
      roundSerialNum: (row['round_serial_num'] as int?) ?? 0,
      isUsing: ((row['is_using'] as int?) ?? 0) != 0,
      operatedAt: parseTimestampOr(row['operated_at'], DateTime.now().toUtc()),
      messageStatus: (row['message_status'] as String?) ?? '',
      message: (row['message'] as String?) ?? '',
      hasImages: hasImages,
    );
  }

  /// 轻量索引查询的列清单（唯一来源，避免各处漏列 / 多读正文）。
  ///
  /// `has_images` 用 SQL 直接算，省掉逐行 JSON 解析。
  static const String metaColumns = '''
      uuid, father_uuid, branch_uuid, round_index, round_serial_num,
      is_using, operated_at, message_status, message,
      (CASE WHEN (user_images <> '[]' AND user_images <> '')
              OR (ai_images <> '[]' AND ai_images <> '')
            THEN 1 ELSE 0 END) AS has_images''';

  /// 元信息列（可直接写回 / 比对摘要）。
  Map<String, Object?> toRow() {
    return {
      'uuid': uuid,
      'father_uuid': fatherUuid,
      'branch_uuid': branchUuid,
      'round_index': roundIndex,
      'round_serial_num': roundSerialNum,
      'is_using': isUsing ? 1 : 0,
      'operated_at': formatTimestamp(operatedAt),
      'message_status': messageStatus,
      'message': message,
    };
  }

  RoundMeta copyWith({
    String? fatherUuid,
    bool clearFather = false,
    String? branchUuid,
    int? roundIndex,
    int? roundSerialNum,
    bool? isUsing,
    DateTime? operatedAt,
    String? messageStatus,
    String? message,
    bool? hasImages,
  }) {
    return RoundMeta(
      uuid: uuid,
      fatherUuid: clearFather ? null : (fatherUuid ?? this.fatherUuid),
      branchUuid: branchUuid ?? this.branchUuid,
      roundIndex: roundIndex ?? this.roundIndex,
      roundSerialNum: roundSerialNum ?? this.roundSerialNum,
      isUsing: isUsing ?? this.isUsing,
      operatedAt: operatedAt ?? this.operatedAt,
      messageStatus: messageStatus ?? this.messageStatus,
      message: message ?? this.message,
      hasImages: hasImages ?? this.hasImages,
    );
  }
}

/// 一代的**完整数据**：元信息 + 正文。
///
/// 正文只在内容窗口里读取；界面上的一轮 = 当前活动链上的某一代。
class RoundGeneration {
  const RoundGeneration({
    required this.meta,
    this.modelName = '',
    this.tokensIn,
    this.tokensCachedIn,
    this.tokensOut,
    this.rawResponse = '',
    this.userInput = '',
    this.aiNarrative = '',
    this.worldState = '',
    this.characterState = '',
    this.memorySummary = '',
    this.currentTime = '',
    this.recommendedAction = '',
    this.userImages = const [],
    this.aiImages = const [],
  });

  final RoundMeta meta;

  String get uuid => meta.uuid;
  String? get fatherUuid => meta.fatherUuid;
  String get branchUuid => meta.branchUuid;
  int get roundIndex => meta.roundIndex;
  int get roundSerialNum => meta.roundSerialNum;
  bool get isUsing => meta.isUsing;
  DateTime get operatedAt => meta.operatedAt;

  final String modelName;

  /// Token 用量：`null` = 无数据，`0` = 真实 0。
  final int? tokensIn;
  final int? tokensCachedIn;
  final int? tokensOut;

  /// AI 返回原文（当前解析后恒为空，为将来失败保留原文预留）。
  final String rawResponse;

  final String userInput;
  final String aiNarrative;
  final String worldState;
  final String characterState;
  final String memorySummary;
  final String currentTime;
  final String recommendedAction;
  final List<String> userImages;
  final List<String> aiImages;

  /// 正文列（唯一来源）：不含身份、轮号、组内序号、时间与提示。
  ///
  /// 编辑 / 云备份摘要 / 迁移比对都按同一字段集，避免三处列清单漂移。
  Map<String, Object?> contentRow() {
    return {
      'model_name': modelName,
      'tokens_in': tokensIn,
      'tokens_cached_in': tokensCachedIn,
      'tokens_out': tokensOut,
      'raw_response': rawResponse,
      'user_input': userInput,
      'ai_narrative': aiNarrative,
      'world_state': worldState,
      'character_state': characterState,
      'memory_summary': memorySummary,
      'current_time': currentTime,
      'recommended_action': recommendedAction,
      'user_images': jsonEncode(userImages),
      'ai_images': jsonEncode(aiImages),
    };
  }

  /// 整行写入。
  Map<String, Object?> toRow() => {...meta.toRow(), ...contentRow()};

  factory RoundGeneration.fromRow(Map<String, Object?> row) {
    return RoundGeneration(
      meta: RoundMeta.fromRow(row),
      modelName: (row['model_name'] as String?) ?? '',
      tokensIn: row['tokens_in'] as int?,
      tokensCachedIn: row['tokens_cached_in'] as int?,
      tokensOut: row['tokens_out'] as int?,
      rawResponse: (row['raw_response'] as String?) ?? '',
      userInput: (row['user_input'] as String?) ?? '',
      aiNarrative: (row['ai_narrative'] as String?) ?? '',
      worldState: (row['world_state'] as String?) ?? '',
      characterState: (row['character_state'] as String?) ?? '',
      memorySummary: (row['memory_summary'] as String?) ?? '',
      currentTime: (row['current_time'] as String?) ?? '',
      recommendedAction: (row['recommended_action'] as String?) ?? '',
      userImages: decodeImageList(row['user_images']),
      aiImages: decodeImageList(row['ai_images']),
    );
  }

  RoundGeneration copyWith({
    RoundMeta? meta,
    String? modelName,
    int? tokensIn,
    bool clearTokensIn = false,
    int? tokensCachedIn,
    bool clearTokensCachedIn = false,
    int? tokensOut,
    bool clearTokensOut = false,
    String? rawResponse,
    String? userInput,
    String? aiNarrative,
    String? worldState,
    String? characterState,
    String? memorySummary,
    String? currentTime,
    String? recommendedAction,
    List<String>? userImages,
    List<String>? aiImages,
  }) {
    return RoundGeneration(
      meta: meta ?? this.meta,
      modelName: modelName ?? this.modelName,
      tokensIn: clearTokensIn ? null : (tokensIn ?? this.tokensIn),
      tokensCachedIn:
          clearTokensCachedIn ? null : (tokensCachedIn ?? this.tokensCachedIn),
      tokensOut: clearTokensOut ? null : (tokensOut ?? this.tokensOut),
      rawResponse: rawResponse ?? this.rawResponse,
      userInput: userInput ?? this.userInput,
      aiNarrative: aiNarrative ?? this.aiNarrative,
      worldState: worldState ?? this.worldState,
      characterState: characterState ?? this.characterState,
      memorySummary: memorySummary ?? this.memorySummary,
      currentTime: currentTime ?? this.currentTime,
      recommendedAction: recommendedAction ?? this.recommendedAction,
      userImages: userImages ?? this.userImages,
      aiImages: aiImages ?? this.aiImages,
    );
  }
}

/// 解析图片相对路径 JSON 数组；非法 / 空视为无图片。
List<String> decodeImageList(Object? raw) {
  if (raw is! String || raw.isEmpty) return const [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      return decoded.map((e) => e.toString()).toList();
    }
  } catch (_) {
    // 非法 JSON 视为空，不让一行脏数据炸掉整个列表。
  }
  return const [];
}

bool _nonEmptyJsonArray(Object? raw) {
  if (raw is! String || raw.isEmpty) return false;
  final trimmed = raw.trim();
  return trimmed != '[]' && trimmed != '';
}
