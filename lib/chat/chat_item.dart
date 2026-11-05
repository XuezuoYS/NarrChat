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
  });

  /// 轮 uuid；分支头条目用分支 uuid。
  final String roundUuid;

  /// 全局轮号（进度与跳转都用它）。
  final int roundIndex;

  final ChatItemKind kind;

  /// 是否带图片（图片高度不确定，估算时给更高的初值）。
  final bool hasImages;

  /// 所属分支（分支头条目必填）。
  final String branchUuid;

  ChatItemKey get key => ChatItemKey(roundUuid, kind);

  @override
  String toString() => 'ChatItem($key, index=$roundIndex)';
}
