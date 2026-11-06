/// 聊天阅读区条目的身份与种类。
///
/// 身份 = **轮 + 类型**：切换同轮的其它版本（代）时 Key 不变、内容变，
/// 这样 Element 会被复用，折叠状态、代码块滚动位置都能保住。
/// R2 时代 Key 用的是轮号（`chat-round$index-ai`），切分支会串内容，
/// 所以 R3 一律用轮的 uuid。
enum ChatItemKind {
  /// 分支头提示卡（只有非默认分支才有，排在链的最前面）。
  branchHeader,

  /// 用户气泡。
  user,

  /// AI 气泡。
  ai,

  /// 失败代气泡（红条 + 重试入口）。
  failed,

  /// 窗口化后**列表最底部**的占位条目（视觉底部，`reverse` 下是首个子项）。
  ///
  /// 只有窗口含末轮时才插：它顶替原来 `ListView.padding.bottom` 的作用
  /// （避开悬浮输入面板），让"底部留白"成为**几何模型认识的一等条目**，
  /// 偏移与跳转落点才不会差这一截。
  leadingSpacer,

  /// 窗口化后**列表最顶部**的占位条目（视觉顶部）。
  ///
  /// 只有窗口含首轮时才插，顶替原来 `ListView.padding.top` 的 24dp。
  trailingSpacer,
}

/// 条目稳定身份。
class ChatItemKey {
  const ChatItemKey(this.roundUuid, this.kind);

  /// 所属轮的 uuid（分支头用分支 uuid）。
  final String roundUuid;

  final ChatItemKind kind;

  @override
  bool operator ==(Object other) =>
      other is ChatItemKey &&
      other.roundUuid == roundUuid &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(roundUuid, kind);

  @override
  String toString() => '$roundUuid:${kind.name}';
}

/// 阅读区的一个条目（用户 / AI / 失败 / 分支头）。
///
/// 只放"排版与定位需要知道的东西"，正文在窗口数据里按 [roundUuid] 取。
class ChatItem {
  const ChatItem({
    required this.roundUuid,
    required this.roundIndex,
    required this.kind,
    this.hasImages = false,
    this.branchUuid = '',
    this.fixedHeight,
  });

  /// 轮 uuid；分支头条目用分支 uuid。
  final String roundUuid;

  /// 全局轮号（进度与跳转都用它）。占位条目沿用相邻轮的轮号。
  final int roundIndex;

  final ChatItemKind kind;

  /// 是否带图片（图片高度不确定，估算时给更高的初值）。
  final bool hasImages;

  /// 所属分支（分支头条目必填）。
  final String branchUuid;

  /// 固定高度（占位条目专用）：给了它就不再走估算 / 不再被测量覆盖。
  ///
  /// 占位条目的高度**就是它的语义**（底部避开输入面板、顶部 24dp 收尾），
  /// 被实测值覆盖会让几何与真实布局越走越偏。
  final double? fixedHeight;

  /// 是否是占位条目（高度固定、不参与测量回填）。
  bool get isSpacer =>
      kind == ChatItemKind.leadingSpacer || kind == ChatItemKind.trailingSpacer;

  ChatItemKey get key => ChatItemKey(roundUuid, kind);

  @override
  String toString() => 'ChatItem($key, index=$roundIndex)';
}
