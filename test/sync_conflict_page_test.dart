import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/providers/cloud_sync_provider.dart';
import 'package:narrchat/screens/sync_conflict_page.dart';
import 'package:narrchat/services/cloud_backup/backup_runner.dart';
import 'package:narrchat/services/sync/sync_conflict.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:provider/provider.dart';

import 'helpers/notice_harness.dart';
import 'helpers/sync_conflict_fixtures.dart';

/// 冲突决策页：PK 展示、选择交互、批量、应用流程、失败与空状态。
void main() {
  /// 宿主页：点按钮才推冲突页，便于断言「应用完后自动返回」。
  Widget host() {
    return Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () => SyncConflictPage.open(context),
            child: const Text('打开冲突页'),
          ),
        ),
      ),
    );
  }

  Future<_SpyProvider> pumpPage(
    WidgetTester tester, {
    List<SyncConflict>? conflicts,
    _SpyProvider? provider,
    double width = 900,
  }) async {
    final spy = provider ?? _SpyProvider();
    spy.debugSetConflicts(conflicts ?? [buildBookConflict()]);
    tester.view.physicalSize = Size(width, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<CloudSyncProvider>.value(
        value: spy,
        child: MaterialApp(
          theme: NarrChatTheme.light,
          builder: floatingNoticeBuilder(),
          home: host(),
        ),
      ),
    );
    await tester.tap(find.text('打开冲突页'));
    await tester.pumpAndSettle();
    return spy;
  }

  testWidgets('渲染概览与 PK 三轴 / 侧卡 / 云端代次', (tester) async {
    await pumpPage(tester);

    expect(find.text('同步冲突决策'), findsOneWidget);
    expect(find.text('需要你决定 1 项'), findsOneWidget);
    expect(find.text('书籍《测试书》'), findsOneWidget);
    expect(find.text('代数'), findsWidgets);
    expect(find.text('最新轮次'), findsWidgets);
    expect(find.text('更新时间'), findsWidgets);
    expect(find.text('4 代'), findsWidgets, reason: '本地代数 4');
    expect(find.text('6 代'), findsWidgets, reason: '云端代数 6');
    expect(find.textContaining('第 4 代 · 设备 device-a'), findsOneWidget);
    expect(find.textContaining('无法自动判定'), findsOneWidget);
    expect(find.text('已选 0 / 1'), findsOneWidget);
  });

  testWidgets('点侧卡选中本地：状态徽标与计数同步', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.text('本地').last);
    await tester.pumpAndSettle();

    expect(find.text('已选本地'), findsOneWidget);
    expect(find.text('已选 1 / 1'), findsOneWidget);
    expect(find.text('应用决策（1）'), findsOneWidget);
  });

  testWidgets('未选择时应用按钮禁用', (tester) async {
    await pumpPage(tester);

    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '应用决策'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('全部采用云端 → 确认 → 提交 remote 并自动返回', (tester) async {
    final spy = await pumpPage(tester);

    await tester.tap(find.text('全部采用云端'));
    await tester.pumpAndSettle();
    expect(find.text('已选云端'), findsOneWidget);

    await tester.tap(find.text('应用决策（1）'));
    await tester.pumpAndSettle();
    expect(find.text('应用这些决策？'), findsOneWidget);
    expect(find.text('采用云端 1 项，保留本地 0 项。'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '应用'));
    await tester.pumpAndSettle();

    expect(spy.applied, hasLength(1));
    expect(spy.applied.single.choice, BackupConflictChoice.remote);
    expect(find.text('同步冲突决策'), findsNothing, reason: '全部解决后自动返回');
    expect(find.text('采用云端 1 项'), findsOneWidget);
    await flushNotices(tester);
  });

  testWidgets('全部保留本地 → 提交 local', (tester) async {
    final spy = await pumpPage(tester);

    await tester.tap(find.text('全部保留本地'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('应用决策（1）'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '应用'));
    await tester.pumpAndSettle();

    expect(spy.applied.single.choice, BackupConflictChoice.local);
    await flushNotices(tester);
  });

  testWidgets('按 PK 建议：三轴一致时才自动落选择', (tester) async {
    final localWins = buildBookConflict(
      localLatestRound: 5,
      localGenerationCount: 9,
      localUpdatedAt: DateTime.utc(2026, 3, 1),
      remoteLatestRound: 2,
      remoteGenerationCount: 3,
      remoteUpdatedAt: DateTime.utc(2026, 1, 1),
    );
    await pumpPage(tester, conflicts: [localWins]);

    await tester.tap(find.text('按 PK 建议'));
    await tester.pumpAndSettle();

    expect(find.text('已选本地'), findsOneWidget);
    expect(find.text('应用决策（1）'), findsOneWidget);
  });

  testWidgets('全部稍后处理：不产生决策、按钮禁用', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.text('全部稍后处理'));
    await tester.pumpAndSettle();

    expect(find.text('稍后处理'), findsWidgets);
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '应用决策'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('应用失败：错误内联展示、页面不返回', (tester) async {
    final spy = _SpyProvider()
      ..reportOverride = const SyncConflictApplyReport(
        errors: {'book:b1': '快照下载失败'},
      );
    await pumpPage(tester, provider: spy);

    await tester.tap(find.text('全部采用云端'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('应用决策（1）'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '应用'));
    await tester.pumpAndSettle();

    expect(find.text('快照下载失败'), findsOneWidget);
    expect(find.text('同步冲突决策'), findsOneWidget, reason: '有失败就别关页');
    expect(find.text('已选云端'), findsOneWidget, reason: '失败项保留选择，方便重试');
    await flushNotices(tester);
  });

  testWidgets('空状态：没有待处理冲突', (tester) async {
    await pumpPage(tester, conflicts: const []);

    expect(find.text('没有待处理的冲突'), findsOneWidget);
    expect(find.text('已选 0 / 0'), findsNothing);
  });

  testWidgets('窄屏 360：可渲染且侧卡上下堆叠', (tester) async {
    await pumpPage(
      tester,
      width: 360,
      conflicts: [buildBookConflict(), buildModsConflict()],
    );

    expect(find.text('需要你决定 2 项'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('多项冲突：概览按类别统计', (tester) async {
    await pumpPage(
      tester,
      conflicts: [
        buildBookConflict(),
        buildModsConflict(),
        buildLibraryConflict(),
      ],
    );

    expect(find.text('需要你决定 3 项'), findsOneWidget);
    expect(find.text('1'), findsWidgets);
  });

  testWidgets('预览：两路加载并展示两侧字段', (tester) async {
    final spy = await pumpPage(tester);

    await tester.tap(find.byTooltip('对比预览').first);
    await tester.pumpAndSettle();

    expect(spy.previewCalls, 2, reason: '本地 + 云端各一次');
    expect(find.textContaining('对比预览 · 书籍《测试书》'), findsOneWidget);
    expect(find.text('本地书名'), findsOneWidget);
    expect(find.text('云端书名'), findsOneWidget);

    // 长文本字段在下方，滚动到那里才能看到差异标记。
    await tester.scrollUntilVisible(
      find.text('基础设定'),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    expect(find.text('有差异'), findsWidgets);

    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
  });

  testWidgets('PK 缺数据：轴行显示「未知」', (tester) async {
    final unknown = buildBookConflict(
      remoteLatestRound: 0,
      remoteGenerationCount: 0,
    );
    await pumpPage(tester, conflicts: [unknown]);

    expect(find.text('未知'), findsWidgets);
    expect(find.textContaining('缺少数据'), findsOneWidget);
  });
}

/// 可编排的 provider 替身：只覆盖冲突页用到的两个方法。
class _SpyProvider extends CloudSyncProvider {
  final List<SyncConflictDecision> applied = [];

  /// 非空时直接返回它（模拟单元级失败）；否则按决策自动统计。
  SyncConflictApplyReport? reportOverride;
  int previewCalls = 0;

  @override
  Future<SyncConflictApplyReport> applyConflictDecisions(
    List<SyncConflictDecision> decisions,
  ) async {
    applied.addAll(decisions);
    final override = reportOverride;
    if (override != null) return override;
    final done = decisions.map((item) => item.conflict.unit).toSet();
    debugSetConflicts([
      for (final conflict in conflicts)
        if (!done.contains(conflict.unit)) conflict,
    ]);
    var local = 0;
    var remote = 0;
    for (final decision in decisions) {
      if (decision.choice == BackupConflictChoice.remote) {
        remote++;
      } else {
        local++;
      }
    }
    return SyncConflictApplyReport(localApplied: local, remoteApplied: remote);
  }

  @override
  Future<SyncSidePreview> loadConflictPreview(
    SyncConflict conflict,
    SyncPreviewSide side,
  ) async {
    previewCalls++;
    return buildPreview(side);
  }
}
