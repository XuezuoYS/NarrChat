/// 书籍的「失败条目」：最近一次未完成的生成尝试（请求失败或用户中断）。
///
/// 仅持久化两项数据——用户输入与错误信息；成功生成 / 重新提问 / 继续提问
/// 都会将其清空，失败则重新填入。它不是轮次，不参与历史上下文与轮次编号。
class FailedAttempt {
  final String userInput;
  final String errorMessage;

  const FailedAttempt({this.userInput = '', this.errorMessage = ''});

  /// 是否存在未完成的尝试（用户输入为空即视为无失败条目）。
  bool get isEmpty => userInput.trim().isEmpty;

  /// 是否因用户主动中断而「已截断」（错误信息为空即视为中断）。
  bool get isTruncated => !isEmpty && errorMessage.trim().isEmpty;

  FailedAttempt copyWith({String? userInput, String? errorMessage}) {
    return FailedAttempt(
      userInput: userInput ?? this.userInput,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}
