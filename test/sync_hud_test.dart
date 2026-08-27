import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/providers/cloud_sync_provider.dart';
import 'package:narrchat/providers/round_provider.dart';
import 'package:narrchat/services/sync/sync_models.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/sync_hud.dart';
import 'package:provider/provider.dart';

import 'helpers/fakes.dart';

/// 假 RoundProvider：可控返回「正在生成的书」，供 HUD 避让横幅测试。
class _FakeRoundProvider extends RoundProvider {
  _FakeRoundProvider(this.ids)
      : super(
          dao: FakeRoundDao(),
          aiService: ToggleAiService(),
          bookDao: FakeBookDao(),
        );

  final List<int> ids;

  @override
  List<int> get activeGenerationBookIds => ids;
}

void main() {
  Future<CloudSyncProvider> pumpHud(
    WidgetTester tester, {
    SyncState? state,
    SyncProgressEvent? progress,
    RoundProvider? roundProvider,
    Size size = const Size(1400, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final provider = CloudSyncProvider();
    if (state != null) provider.debugSetSyncState(state);
    if (progress != null) provider.debugSetProgress(progress);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: provider),
          ChangeNotifierProvider.value(
            value: roundProvider ?? _FakeRoundProvider(const []),
          ),
        ],
        child: MaterialApp(
          theme: NarrChatTheme.light,
          home: const Scaffold(body: SizedBox.expand()),
          // 与真实应用一致：HUD / Tooltip 位于 Navigator 之上，需要独立 Overlay。
          builder: (context, child) => Overlay(
            initialEntries: [
              OverlayEntry(
                builder: (_) => Stack(
                  fit: StackFit.expand,
                  children: [
                    child ?? const SizedBox.shrink(),
                    const SyncHud(),
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

  testWidgets('非同步（idle）：不显示悬浮条', (tester) async {
    await pumpHud(tester, state: SyncState.idle);
    expect(find.byType(SyncHud), findsOneWidget);
    expect(find.byIcon(Icons.close), findsNothing);
  });

  testWidgets('同步中：展示阶段标签与取消按钮', (tester) async {
    await pumpHud(
      tester,
      state: SyncState.syncing,
      progress: const SyncProgressEvent(
        phase: SyncPhase.pushImages,
        label: '上传图片',
      ),
    );
    expect(find.textContaining('上传图片'), findsOneWidget);
    expect(find.byIcon(Icons.close), findsOneWidget);
  });

  testWidgets('拖动手柄：同步中显示拖拽图标与提示', (tester) async {
    await pumpHud(tester, state: SyncState.syncing);
    expect(find.byIcon(Icons.drag_indicator), findsOneWidget);
    // 悬停/聚焦提示「此框可拖动」。
    expect(find.byTooltip('拖动可移动位置'), findsOneWidget);
  });

  testWidgets('拖动方向：水平右拖 / 垂直下拖均随手势同向（水平方向修正）', (tester) async {
    await pumpHud(
      tester,
      state: SyncState.syncing,
      progress: const SyncProgressEvent(phase: SyncPhase.pullManifest, label: '读取清单'),
    );
    final before = tester.getCenter(find.byIcon(Icons.drag_indicator));

    await tester.drag(find.byIcon(Icons.drag_indicator), const Offset(120, 40));
    await tester.pump();

    final after = tester.getCenter(find.byIcon(Icons.drag_indicator));
    expect(after.dx - before.dx, greaterThan(60), reason: '水平拖动应与手势同向（原先反向）');
    expect(after.dy - before.dy, greaterThan(20), reason: '垂直拖动应随手势下移');
  });

  testWidgets('不记忆拖动位置：消失后再次显示回到默认位置', (tester) async {
    final provider = await pumpHud(
      tester,
      state: SyncState.syncing,
      progress: const SyncProgressEvent(phase: SyncPhase.pullManifest, label: '读取清单'),
    );
    // 默认位置基准（未拖动）。
    final base = tester.getCenter(find.byIcon(Icons.drag_indicator));
    // 拖到新的位置。
    await tester.drag(find.byIcon(Icons.drag_indicator), const Offset(120, 40));
    await tester.pump();
    final dragged = tester.getCenter(find.byIcon(Icons.drag_indicator));
    expect((dragged.dx - base.dx).abs(), greaterThan(60));

    // 同步结束（HUD 消失）→ 再次同步（HUD 重新出现）：应回到默认位置。
    provider.debugSetSyncState(SyncState.success);
    await tester.pump();
    expect(find.byIcon(Icons.drag_indicator), findsNothing);

    provider.debugSetSyncState(SyncState.syncing);
    await tester.pump();
    final again = tester.getCenter(find.byIcon(Icons.drag_indicator));
    expect((again.dx - base.dx).abs(), lessThan(1), reason: '消失后水平位置回到默认');
    expect((again.dy - base.dy).abs(), lessThan(1), reason: '消失后垂直位置回到默认');
  });

  testWidgets('收起/展开切换', (tester) async {
    await pumpHud(
      tester,
      state: SyncState.syncing,
      progress: const SyncProgressEvent(phase: SyncPhase.pullManifest, label: '读取清单'),
    );
    // 展开态有收起按钮（expand_less）。
    expect(find.byIcon(Icons.expand_less), findsOneWidget);
    await tester.tap(find.byIcon(Icons.expand_less));
    await tester.pump();
    expect(find.byIcon(Icons.expand_more), findsOneWidget);
  });

  testWidgets('窄屏不溢出', (tester) async {
    await pumpHud(
      tester,
      state: SyncState.syncing,
      progress: const SyncProgressEvent(
        phase: SyncPhase.pushSnapshot,
        label: '上传快照及长文件名测试',
      ),
      size: const Size(320, 640),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('点取消：同步取消标记置位', (tester) async {
    final provider = await pumpHud(
      tester,
      state: SyncState.syncing,
      progress: const SyncProgressEvent(phase: SyncPhase.merge, label: '合并'),
    );
    expect(provider.debugCancelRequested, isFalse);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(provider.debugCancelRequested, isTrue);
  });

  testWidgets('GenerationBanner 可见时不遮挡：仍正常渲染', (tester) async {
    await pumpHud(
      tester,
      state: SyncState.syncing,
      progress: const SyncProgressEvent(
        phase: SyncPhase.pullManifest,
        label: '读取清单',
      ),
      roundProvider: _FakeRoundProvider(const [1, 2]),
    );
    expect(find.textContaining('读取清单'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
