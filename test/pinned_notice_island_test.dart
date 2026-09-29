import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/app_notice.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/providers/book_provider.dart';
import 'package:narrchat/providers/cloud_sync_provider.dart';
import 'package:narrchat/providers/round_provider.dart';
import 'package:narrchat/services/sync/sync_models.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/app_notice_overlay.dart';
import 'package:narrchat/widgets/notice_visuals.dart';
import 'package:narrchat/widgets/pinned_notice_island.dart';
import 'package:provider/provider.dart';

import 'helpers/fakes.dart';

/// 可预置「正在生成的书」与「当前可见对话页」的 RoundProvider 替身。
class _FakeRoundProvider extends RoundProvider {
  _FakeRoundProvider(this.uuids)
      : super(
          dao: FakeRoundDao(),
          aiService: ToggleAiService(),
          bookDao: FakeBookDao(),
        );

  final List<String> uuids;

  @override
  List<String> get activeGenerationBookUuids => uuids;

  String? _visible;

  @override
  String? get visibleChatBookUuid => _visible;

  @override
  void setVisibleChatBook(String? bookUuid) {
    if (_visible == bookUuid) return;
    _visible = bookUuid;
    notifyListeners();
  }
}

/// 驻场岛（[PinnedNoticeIsland]）测试：
/// 收起态只有图标 + 主文案（无取消按钮）、点击展开后含分平面取消与生成书列表、
/// 结果条目成功 3s / 失败 15s 自动收起、「已读」提前收起、空闲不占位。
///
/// 注意：岛上常驻转圈动画（无限 ticker），**不能用 `pumpAndSettle`**，
/// 一律用显式 `pump(duration)`。
void main() {
  Future<CloudSyncProvider> pumpIsland(
    WidgetTester tester, {
    Size size = const Size(1400, 900),
    RoundProvider? roundProvider,
    List<Book> books = const [],
    void Function(String bookUuid)? onOpenBook,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final sync = CloudSyncProvider();
    final bookProvider = BookProvider(dao: FakeBookDao(books: books));
    await bookProvider.loadBooks();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<CloudSyncProvider>.value(value: sync),
          ChangeNotifierProvider<BookProvider>.value(value: bookProvider),
          ChangeNotifierProvider<RoundProvider>.value(
            value: roundProvider ??
                RoundProvider(
                  dao: FakeRoundDao(),
                  bookDao: FakeBookDao(),
                  aiService: ToggleAiService(),
                ),
          ),
        ],
        child: MaterialApp(
          theme: NarrChatTheme.light,
          builder: (context, child) => AppNoticeOverlay(
            onOpenBook: onOpenBook ?? (_) {},
            child: child ?? const SizedBox.shrink(),
          ),
          home: const Scaffold(body: SizedBox.expand()),
        ),
      ),
    );
    await tester.pump();
    return sync;
  }

  /// 走完驻场岛的出现 / 消失动画（淡入 200ms + 宽度收放 200ms；
  /// 宽度动画需要先测出胶囊自然宽，故多推一帧）。
  Future<void> settlePresence(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 250));
  }

  /// 点击胶囊展开并等 200ms 形变完成（ticker 首帧 elapsed 恒为 0，需多推一帧）。
  ///
  /// 先等「宽度展开动画」走完：起点宽度为 0，期间右侧箭头处于裁剪区之外不可点。
  Future<void> expand(WidgetTester tester) async {
    await settlePresence(tester);
    await tester.tap(find.byIcon(Icons.expand_more));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump(const Duration(milliseconds: 250));
  }

  /// 驻场岛出现 / 消失动画的当前透明度（0 = 完全隐藏，1 = 就位）。
  double islandOpacity(WidgetTester tester) => tester
      .widget<Opacity>(find.byKey(const ValueKey('island_presence')))
      .opacity;

  testWidgets('出现动画：内容出现后自顶部淡入就位（200ms）', (tester) async {
    final sync = await pumpIsland(tester);
    sync.debugSetSyncState(SyncPlane.data, SyncState.syncing);
    await tester.pump();

    // 首帧即在树中（透明度 0），避免闪空。
    expect(find.textContaining('数据同步'), findsOneWidget);
    expect(islandOpacity(tester), 0, reason: '出现动画起点为完全透明');

    await tester.pump(const Duration(milliseconds: 1)); // 帧后回调启动 forward
    await tester.pump(const Duration(milliseconds: 100));
    final mid = islandOpacity(tester);
    expect(mid, greaterThan(0));
    expect(mid, lessThan(1));

    await tester.pump(const Duration(milliseconds: 200));
    expect(islandOpacity(tester), 1, reason: '200ms 后完全就位');
  });

  testWidgets('消失动画：内容清空后自顶部淡出，播完从树上撤下', (tester) async {
    final sync = await pumpIsland(tester);
    sync.debugSetSyncState(SyncPlane.data, SyncState.syncing);
    await tester.pump();
    await settlePresence(tester);
    expect(islandOpacity(tester), 1);

    // 同步结束 → 内容清空。
    sync.debugSetSyncState(SyncPlane.data, SyncState.success);
    await tester.pump();
    expect(
      find.textContaining('数据同步'),
      findsOneWidget,
      reason: '淡出期间沿用最后一帧内容，避免内容先消失再淡出',
    );

    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 100));
    final mid = islandOpacity(tester);
    expect(mid, greaterThan(0));
    expect(mid, lessThan(1));

    await tester.pump(const Duration(milliseconds: 200));
    expect(
      find.byKey(const ValueKey('island_presence')),
      findsNothing,
      reason: '淡出播完即不占位',
    );
  });

  testWidgets('统一黑底白字：岛为深色卡片 + 浅色字体', (tester) async {
    final sync = await pumpIsland(tester);
    sync.debugSetSyncState(SyncPlane.data, SyncState.syncing);
    sync.debugSetProgress(
      SyncPlane.data,
      const SyncProgressEvent(phase: SyncPhase.pullManifest, label: '读取云端清单…'),
    );
    await settlePresence(tester);

    final material = tester.widget<Material>(
      find
          .descendant(
            of: find.byType(PinnedNoticeIsland),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(material.color, kNoticeSurface, reason: '统一黑底');
    expect(
      (material.color!.r + material.color!.g + material.color!.b) / 3,
      lessThan(0.15),
    );
    final text = tester.widget<Text>(find.text('数据同步 · 读取云端清单'));
    expect(text.style?.color, kNoticeTextPrimary, reason: '统一浅色（白色）字体');
  });

  testWidgets('空闲：不占位（无展开箭头、无取消按钮）', (tester) async {
    await pumpIsland(tester);
    expect(find.byType(PinnedNoticeIsland), findsOneWidget);
    expect(find.byIcon(Icons.expand_more), findsNothing);
    expect(find.byIcon(Icons.close), findsNothing);
  });

  testWidgets('收起态：只有图标 + 进度文案，无取消按钮', (tester) async {
    final sync = await pumpIsland(tester);
    sync.debugSetSyncState(SyncPlane.data, SyncState.syncing);
    sync.debugSetProgress(
      SyncPlane.data,
      const SyncProgressEvent(phase: SyncPhase.pullManifest, label: '读取云端清单…'),
    );
    await tester.pump();

    expect(find.text('数据同步 · 读取云端清单'), findsOneWidget);
    expect(find.textContaining('图片同步'), findsNothing);
    expect(find.byIcon(Icons.close), findsNothing, reason: '收起态不暴露取消按钮');
    expect(find.byIcon(Icons.expand_more), findsOneWidget);
  });

  testWidgets('点击展开：出现本平面取消按钮，点击只置对应平面的取消标记', (tester) async {
    final sync = await pumpIsland(tester);
    sync.debugSetSyncState(SyncPlane.data, SyncState.syncing);
    await tester.pump();

    await expand(tester);
    expect(find.byTooltip('取消数据同步'), findsOneWidget);

    expect(sync.debugCancelRequested(SyncPlane.data), isFalse);
    await tester.tap(find.byTooltip('取消数据同步'));
    await tester.pump();
    expect(sync.debugCancelRequested(SyncPlane.data), isTrue);

    // 头部箭头可再次收起。
    await tester.tap(find.byIcon(Icons.expand_less));
    await tester.pump();
    expect(find.byTooltip('取消数据同步'), findsNothing);
  });

  testWidgets('两平面同时在跑：收起态显示主平面 + "+1"，展开后各段独立取消', (tester) async {
    final sync = await pumpIsland(tester);
    sync.debugSetSyncState(SyncPlane.data, SyncState.syncing);
    sync.debugSetSyncState(SyncPlane.images, SyncState.syncing);
    sync.debugSetProgress(
      SyncPlane.data,
      const SyncProgressEvent(phase: SyncPhase.pushSnapshot, label: '上传快照…'),
    );
    sync.debugSetProgress(
      SyncPlane.images,
      const SyncProgressEvent(
        phase: SyncPhase.pushImages,
        label: '上传图片',
        currentItem: 2,
        totalItems: 30,
      ),
    );
    await tester.pump();

    expect(find.text('数据同步 · 上传快照'), findsOneWidget);
    expect(find.text('+1'), findsOneWidget);

    await expand(tester);
    // 展开态头部只做计数摘要，细节各自成行（不重复文案）。
    expect(find.text('同步中 2'), findsOneWidget);
    expect(find.text('数据同步 · 上传快照'), findsOneWidget);
    expect(find.text('图片同步 · 上传图片 · 3/30'), findsOneWidget);
    expect(find.byTooltip('取消数据同步'), findsOneWidget);
    expect(find.byTooltip('取消图片同步'), findsOneWidget);

    await tester.tap(find.byTooltip('取消图片同步'));
    await tester.pump();
    expect(sync.debugCancelRequested(SyncPlane.images), isTrue);
    expect(sync.debugCancelRequested(SyncPlane.data), isFalse);
  });

  testWidgets('正在生成：收起态计数，展开后点书名跳转并收起', (tester) async {
    const book = Book(uuid: 'b1', title: '书A');
    final opened = <String>[];
    final round = _FakeRoundProvider(const ['b1']);
    await pumpIsland(
      tester,
      roundProvider: round,
      books: const [book],
      onOpenBook: opened.add,
    );
    await tester.pump();

    expect(find.text('1本书正在生成……'), findsOneWidget);

    await expand(tester);
    expect(find.text('书A'), findsOneWidget);

    await tester.tap(find.text('书A'));
    await tester.pump();
    expect(opened, ['b1']);
    // 跳转后岛回到收起态。
    expect(find.byIcon(Icons.expand_more), findsOneWidget);
  });

  testWidgets('正在生成：正在查看的那本书不提示，离开页面才提示、返回后不再提示', (tester) async {
    // 停留在该书对话页：`visibleChatBookUuid` = 该书 → 不提示（改动前内嵌横幅
    // 也是传 excludeBookUuid 排除当前查看书）。
    final round = _FakeRoundProvider(const ['b1'])..setVisibleChatBook('b1');
    await pumpIsland(tester, roundProvider: round);
    await tester.pump();
    expect(find.text('1本书正在生成……'), findsNothing,
        reason: '正在看这本书，不该提示它自己在生成');

    // 在应用内离开该页面（回首页 / 进设置 / 切到别的书）。
    round.setVisibleChatBook(null);
    await settlePresence(tester);
    expect(find.text('1本书正在生成……'), findsOneWidget);

    // 回到该书页面：提示消失。
    round.setVisibleChatBook('b1');
    await settlePresence(tester);
    expect(find.text('1本书正在生成……'), findsNothing);
    expect(find.byIcon(Icons.expand_more), findsNothing, reason: '岛整体撤下');
  });

  testWidgets('正在生成：切到别的书时，正在生成的那本书仍然提示', (tester) async {
    final round = _FakeRoundProvider(const ['b1'])..setVisibleChatBook('b2');
    await pumpIsland(tester, roundProvider: round);
    await settlePresence(tester);
    expect(find.text('1本书正在生成……'), findsOneWidget,
        reason: '当前看的是别的书，b1 在生成 → 提示');
  });

  testWidgets('结果成功：3 秒后自动收起（收起态也计时，含 200ms 淡出）', (tester) async {
    final sync = await pumpIsland(tester);
    sync.showSyncResult('云端记录 #3：数据已同步');
    await tester.pump();

    expect(find.text('云端记录 #3：数据已同步'), findsOneWidget);
    // 收起态不渲染条目，但计时照跑。
    await tester.pump(const Duration(seconds: 3));
    expect(sync.resultToasts, isEmpty);
    // 淡出动画播完后彻底撤下。
    await settlePresence(tester);
    expect(find.text('云端记录 #3：数据已同步'), findsNothing);
  });

  testWidgets('结果失败：15 秒内驻留（可读完），点「已读」提前收起', (tester) async {
    final sync = await pumpIsland(tester);
    sync.showSyncResult(
      '数据同步失败：无法连接服务器',
      kind: NoticeKind.error,
    );
    await tester.pump();

    expect(find.text('数据同步失败：无法连接服务器'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    expect(
      find.text('数据同步失败：无法连接服务器'),
      findsOneWidget,
      reason: '失败条目比成功条目驻留更久',
    );

    await expand(tester);
    expect(find.text('已读'), findsOneWidget);
    await tester.tap(find.text('已读'));
    await tester.pump();
    expect(sync.resultToasts, isEmpty);
    // 「已读」= 提前收起：先淡出，播完撤下。
    await settlePresence(tester);
    expect(find.text('数据同步失败：无法连接服务器'), findsNothing);
  });

  testWidgets('结果失败：15 秒到点无条件收起', (tester) async {
    final sync = await pumpIsland(tester);
    sync.showSyncResult('图片同步：连接超时', kind: NoticeKind.error);
    await tester.pump();

    await tester.pump(const Duration(seconds: 15));
    expect(sync.resultToasts, isEmpty);
  });

  testWidgets('主文案优先级：结果 > 同步进度 > 正在生成', (tester) async {
    final sync = await pumpIsland(
      tester,
      roundProvider: _FakeRoundProvider(const ['b1']),
    );
    sync.debugSetSyncState(SyncPlane.data, SyncState.syncing);
    sync.debugSetProgress(
      SyncPlane.data,
      const SyncProgressEvent(phase: SyncPhase.merge, label: '合并数据'),
    );
    await tester.pump();
    expect(find.text('数据同步 · 合并数据'), findsOneWidget);

    sync.showSyncResult('云端记录 #2：已拉取最新数据');
    await tester.pump();
    expect(find.text('云端记录 #2：已拉取最新数据'), findsOneWidget);
    expect(find.text('+2'), findsOneWidget, reason: '同步段与生成段仍在，以 +N 提示');

    // 收尾：走完结果条目的自动撤销计时。
    await tester.pump(const Duration(seconds: 3));
    expect(sync.resultToasts, isEmpty);
  });

  testWidgets('窄屏：超长进度文案与展开区不溢出', (tester) async {
    final sync = await pumpIsland(tester, size: const Size(320, 640));
    sync.debugSetSyncState(SyncPlane.data, SyncState.syncing);
    sync.debugSetProgress(
      SyncPlane.data,
      const SyncProgressEvent(
        phase: SyncPhase.pushSnapshot,
        label: '上传超长中文文件名测试快照2020-01-01_00-00-00.db…',
      ),
    );
    await tester.pump();
    await expand(tester);
    expect(tester.takeException(), isNull);
  });
}
