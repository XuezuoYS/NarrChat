/// 应用内通知的类型（决定图标、颜色与驻留时长）。
///
/// 悬浮渠道与驻场岛共用同一枚举：云同步结果原有的 `SyncToastKind`
/// 已被本枚举取代（`success` / `info` / `error` 语义一一对应）。
enum NoticeKind {
  /// 中性提示（已取消、已复制等）。
  info,

  /// 成功 / 完成类提示。
  success,

  /// 需要用户注意但非失败（校验不通过、未获取到数据等）。
  warning,

  /// 失败类提示（保存失败、同步失败、请求失败等）。
  error;

  /// 驻场岛里结果条目的自动撤销时长（到点无条件移除；[error] 另提供「已读」提前收起）。
  ///
  /// 悬浮渠道不使用本值：悬浮通知统一「常驻 3 秒 + 消失动画 1 秒」，
  /// 仅由调用点显式传入的 `dwell` 覆盖（见 `AppNotice.dwell`）。
  Duration get dwell => switch (this) {
    NoticeKind.info => const Duration(seconds: 3),
    NoticeKind.success => const Duration(seconds: 3),
    NoticeKind.warning => const Duration(seconds: 5),
    NoticeKind.error => const Duration(seconds: 15),
  };
}

/// 一条悬浮通知（[AppNoticeCenter] 的队列条目）。
///
/// 只承载「短提示」：内容在窗口正中半透明悬浮，进入 200ms → 驻留 `dwell`
/// → 退出 1000ms；点击 / 按住划过可提前进入退出动画。
class AppNotice {
  const AppNotice({
    required this.id,
    required this.message,
    required this.kind,
    required this.dwell,
    this.copyable = false,
  });

  /// 队列内唯一标识（去重定位、宿主回调 `completeDismissal` 均以它为准）。
  final int id;

  /// 提示文案（可多行）。
  final String message;

  /// 提示类型（图标与颜色）。
  final NoticeKind kind;

  /// 驻留时长（从进入动画结束算起）。
  final Duration dwell;

  /// 是否以 [SelectableText] 呈现（长文案 / 需复制的报错详情），
  /// 并为该条常显「关闭」按钮（选择手势与点击消失冲突，故不依赖点击消失）。
  final bool copyable;
}
