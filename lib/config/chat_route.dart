/// 对话页路由名：用于 [NavigatorObserver] 识别「当前栈顶是否为某本书的对话页」。
///
/// 推送 [ChatScreen] 时统一通过 `RouteSettings(name: chatRouteName, arguments: bookId)`
/// 标记；通知服务据此判断「用户是否正在查看某本书的 chat 页」，从而决定是否弹出/
/// 删除生成完成系统通知。
const String chatRouteName = '/chat';
