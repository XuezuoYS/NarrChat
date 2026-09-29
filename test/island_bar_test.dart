import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/providers/book_provider.dart';
import 'package:narrchat/providers/cloud_sync_provider.dart';
import 'package:narrchat/providers/round_provider.dart';
import 'package:narrchat/services/sync/sync_models.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/app_notice_overlay.dart';
import 'package:narrchat/widgets/island_bar.dart';
import 'package:narrchat/widgets/narr_chat_app_bar.dart';
import 'package:narrchat/widgets/pinned_notice_island.dart';
import 'package:provider/provider.dart';

import 'helpers/fakes.dart';

/// 统一顶栏 × 驻场岛协作测试：
/// - 宽屏：岛收起时嵌在顶栏中部（槽位在工具栏内、水平居中），标题被挤压但不重叠；
/// - 窄屏（< 760）或预算不足：顶栏向下拉出一行放岛（高度 200ms 过渡），标题不被挤压；
/// - 展开：岛从顶栏脱离成悬浮卡片，槽位收缩为可点击收回的小标记；
/// - 无顶栏页面：回退为顶部悬浮。
void main() {
  /// 测试页：统一顶栏 + 空 body（不接任何业务页面）。
  ///
  /// 标题刻意取长文本（约 27 字，宽于顶栏一半）：宽屏下必须被驻场岛挤压
  /// （省略号）且保底 [kIslandTitleMinWidth]；窄屏下不受挤压。
  const longTitle = '测试页面标题很长用于验证挤压再加一些字凑够二十七个字整';

  Widget barPage({List<Widget> actions = const []}) => IslandAwareScaffold(
    appBarBuilder: (context, extraRow) => NarrChatAppBar(
      extraRowHeight: extraRow,
      title: longTitle,
      actions: actions,
    ),
    body: const SizedBox.expand(),
  );

  Future<CloudSyncProvider> pumpBarApp(
    WidgetTester tester, {
    Size size = const Size(1400, 900),
    List<Widget> actions = const [],
    bool withBar = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final sync = CloudSyncProvider();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<CloudSyncProvider>.value(value: sync),
          ChangeNotifierProvider<BookProvider>.value(
            value: BookProvider(dao: FakeBookDao())..loadBooks(),
          ),
          ChangeNotifierProvider<RoundProvider>.value(
            value: RoundProvider(
              dao: FakeRoundDao(),
              bookDao: FakeBookDao(),
              aiService: ToggleAiService(),
            ),
          ),
        ],
        child: MaterialApp(
          theme: NarrChatTheme.light,
          builder: (context, child) => AppNoticeOverlay(
            onOpenBook: (_) {},
            child: child ?? const SizedBox.shrink(),
          ),
          home: withBar
              ? barPage(actions: actions)
              : const Scaffold(body: SizedBox.expand()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return sync;
  }

  /// 推帧到所有 200ms 动画（出现 / 脱离 / 顶栏行高）与槽位测量都落定。
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  /// 让同步开始 → 岛出现（含出现动画 / 顶栏行高 / 槽位测量落定）。
  Future<void> startSync(
    WidgetTester tester,
    CloudSyncProvider sync, {
    String label = '读取云端清单…',
  }) async {
    sync.debugSetSyncState(SyncPlane.data, SyncState.syncing);
    sync.debugSetProgress(
      SyncPlane.data,
      SyncProgressEvent(phase: SyncPhase.pullManifest, label: label),
    );
    await settle(tester);
  }

  /// 岛卡片（黑底卡片）矩形；收起态就是嵌入顶栏的那枚胶囊。
  Rect islandCard(WidgetTester tester) => tester.getRect(
    find
        .descendant(
          of: find.byType(PinnedNoticeIsland),
          matching: find.byType(Material),
        )
        .first,
  );

  Rect barRect(WidgetTester tester) =>
      tester.getRect(find.byType(NarrChatAppBar));

  /// 岛当前**可见宽度**（展开度裁剪盒的宽度）；未渲染（宽度归零）时返回 null。
  double? islandCardWidth(WidgetTester tester) {
    final clip = find.byKey(const ValueKey('island_unfold_clip'));
    if (clip.evaluate().isEmpty) return null;
    return tester.getSize(clip).width;
  }

  /// 展开度因子（1 = 完整宽度）。同时用于校验「非线性」：中途不应等于线性进度。
  double unfoldFactor(WidgetTester tester) => tester
      .widget<Align>(find.byKey(const ValueKey('island_unfold')))
      .widthFactor!;

  testWidgets('嵌入态出现：非线性调整宽度，自中心向左右展开', (tester) async {
    final sync = await pumpBarApp(tester);
    sync.debugSetSyncState(SyncPlane.data, SyncState.syncing);
    sync.debugSetProgress(
      SyncPlane.data,
      const SyncProgressEvent(phase: SyncPhase.pullManifest, label: '读取云端清单…'),
    );
    // 零时长推帧：完成「岛汇报有内容 → 顶栏占位 → 槽位测量」链路，
    // 但不推进动画时钟（此时宽度仍为 0，未渲染）。
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
    expect(islandCardWidth(tester), isNull, reason: '起点宽度为 0');

    // 动画途中出现中间宽度（左右同时张开），且是**非线性**推进：
    // 时钟走了 60/200，宽度应已超过线性进度（easeOutCubic）。
    await tester.pump(const Duration(milliseconds: 60));
    final mid = islandCardWidth(tester)!;
    expect(mid, greaterThan(0));
    expect(unfoldFactor(tester), greaterThan(60 / 200),
        reason: '非线性曲线：前段更快');

    // 展开到完整宽度：胶囊按**内容自然宽**成形，而不是撑满槽位。
    await tester.pump(const Duration(milliseconds: 300));
    final full = islandCardWidth(tester)!;
    expect(full, greaterThan(mid));
    expect(unfoldFactor(tester), 1);
    final slotWidth = tester.getRect(find.byType(IslandSlot)).width;
    expect(full, lessThan(slotWidth),
        reason: '胶囊按内容成形（槽位只是可用宽度上限）');
    expect(
      tester.getRect(find.byKey(const ValueKey('island_unfold_clip'))).center.dx,
      closeTo(1400 / 2, 2),
      reason: '自中心向左右对称展开',
    );
  });

  testWidgets('嵌入态消失：非线性收窄宽度直至撤下', (tester) async {
    final sync = await pumpBarApp(tester);
    await startSync(tester, sync);
    final full = islandCardWidth(tester)!;
    expect(full, greaterThan(0));

    sync.debugSetSyncState(SyncPlane.data, SyncState.success);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 120));
    final mid = islandCardWidth(tester)!;
    expect(mid, greaterThan(0));
    expect(mid, lessThan(full), reason: '收窄过程中保留中间宽度');
    // 收窄同样居中对称（两侧一起向中心收）。
    expect(
      tester.getRect(find.byKey(const ValueKey('island_unfold_clip'))).center.dx,
      closeTo(1400 / 2, 2),
    );

    // 播完即撤下（不残留空壳）。
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(islandCardWidth(tester), isNull);
    expect(
      find.descendant(
        of: find.byType(PinnedNoticeIsland),
        matching: find.byType(Material),
      ),
      findsNothing,
    );
  });

  testWidgets('宽屏：岛收起时嵌在顶栏中部，标题被挤压但不与岛重叠', (tester) async {
    final sync = await pumpBarApp(tester);
    // 无内容时不占槽位。
    expect(find.byType(IslandSlot), findsNothing);

    await startSync(tester, sync);
    expect(find.byType(IslandSlot), findsOneWidget);
    expect(tester.getSize(find.byType(NarrChatAppBar)).height, kToolbarHeight,
        reason: '宽屏单行形态，顶栏高度不变');

    final bar = barRect(tester);
    final slot = tester.getRect(find.byType(IslandSlot));
    final card = islandCard(tester);
    // 槽位在工具栏内、水平居中。
    expect(slot.top, greaterThanOrEqualTo(bar.top));
    expect(slot.bottom, lessThanOrEqualTo(bar.bottom));
    expect(slot.center.dx, closeTo(1400 / 2, 1));
    // 岛画在槽位矩形内（宽度不超过预算，且居中）。
    expect(card.center.dx, closeTo(slot.center.dx, 2));
    expect(card.width, lessThanOrEqualTo(slot.width + 0.5));
    // 标题被挤压（长标题省略号），但保底 8 字宽且不与岛重叠。
    final title = tester.getRect(find.text(longTitle));
    expect(title.right, lessThanOrEqualTo(card.left - kIslandTitleGap + 0.5),
        reason: '标题必须止于岛左缘之前');
    expect(title.width, greaterThanOrEqualTo(kIslandTitleMinWidth - 0.5),
        reason: '标题保底字数空间');
    expect(title.width, lessThan(tester.getSize(find.byType(NarrChatAppBar)).width / 2),
        reason: '宽屏下标题确实被岛挤压到左半区');
  });

  testWidgets('窄屏（<760）：顶栏向下拉出一行放岛，标题不再被挤压', (tester) async {
    final sync = await pumpBarApp(tester, size: const Size(700, 900));
    // 零时长推帧完成「岛汇报 → 顶栏占位」链路，附加行动画随即开始。
    sync.debugSetSyncState(SyncPlane.data, SyncState.syncing);
    sync.debugSetProgress(
      SyncPlane.data,
      const SyncProgressEvent(phase: SyncPhase.pullManifest, label: '读取云端清单…'),
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
    // 过渡途中：高度严格介于单行与「工具栏 + 附加行」之间（不是瞬变）。
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    final midHeight = tester.getSize(find.byType(NarrChatAppBar)).height;
    expect(midHeight, greaterThan(kToolbarHeight));
    expect(
      midHeight,
      lessThan(kToolbarHeight + kIslandRowHeight),
      reason: '附加行高度是 200ms 过渡出来的',
    );
    await settle(tester);

    final bar = barRect(tester);
    expect(bar.height, closeTo(kToolbarHeight + kIslandRowHeight, 1),
        reason: '窄屏顶栏高度 = 工具栏 + 附加行');
    final slot = tester.getRect(find.byType(IslandSlot));
    expect(
      slot.center.dy,
      inInclusiveRange(bar.top + kToolbarHeight, bar.bottom),
      reason: '岛在附加行内',
    );
    expect(slot.center.dx, closeTo(700 / 2, 2));
    // 标题保持完整宽度（不受岛挤压：可越过顶栏中线）。
    final title = tester.getRect(find.text(longTitle));
    expect(title.right, greaterThan(700 / 2),
        reason: '窄屏顶栏的岛在附加行，标题不再让位');
  });

  testWidgets('预算不足：窗口够宽但右侧按键过宽时同样走附加行', (tester) async {
    // 900 宽窗口 + 600 宽的“按键” → 岛预算 < 140 → 改走附加行。
    final sync = await pumpBarApp(
      tester,
      size: const Size(900, 900),
      actions: const [SizedBox(width: 600, height: 40)],
    );
    await startSync(tester, sync);
    expect(
      tester.getSize(find.byType(NarrChatAppBar)).height,
      closeTo(kToolbarHeight + kIslandRowHeight, 1),
    );
  });

  testWidgets('展开：从顶栏脱离成悬浮卡片，槽位收缩为小标记且可点击收回', (tester) async {
    final sync = await pumpBarApp(tester);
    await startSync(tester, sync);
    final bar = barRect(tester);
    final embeddedCard = islandCard(tester);
    expect(embeddedCard.top, greaterThanOrEqualTo(bar.top));

    // 点击顶栏里的岛 → 展开并脱离。
    await tester.tap(find.text('数据同步 · 读取云端清单'));
    await settle(tester);

    final detached = islandCard(tester);
    expect(detached.top, greaterThan(bar.bottom),
        reason: '展开后脱离顶栏，悬浮在顶栏下方');
    expect(detached.center.dx, closeTo(1400 / 2, 2));
    // 槽位收缩为小标记（标题回收空间）。
    final slot = tester.getRect(find.byType(IslandSlot));
    expect(slot.width, kIslandMarkerSize);
    expect(find.byTooltip('收回顶栏'), findsOneWidget);

    // 点小标记 → 收回顶栏（回到嵌入态）。
    await tester.tap(find.byTooltip('收回顶栏'));
    await settle(tester);
    final back = islandCard(tester);
    expect(back.top, lessThan(bar.bottom), reason: '收回后重新嵌回顶栏');
  });

  testWidgets('无顶栏页面：岛回退为顶部悬浮（不依赖槽位）', (tester) async {
    final sync = await pumpBarApp(tester, withBar: false);
    await startSync(tester, sync);
    expect(find.byType(IslandSlot), findsNothing);
    final card = islandCard(tester);
    expect(card.center.dx, closeTo(1400 / 2, 2));
    expect(card.top, closeTo(kToolbarHeight + 8, 2));
  });

  testWidgets('岛消失：顶栏附加行收回，岛从树上撤下', (tester) async {
    final sync = await pumpBarApp(tester, size: const Size(700, 900));
    await startSync(tester, sync);
    expect(
      tester.getSize(find.byType(NarrChatAppBar)).height,
      closeTo(kToolbarHeight + kIslandRowHeight, 0.5),
    );

    sync.debugSetSyncState(SyncPlane.data, SyncState.success);
    // 先等岛收窄消失（200ms），再等附加行收回（200ms）。
    await settle(tester);
    await settle(tester);
    expect(
      tester.getSize(find.byType(NarrChatAppBar)).height,
      closeTo(kToolbarHeight, 1),
      reason: '无内容后附加行收回',
    );
    expect(
      find.descendant(
        of: find.byType(PinnedNoticeIsland),
        matching: find.byType(Material),
      ),
      findsNothing,
    );
  });
}
