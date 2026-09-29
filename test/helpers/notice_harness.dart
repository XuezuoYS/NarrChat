import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/app_notice_center.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/app_notice_overlay.dart';
import 'package:narrchat/widgets/floating_notice_host.dart';
import 'package:provider/provider.dart';

/// 应用内通知宿主的公共测试脚手架。
///
/// - [floatingNoticeBuilder]：只挂悬浮渠道（页面级测试用，不依赖云同步 / 生成 Provider）；
/// - [noticeHostBuilder]：挂悬浮 + 驻场岛（需上层已提供 CloudSync / Round / Book Provider）；
/// - [pumpNoticeApp]：pump 一个最小宿主应用并返回注入的 [AppNoticeCenter]。

/// `MaterialApp.builder`：仅挂悬浮渠道。
///
/// [textScale] 非 1.0 时额外套一层全局字体缩放（等价生产 main.dart 的接线顺序）。
Widget Function(BuildContext, Widget?) floatingNoticeBuilder({
  AppNoticeCenter? center,
  double textScale = 1.0,
}) {
  return (context, child) {
    final host = AppNoticeOverlay(
      center: center,
      pinnedIsland: false,
      child: child ?? const SizedBox.shrink(),
    );
    if (textScale == 1.0) return host;
    return MediaQuery.withClampedTextScaling(
      minScaleFactor: textScale,
      maxScaleFactor: textScale,
      child: host,
    );
  };
}

/// `MaterialApp.builder`：悬浮渠道 + 驻场岛。
///
/// 前置条件：上层已提供 `CloudSyncProvider` / `RoundProvider` / `BookProvider`
/// （`pumpChatScreen`、`pumpHomeScreen` 等脚手架已默认提供）。
Widget Function(BuildContext, Widget?) noticeHostBuilder({
  void Function(String bookUuid)? onOpenBook,
  AppNoticeCenter? center,
  double textScale = 1.0,
}) {
  return (context, child) {
    final host = AppNoticeOverlay(
      center: center,
      onOpenBook: onOpenBook ?? (_) {},
      child: child ?? const SizedBox.shrink(),
    );
    if (textScale == 1.0) return host;
    return MediaQuery.withClampedTextScaling(
      minScaleFactor: textScale,
      maxScaleFactor: textScale,
      child: host,
    );
  };
}

/// 走完悬浮通知的进入动画。
///
/// [FloatingNoticeHost] 的动画由 [AnimationController] 驱动：ticker 的首次 tick
/// elapsed 恒为 0（只用于确立起点），因此构建后需再推一帧才看到进度。
Future<void> settleNoticeEnter(WidgetTester tester) async {
  await tester.pump(); // 构建卡片并启动 ticker
  await tester.pump(AppNoticeCenter.enterDuration); // 首次 tick（elapsed 0）
  await tester.pump(AppNoticeCenter.enterDuration); // 进入动画完成
}

/// 走完悬浮通知的消失动画（1s），并让宿主完成移除。
Future<void> settleNoticeExit(WidgetTester tester) async {
  await tester.pump(AppNoticeCenter.exitDuration);
  await tester.pump(AppNoticeCenter.exitDuration);
  await tester.pump();
}

/// 清空通知中心：取消驻留 / 兜底定时器，避免 `testWidgets` 结束时报「悬挂定时器」。
///
/// 用例若未把提示自然走完（3s 驻留 + 1s 退出），须在结束前调用一次并 `pump()`。
void drainNotices(AppNoticeCenter center) => center.reset();

/// 当前树上的通知中心（页面用例收尾 / 额外断言用）。
AppNoticeCenter noticeCenterOf(WidgetTester tester) =>
    Provider.of<AppNoticeCenter>(
      tester.element(find.byType(FloatingNoticeHost)),
      listen: false,
    );

/// 收尾：清空通知中心（取消驻留 / 兜底定时器），避免 `testWidgets` 报「悬挂定时器」。
///
/// 只断言提示文案、不关心时序的页面用例，在结尾调用一次即可。
Future<void> flushNotices(WidgetTester tester) async {
  noticeCenterOf(tester).reset();
  await tester.pump();
}

/// pump 一个最小宿主应用（仅悬浮渠道），返回可断言的通知中心。
Future<AppNoticeCenter> pumpNoticeApp(
  WidgetTester tester, {
  Size size = const Size(1400, 900),
  Widget? home,
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final center = AppNoticeCenter();
  addTearDown(center.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: NarrChatTheme.light,
      builder: floatingNoticeBuilder(center: center, textScale: textScale),
      home: home ?? const Scaffold(body: SizedBox.expand()),
    ),
  );
  await tester.pump();
  return center;
}
