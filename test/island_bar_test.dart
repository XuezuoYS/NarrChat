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
  /// 标题刻意取长文本（约 50 字，宽于顶栏一半）：宽屏下必须被驻场岛挤压
  /// （省略号）且保底 [kIslandTitleMinWidth]；没有岛时则能用满顶栏宽度。
  const longTitle =
      '测试页面标题很长用于验证驻场岛的挤压行为所以这里再补上足够多的字符让标题宽度超过顶栏的一半以上还要再多一些';

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

  /// 岛当前可见宽度（由岛逐帧汇报给顶栏控制器，正是标题挤压的依据）。
  double islandVisibleWidth(WidgetTester tester) {
    final island = find.byType(PinnedNoticeIsland);
    if (island.evaluate().isEmpty) return 0;
    final bar = IslandBarScope.maybeOf(tester.element(island));
    expect(bar, isNotNull, reason: '岛必须处在顶栏作用域内');
    return bar!.islandWidth.value;
  }

  testWidgets('无常驻岛：标题不受挤压（岛宽度为 0）', (tester) async {
    await pumpBarApp(tester);
    expect(islandVisibleWidth(tester), 0);
    // 长标题可用满顶栏宽度：越过顶栏中线（不会被压到左半区）。
    final title = tester.getRect(find.text(longTitle));
    expect(title.right, greaterThan(1400 / 2),
        reason: '没有岛时标题不该让位');
  });

  testWidgets('嵌入态出现：非线性收放宽度，标题实时跟随挤压', (tester) async {
    final sync = await pumpBarApp(tester);
    sync.debugSetSyncState(SyncPlane.data, SyncState.syncing);
    sync.debugSetProgress(
      SyncPlane.data,
      const SyncProgressEvent(phase: SyncPhase.pullManifest, label: '读取云端清单…'),
    );
    // 零时长推帧：完成「岛汇报有内容 → 顶栏占位 → 槽位测量 → 胶囊测量」链路，
    // 但不推进动画时钟（此时宽度仍为 0）。
    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    expect(islandVisibleWidth(tester), 0, reason: '起点宽度为 0');
    final titleFull = tester.getRect(find.text(longTitle)).width;

    // 动画途中出现中间宽度；非线性曲线（easeOutCubic）下前段应明显快于线性。
    await tester.pump(const Duration(milliseconds: 60));
    final mid = islandVisibleWidth(tester);
    expect(mid, greaterThan(0));

    // 展开到完整宽度：胶囊按**内容自然宽**成形，而不是撑满槽位。
    await tester.pump(const Duration(milliseconds: 300));
    final full = islandVisibleWidth(tester);
    expect(full, greaterThan(mid));
    final slotWidth = tester.getRect(find.byType(IslandSlot)).width;
    expect(full, lessThan(slotWidth),
        reason: '胶囊按内容成形（槽位只是可用宽度上限）');
    expect(mid, greaterThan(full * 0.5),
        reason: '非线性：时钟走 30% 时宽度应已过半');

    // 标题跟随岛宽度实时变化：岛变宽 → 标题可用宽度变小。
    expect(tester.getRect(find.text(longTitle)).width, lessThan(titleFull));
    final visibleLeft = 1400 / 2 - full / 2;
    expect(
      tester.getRect(find.text(longTitle)).right,
      lessThanOrEqualTo(visibleLeft - kIslandTitleGap + 0.5),
      reason: '标题止于岛（可见左缘）之前',
    );
  });

  testWidgets('内容变长：岛宽度带动画过渡，标题随之实时让位', (tester) async {
    final sync = await pumpBarApp(tester);
    // 先出现一段短文案的岛。
    await startSync(tester, sync, label: '读取');
    final before = islandVisibleWidth(tester);
    final titleBefore = tester.getRect(find.text(longTitle)).width;
    expect(before, greaterThan(0));

    // 文案变长 → 目标宽度变化，应先保持旧宽度再动画到新宽度（不跳变）。
    sync.debugSetProgress(
      SyncPlane.data,
      const SyncProgressEvent(
        phase: SyncPhase.pullManifest,
        label: '读取云端清单并逐条比对后合并到本地数据库快照',
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    expect(islandVisibleWidth(tester), closeTo(before, 1),
        reason: '变化后的第一帧不应跳变到新宽度');

    await tester.pump(const Duration(milliseconds: 1)); // 动画首帧（elapsed 0）
    await tester.pump(const Duration(milliseconds: 100));
    final mid = islandVisibleWidth(tester);
    expect(mid, greaterThan(before), reason: '动画中段已开始变宽');
    final titleMid = tester.getRect(find.text(longTitle)).width;
    expect(titleMid, lessThan(titleBefore),
        reason: '标题随岛变宽而实时收缩');

    await tester.pump(const Duration(milliseconds: 300));
    final after = islandVisibleWidth(tester);
    expect(after, greaterThan(mid), reason: '动画终点为新的自然宽度');
    expect(tester.getRect(find.text(longTitle)).width, lessThanOrEqualTo(titleMid));
  });

  testWidgets('嵌入态消失：非线性收窄宽度直至撤下', (tester) async {
    final sync = await pumpBarApp(tester);
    await startSync(tester, sync);
    final full = islandVisibleWidth(tester);
    expect(full, greaterThan(0));

    sync.debugSetSyncState(SyncPlane.data, SyncState.success);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 120));
    final mid = islandVisibleWidth(tester);
    expect(mid, greaterThan(0));
    expect(mid, lessThan(full), reason: '收窄过程中保留中间宽度');

    // 播完即撤下（不残留空壳）。
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(islandVisibleWidth(tester), 0);
    expect(
      find.descendant(
        of: find.byType(PinnedNoticeIsland),
        matching: find.byType(Material),
      ),
      findsNothing,
    );
  });

  testWidgets('切换页面后：岛仍嵌在新顶栏槽位里（返回不得把槽位清成空）', (tester) async {
    final sync = await pumpBarApp(tester);
    await startSync(tester, sync);
    final embeddedTop = islandCard(tester).top;
    expect(embeddedTop, lessThan(30), reason: '此时岛嵌在工具栏内');

    final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
    navigator.push(MaterialPageRoute<void>(builder: (_) => barPage()));
    await settle(tester);
    expect(islandCard(tester).top, closeTo(embeddedTop, 2),
        reason: '新页面顶栏的槽位接管后位置不变');

    // 返回：被销毁页面的槽位会发布 null，但它已不是当前发布者，
    // 不能因此把岛打回顶部悬浮位（悬浮位 top≈64）。
    navigator.pop();
    await settle(tester);
    expect(islandCard(tester).top, closeTo(embeddedTop, 2),
        reason: '返回后岛仍应嵌在顶栏槽位里');
    expect(islandVisibleWidth(tester), greaterThan(0));
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
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pump();
    final midHeight = tester.getSize(find.byType(NarrChatAppBar)).height;
    expect(midHeight, greaterThan(kToolbarHeight));
    expect(
      midHeight,
      lessThan(kToolbarHeight + kIslandRowHeight),
      reason: '附加行高度是过渡出来的',
    );
    // 且要够快：140ms 内必须拉满（曾用 200ms 线性动画，观感偏慢）。
    await tester.pump(const Duration(milliseconds: 160));
    expect(
      tester.getSize(find.byType(NarrChatAppBar)).height,
      closeTo(kToolbarHeight + kIslandRowHeight, 0.5),
      reason: '附加行应在 140ms 内拉满',
    );
    await settle(tester);

    final bar = barRect(tester);
    expect(bar.height, closeTo(kToolbarHeight + kIslandRowHeight, 1),
        reason: '窄屏顶栏高度 = 工具栏 + 附加行');
    // 岛**向上嵌进工具栏空白区**，下方留顶栏背景留白：
    // - 曾经因为「槽位只在挂载那一帧测量」而永久偏上约 13px、与顶栏重叠；
    // - 曾经完全排在工具栏下方，视觉上隔着整块空白（间距过大）。
    final rowBottom = bar.bottom - 1; // 顶栏底部 1px 边线
    final rowTop = rowBottom - kIslandRowHeight;
    final card = islandCard(tester);
    expect(rowTop - card.top, closeTo(kIslandRowOverlap, 0.5),
        reason: '岛向上借用工具栏空白 $kIslandRowOverlap px（视觉上紧贴上方元素）');
    expect(rowBottom - card.bottom, closeTo(kIslandRowPadding, 0.5),
        reason: '岛下方留白 = $kIslandRowPadding px');
    expect(card.bottom, greaterThan(rowTop), reason: '岛跨在工具栏下缘上');
    // 视觉验收：岛顶与标题底部的关系必须正好是「工具栏下部空白 − 上提量」
    // （不写死像素，跟着 kIslandRowOverlap 走；当前 5px → 约 14px）。
    final titleBox = tester.getRect(find.text(longTitle));
    final visualGap = card.top - titleBox.bottom;
    final toolbarGapWithoutOverlap =
        bar.top + kToolbarHeight - 1 - titleBox.bottom; // 工具栏下部的空白
    expect(visualGap, greaterThan(0), reason: '不与标题重叠');
    expect(
      visualGap,
      closeTo(toolbarGapWithoutOverlap - kIslandRowOverlap, 1),
      reason: '视觉间距 = 工具栏下部空白 − 上提量',
    );
    final slot = tester.getRect(find.byType(IslandSlot));
    expect(
      slot.top,
      closeTo(bar.top + kToolbarHeight - 1 - kIslandRowOverlap, 1),
      reason: '槽位向上嵌进工具栏下方的空白区',
    );
    expect(slot.center.dx, closeTo(700 / 2, 2));
    // 标题保持完整宽度（不受岛挤压：可越过顶栏中线）。
    final title = tester.getRect(find.text(longTitle));
    expect(title.right, greaterThan(700 / 2),
        reason: '窄屏顶栏的岛在附加行，标题不再让位');
  });

  testWidgets('窄屏收起（无岛）：顶栏原本的元素不被附加行挤压', (tester) async {
    // 回归：曾把 28px 占位框留在 0 高的 bottom 槽里，使 AppBar 把工具栏压成
    // 28px——标题 / 按钮整体上移到 top≈5，观感就是「顶栏元素被动了」。
    // 用「图标 + 标题 + 右侧按键」模拟首页顶栏。
    await pumpBarApp(
      tester,
      size: const Size(380, 900),
      actions: [
        IconButton(
          icon: const Icon(Icons.settings_outlined),
          tooltip: '设置',
          onPressed: () {},
        ),
      ],
    );
    await tester.pump(const Duration(milliseconds: 200));

    final bar = barRect(tester);
    expect(bar.height, kToolbarHeight, reason: '无岛时顶栏仍是单行');
    expect(tester.takeException(), isNull, reason: '不得出现布局溢出');
    // 工具栏内容垂直居中（(56-1px 底边) / 2 ≈ 27.5）。
    final center = bar.top + (kToolbarHeight - 1) / 2;
    expect(tester.getRect(find.text(longTitle)).center.dy, closeTo(center, 1.5),
        reason: '标题垂直居中于工具栏');
    expect(
      tester.getRect(find.byIcon(Icons.settings_outlined)).center.dy,
      closeTo(center, 1.5),
      reason: '右侧按键垂直居中于工具栏',
    );
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
