import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/providers/cloud_sync_provider.dart';
import 'package:narrchat/services/sync/sync_models.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/sync_result_bubble.dart';
import 'package:provider/provider.dart';

/// 应用级云同步结果悬浮气泡测试：
/// - 成功 / 取消类：悬浮 2 秒后自动消失，无关闭按钮；
/// - 失败类：驻留等待用户点击「关闭」，内容可复制（SelectableText）；
/// - 多条目堆叠与逐个关闭；
/// - 任一平面同步中（与同步 HUD 同时可见）时下移一排避让。
void main() {
  Future<CloudSyncProvider> pumpBubble(
    WidgetTester tester, {
    Size size = const Size(1400, 900),
    bool dataSyncing = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final provider = CloudSyncProvider();
    if (dataSyncing) {
      provider.debugSetSyncState(SyncPlane.data, SyncState.syncing);
    }
    await tester.pumpWidget(
      MultiProvider(
        providers: [ChangeNotifierProvider.value(value: provider)],
        child: MaterialApp(
          theme: NarrChatTheme.light,
          home: const Scaffold(body: SizedBox.expand()),
          // 与真实应用一致：HUD / 气泡位于 Navigator 之上，需要独立 Overlay。
          builder: (context, child) => Overlay(
            initialEntries: [
              OverlayEntry(
                builder: (_) => Stack(
                  fit: StackFit.expand,
                  children: [
                    child ?? const SizedBox.shrink(),
                    const SyncResultBubble(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    return provider;
  }

  testWidgets('成功提示：内容可复制（SelectableText），悬浮 2 秒后自动消失', (tester) async {
    final provider = await pumpBubble(tester);
    expect(find.byType(SelectableText), findsNothing, reason: '无提示时不占位');

    provider.showSyncResult('云端记录 #3：数据已同步');
    await tester.pump();
    // 内容以 SelectableText 呈现（可长按选择复制）。
    expect(find.byType(SelectableText), findsOneWidget);
    expect(find.text('云端记录 #3：数据已同步'), findsOneWidget);
    expect(find.byTooltip('关闭'), findsNothing, reason: '成功提示无需关闭按钮');

    // 悬浮 2 秒后自动消失。
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.text('云端记录 #3：数据已同步'), findsNothing);
  });

  testWidgets('失败提示：驻留等待用户点击「关闭」，内容可复制', (tester) async {
    final provider = await pumpBubble(tester);
    provider.showSyncResult(
      '图片同步：连接超时（HTTP 408）',
      kind: SyncToastKind.error,
    );
    await tester.pump();

    expect(find.byType(SelectableText), findsOneWidget);
    expect(find.text('图片同步：连接超时（HTTP 408）'), findsOneWidget);
    expect(find.byTooltip('关闭'), findsOneWidget);

    // 驻留：远超自动消失时长（10s）后仍不消失。
    await tester.pump(const Duration(seconds: 10));
    expect(find.text('图片同步：连接超时（HTTP 408）'), findsOneWidget);

    // 手动关闭。
    await tester.tap(find.byTooltip('关闭'));
    await tester.pump();
    expect(find.text('图片同步：连接超时（HTTP 408）'), findsNothing);
  });

  testWidgets('多条结果纵向堆叠，关闭其中一条不影响其它条目', (tester) async {
    final provider = await pumpBubble(tester);
    provider.showSyncResult('已取消数据同步', kind: SyncToastKind.info);
    provider.showSyncResult(
      '图片同步：连接超时（HTTP 408）',
      kind: SyncToastKind.error,
    );
    await tester.pump();
    expect(find.byType(SelectableText), findsNWidgets(2));
    expect(find.byTooltip('关闭'), findsOneWidget);

    await tester.tap(find.byTooltip('关闭'));
    await tester.pump();
    expect(find.text('图片同步：连接超时（HTTP 408）'), findsNothing);
    expect(find.text('已取消数据同步'), findsOneWidget);
  });

  testWidgets('同步进行中（与 HUD 同时可见）时结果气泡下移一排避让', (tester) async {
    final provider = await pumpBubble(tester, dataSyncing: true);
    provider.showSyncResult(
      '数据同步失败：无法连接服务器',
      kind: SyncToastKind.error,
    );
    await tester.pump();

    final toastTop = tester.getTopLeft(find.text('数据同步失败：无法连接服务器')).dy;
    // 默认位（标题栏下方 + 8）之上再下移 44 避让同步 HUD。
    expect(
      toastTop,
      greaterThanOrEqualTo(kToolbarHeight + 8 + 44 + 4),
      reason: '任一平面同步中时结果气泡下移一排，避免遮挡同步 HUD',
    );
  });

  testWidgets('同步空闲时结果气泡位于默认位（标题栏下方）', (tester) async {
    final provider = await pumpBubble(tester);
    provider.showSyncResult('数据同步失败：无法连接服务器', kind: SyncToastKind.error);
    await tester.pump();

    final toastTop = tester.getTopLeft(find.text('数据同步失败：无法连接服务器')).dy;
    expect(toastTop, lessThan(kToolbarHeight + 8 + 40),
        reason: '空闲时气泡停在默认位，不下移');
  });
}
