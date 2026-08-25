/// 书籍的「失败条目」：最近一次未完成的生成尝试（请求失败或用户中断）。
///
/// 持久化用户输入、错误信息与用户消息附带的图片（相对路径）；
/// 成功生成 / 重新提问 / 继续提问都会将其清空，失败则重新填入。
/// 它不是轮次，不参与历史上下文与轮次编号。
class FailedAttempt {
  final String userInput;
  final String errorMessage;

  /// 失败时用户消息附带的图片（相对路径 `img/<hash>.<ext>`，随失败条目落库，
  /// 供失败气泡保留展示与重新提问 / 修改并重新提问时复用）。
  final List<String> userImages;

  const FailedAttempt({
    this.userInput = '',
    this.errorMessage = '',
    this.userImages = const [],
  });

  /// 是否存在未完成的尝试（用户输入为空即视为无失败条目）。
  bool get isEmpty => userInput.trim().isEmpty;

  /// 是否因用户主动中断而「已截断」（错误信息为空即视为中断）。
  bool get isTruncated => !isEmpty && errorMessage.trim().isEmpty;

  /// 是否附带图片。
  bool get hasImages => userImages.isNotEmpty;

  FailedAttempt copyWith({
    String? userInput,
    String? errorMessage,
    List<String>? userImages,
  }) {
    return FailedAttempt(
      userInput: userInput ?? this.userInput,
      errorMessage: errorMessage ?? this.errorMessage,
      userImages: userImages ?? this.userImages,
    );
  }
}
