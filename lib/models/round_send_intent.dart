/// 一次「若此刻点击发送」的发送意图。
///
/// 由界面按**当前状态**构造（普通新一轮，或输入卡灰条的一次临时用途），交给
/// `RoundProvider`：
/// - 实发：`RoundProvider.sendIntent` 按它组装并发送；
/// - 预览：`RoundProvider.previewRequestBody` 按**同一份意图 + 同一套组装**给出
///   真实会发出的请求体。
///
/// 意图只描述「这次要做什么」，**不携带任何预先拼好的请求字段**：提示词、历史、
/// 世界书、图片、参数与请求体全部由 Provider 依当前状态现算。界面与预览因此
/// 不可能各自漂移——灰条用途改了、历史被截断了、档位换了，预览跟着同步变。
enum RoundSendKind {
  /// 普通发送新一轮（也用于失败条目的「修改并重新提问」：失败条目不是轮次，
  /// 不截断投影）。
  newRound,

  /// 从某一轮起重来：先删除该轮起的投影行，再按修改后的输入在同轮号生成
  /// （「刷新本轮」「修改并重新提问」）。
  ///
  /// 请求 = **截断后**投影上的新一轮请求（见 [RoundProvider.sendIntent]），
  /// 因此 [targetRoundIndex] 必须指向当前投影里仍存在的轮次。
  reaskRound,

  /// 按意见重写某一轮（AI 气泡「按意见修改」）：同轮号**新增一代**，
  /// 用户输入与原图沿用被重写轮，意见与附带图片只进请求（不落库）。
  rewriteByOpinion,
}

/// 发送意图（值对象；见 [RoundSendKind] 的语义）。
///
/// 三个命名构造器对应三种用途，字段取用规则由 [kind] 决定：
/// | 用途 | 用户输入 | 图片 | 意见 |
/// |---|---|---|---|
/// | [newRound] | [userInput] | [images] | — |
/// | [reaskRound] | [userInput]（改后的输入） | [images] | — |
/// | [rewriteByOpinion] | 被重写轮的原值（Provider 现取） | 被重写轮的原图 | [opinion] + [images] |
class RoundSendIntent {
  /// 普通发送新一轮。
  const RoundSendIntent.newRound({
    required this.userInput,
    this.images = const [],
  })  : kind = RoundSendKind.newRound,
        targetRoundIndex = null,
        opinion = '';

  /// 「刷新本轮 / 修改并重新提问」：截断 [targetRoundIndex] 起的投影后重发。
  const RoundSendIntent.reaskRound({
    required this.targetRoundIndex,
    required this.userInput,
    this.images = const [],
  })  : kind = RoundSendKind.reaskRound,
        opinion = '';

  /// 「按意见修改」：以 [opinion] 重写 [targetRoundIndex] 指向的那一轮。
  ///
  /// [images] 是意见附带的图片（仅本次请求，不落库）；被重写轮自身的输入与原图
  /// 由 Provider 从当前投影现取（与落库一致）。
  const RoundSendIntent.rewriteByOpinion({
    required this.targetRoundIndex,
    required this.opinion,
    this.images = const [],
  })  : kind = RoundSendKind.rewriteByOpinion,
        userInput = '';

  final RoundSendKind kind;

  /// 目标轮号（[RoundSendKind.newRound] 为 null）。
  final int? targetRoundIndex;

  /// 主输入框文本（[RoundSendKind.rewriteByOpinion] 下为空，取被重写轮原输入）。
  final String userInput;

  /// 本次提交的待发送图片（[RoundSendKind.rewriteByOpinion] = 意见附图）。
  final List<String> images;

  /// 修改意见（仅 [RoundSendKind.rewriteByOpinion]）。
  final String opinion;

  /// 目标轮号（非空断言；仅 [RoundSendKind.newRound] 之外可用）。
  int get requiredTargetRoundIndex {
    final index = targetRoundIndex;
    if (index == null) {
      throw StateError('该发送意图没有目标轮次：$kind');
    }
    return index;
  }
}
