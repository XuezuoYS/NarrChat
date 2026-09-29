import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/app_notice.dart';
import 'package:narrchat/services/app_notice_center.dart';
import 'package:narrchat/widgets/floating_notice_host.dart';
import 'package:narrchat/widgets/notice_visuals.dart';

import 'helpers/notice_harness.dart';

/// 悬浮通知渠道（[FloatingNoticeHost]）的 widget 测试：
/// 窗口正中半透明、200ms 进 / 3s 驻 / 1s 出、点击与按住划过提前消失、
/// 鼠标悬停不触发、单槽位排队与去重、窄屏可查阅。
void main() {
  testWidgets('无通知时不占位', (tester) async {
    final center = await pumpNoticeApp(tester);
    expect(center.current, isNull);
    expect(
      find.descendant(
        of: find.byType(FloatingNoticeHost),
        matching: find.byType(Material),
      ),
      findsNothing,
    );
  });

  testWidgets('统一黑底白字 + 真正半透明：黑色半透明卡片 + 浅色字体', (tester) async {
    final center = await pumpNoticeApp(tester);
    center.show('已复制');
    await settleNoticeEnter(tester);

    final card = find
        .ancestor(of: find.text('已复制'), matching: find.byType(Material))
        .first;
    final color = tester.widget<Material>(card).color!;
    expect(
      color.a,
      lessThanOrEqualTo(0.85),
      reason: '半透明：能透出下方页面内容（此前 0.92 近乎不透明）',
    );
    expect((color.r + color.g + color.b) / 3, lessThan(0.15), reason: '统一黑底');
    final text = tester.widget<Text>(find.text('已复制'));
    expect(text.style?.color, kNoticeTextPrimary, reason: '统一浅色（白色）字体');
    drainNotices(center);
    await tester.pump();
  });

  testWidgets('窗口正中 + 半透明：驻留 3s 后进入 1s 消失动画', (tester) async {
    final center = await pumpNoticeApp(tester);
    center.show('已复制');
    await settleNoticeEnter(tester);

    expect(find.text('已复制'), findsOneWidget);
    final card = find
        .ancestor(of: find.text('已复制'), matching: find.byType(Material))
        .first;
    // 半透明背景（alpha < 1）。
    expect(tester.widget<Material>(card).color!.a, lessThan(1.0));
    // 水平 / 垂直居中（窗口正中）。
    final cardCenter = tester.getCenter(card);
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(cardCenter.dx, closeTo(screen.width / 2, 2));
    expect(cardCenter.dy, closeTo(screen.height / 2, 2));

    // 未到驻留时长：不消失。
    await tester.pump(const Duration(seconds: 2));
    expect(center.isExiting, isFalse);
    expect(find.text('已复制'), findsOneWidget);

    // 到点：进入退出动画（1s 内仍在树上）。
    await tester.pump(const Duration(seconds: 1));
    expect(center.isExiting, isTrue);
    expect(find.text('已复制'), findsOneWidget);

    // 退出动画播完：移除。
    await settleNoticeExit(tester);
    expect(center.current, isNull);
    expect(find.text('已复制'), findsNothing);
  });

  testWidgets('点击 → 提前进入消失动画', (tester) async {
    final center = await pumpNoticeApp(tester);
    center.show('已保存');
    await settleNoticeEnter(tester);

    await tester.tap(find.text('已保存'));
    expect(center.isExiting, isTrue);

    await settleNoticeExit(tester);
    expect(find.text('已保存'), findsNothing);
  });

  testWidgets('按住划过（拖动）→ 提前进入消失动画', (tester) async {
    final center = await pumpNoticeApp(tester);
    center.show('已保存');
    await settleNoticeEnter(tester);

    await tester.drag(find.text('已保存'), const Offset(40, 0));
    expect(center.isExiting, isTrue, reason: '按住滑动触控 / 鼠标划过即提前消失');

    await settleNoticeExit(tester);
    expect(find.text('已保存'), findsNothing);
  });

  testWidgets('鼠标悬停不触发消失', (tester) async {
    final center = await pumpNoticeApp(tester);
    center.show('提示');
    await settleNoticeEnter(tester);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.text('提示')));
    await tester.pump();

    expect(center.isExiting, isFalse, reason: '划过不等于点击，悬停不进入消失动画');
    expect(find.text('提示'), findsOneWidget);

    drainNotices(center);
    await tester.pump();
  });

  testWidgets('单槽位排队：一次只显示一条，前一条消失后显示下一条', (tester) async {
    final center = await pumpNoticeApp(tester);
    center.show('第一条');
    center.show('第二条');
    await tester.pump();

    expect(find.text('第一条'), findsOneWidget);
    expect(find.text('第二条'), findsNothing);

    // 第一条走完整个生命周期。
    await tester.pump(AppNoticeCenter.enterDuration + AppNoticeCenter.defaultDwell);
    await settleNoticeExit(tester);
    expect(find.text('第一条'), findsNothing);

    // 第二条接着显示。
    await settleNoticeEnter(tester);
    expect(find.text('第二条'), findsOneWidget);
    drainNotices(center);
    await tester.pump();
  });

  testWidgets('同文案去重：连点复制只显示一条', (tester) async {
    final center = await pumpNoticeApp(tester);
    center.show('已复制 UUID');
    await tester.pump();
    center.show('已复制 UUID');
    await tester.pump();

    expect(find.text('已复制 UUID'), findsOneWidget);
    expect(center.pendingCount, 0, reason: '同文案不叠加为第二条');
    drainNotices(center);
    await tester.pump();
  });

  testWidgets('窄屏：长文案换行可查阅且不溢出', (tester) async {
    final center = await pumpNoticeApp(tester, size: const Size(320, 640));
    const message = '导出失败：连接超时（HTTP 408），请检查网络后重试，或稍后在设置页重新导出';
    center.show(message, kind: NoticeKind.error);
    await settleNoticeEnter(tester);

    expect(tester.takeException(), isNull);
    expect(find.text(message), findsOneWidget);
    final box = tester.getSize(find.text(message));
    expect(box.width, lessThanOrEqualTo(320), reason: '窄屏按窗口宽 - 24 换行');
    drainNotices(center);
    await tester.pump();
  });

  testWidgets('长文案（copyable）以可选中文本呈现并恒显关闭按钮', (tester) async {
    final center = await pumpNoticeApp(tester);
    center.show('数据同步失败：无法连接服务器', kind: NoticeKind.error, copyable: true);
    await settleNoticeEnter(tester);

    expect(find.byType(SelectableText), findsOneWidget);
    expect(find.byTooltip('关闭'), findsOneWidget);

    await tester.tap(find.byTooltip('关闭'));
    expect(center.isExiting, isTrue);
    await settleNoticeExit(tester);
    expect(find.byType(SelectableText), findsNothing);
  });

  testWidgets('dwell 覆盖：短驻留提示按传入时长消失', (tester) async {
    final center = await pumpNoticeApp(tester);
    center.show('已复制', dwell: const Duration(seconds: 1));
    await settleNoticeEnter(tester);

    await tester.pump(const Duration(seconds: 1));
    expect(center.isExiting, isTrue);
    drainNotices(center);
    await tester.pump();
  });
}
