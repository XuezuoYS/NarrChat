import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/providers/cloud_sync_provider.dart';
import 'package:narrchat/providers/round_provider.dart';
import 'package:narrchat/services/sync/sync_models.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/sync_hud.dart';
import 'package:provider/provider.dart';

import 'helpers/fakes.dart';

/// 假 RoundProvider：可控返回「正在生成的书 uuid」，供 HUD 避让横幅测试。
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
}

void main() {
  Future<CloudSyncProvider> pumpHud(
    WidgetTester tester, {
    SyncState dataState = SyncState.idle,
    SyncState imageState = SyncState.idle,
    SyncProgressEvent? dataProgress,
    SyncProgressEvent? imageProgress,
    RoundProvider? roundProvider,
    Size size = const Size(1400, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final provider = CloudSyncProvider();
    provider.debugSetSyncState(SyncPlane.data, dataState);
    provider.debugSetSyncState(SyncPlane.images, imageState);
    if (dataProgress != null) {
      provider.debugSetProgress(SyncPlane.data, dataProgress);
    }
    if (imageProgress != null) {
      provider.debugSetProgress(SyncPlane.images, imageProgress);
    }

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

  testWidgets('两平面均空闲：不显示悬浮条', (tester) async {
    await pumpHud(tester);
    expect(find.byType(SyncHud), findsOneWidget);
    expect(find.byIcon(Icons.close), findsNothing);
  });

  testWidgets('仅数据平面同步：单段无分隔线，含平面名与取消按钮', (tester) async {
    await pumpHud(
      tester,
      dataState: SyncState.syncing,
      dataProgress: const SyncProgressEvent(
        phase: SyncPhase.pullManifest,
        label: '读取云端清单…',
      ),
    );
    expect(find.text('数据同步 · 读取云端清单'), findsOneWidget);
    expect(find.textContaining('图片同步'), findsNothing,
        reason: '未同步的平面不出段');
    expect(find.byIcon(Icons.close), findsOneWidget, reason: '单平面单取消');
  });

  testWidgets('两平面同时在跑：单胶囊双段（数据 · 图片），各自取消按钮与进度',
      (tester) async {
    await pumpHud(
      tester,
      dataState: SyncState.syncing,
      imageState: SyncState.syncing,
      dataProgress: const SyncProgressEvent(
        phase: SyncPhase.pushSnapshot,
        label: '上传快照…',
      ),
      imageProgress: const SyncProgressEvent(
        phase: SyncPhase.pushImages,
        label: '上传图片',
        currentItem: 2,
        totalItems: 30,
      ),
    );
    expect(find.text('数据同步 · 上传快照'), findsOneWidget);
    expect(find.text('图片同步 · 上传图片 · 3/30'), findsOneWidget);
    expect(find.byIcon(Icons.close), findsNWidgets(2),
        reason: '每段一个独立取消按钮');
    expect(find.byIcon(Icons.drag_indicator), findsOneWidget,
        reason: '仍是同一枚胶囊（一个拖动手柄）');
  });

  testWidgets('图片平面进度条独立于数据平面（fraction 各自渲染）', (tester) async {
    await pumpHud(
      tester,
      imageState: SyncState.syncing,
      imageProgress: const SyncProgressEvent(
        phase: SyncPhase.pullImages,
        label: '下载图片',
        currentItem: 2,
        totalItems: 4,
      ),
    );
    final bar = tester.widget<LinearProgressIndicator>(
      find.descendant(
        of: find.byType(SyncHud),
        matching: find.byType(LinearProgressIndicator),
      ),
    );
    // fraction = currentItem / totalItems（0 基）＝已完整完成 2/4。
    expect(bar.value, closeTo(0.5, 0.001));
  });

  testWidgets('拖动手柄：同步中显示拖拽图标与提示', (tester) async {
    await pumpHud(tester, dataState: SyncState.syncing);
    expect(find.byIcon(Icons.drag_indicator), findsOneWidget);
    // 悬停/聚焦提示「此框可拖动」。
    expect(find.byTooltip('拖动可移动位置'), findsOneWidget);
  });

  testWidgets('拖动方向：水平右拖 / 垂直下拖均随手势同向（水平方向修正）', (tester) async {
    await pumpHud(
      tester,
      dataState: SyncState.syncing,
      dataProgress: const SyncProgressEvent(
        phase: SyncPhase.pullManifest,
        label: '读取清单',
      ),
    );
    final before = tester.getCenter(find.byIcon(Icons.drag_indicator));

    await tester.drag(find.byIcon(Icons.drag_indicator), const Offset(120, 40));
    await tester.pump();

    final after = tester.getCenter(find.byIcon(Icons.drag_indicator));
    expect(
      after.dx - before.dx,
      greaterThan(60),
      reason: '水平拖动应与手势同向（原先反向）',
    );
    expect(after.dy - before.dy, greaterThan(20), reason: '垂直拖动应随手势下移');
  });

  testWidgets('不记忆拖动位置：消失后再次显示回到默认位置', (tester) async {
    final provider = await pumpHud(
      tester,
      dataState: SyncState.syncing,
      dataProgress: const SyncProgressEvent(
        phase: SyncPhase.pullManifest,
        label: '读取清单',
      ),
    );
    // 默认位置基准（未拖动）。
    final base = tester.getCenter(find.byIcon(Icons.drag_indicator));
    // 拖到新的位置。
    await tester.drag(find.byIcon(Icons.drag_indicator), const Offset(120, 40));
    await tester.pump();
    final dragged = tester.getCenter(find.byIcon(Icons.drag_indicator));
    expect((dragged.dx - base.dx).abs(), greaterThan(60));

    // 同步结束（HUD 消失）→ 再次同步（HUD 重新出现）：应回到默认位置。
    provider.debugSetSyncState(SyncPlane.data, SyncState.success);
    await tester.pump();
    expect(find.byIcon(Icons.drag_indicator), findsNothing);

    provider.debugSetSyncState(SyncPlane.data, SyncState.syncing);
    await tester.pump();
    final again = tester.getCenter(find.byIcon(Icons.drag_indicator));
    expect((again.dx - base.dx).abs(), lessThan(1), reason: '消失后水平位置回到默认');
    expect((again.dy - base.dy).abs(), lessThan(1), reason: '消失后垂直位置回到默认');
  });

  testWidgets('收起/展开切换（两平面共享一个折叠按钮）', (tester) async {
    await pumpHud(
      tester,
      dataState: SyncState.syncing,
      imageState: SyncState.syncing,
      dataProgress: const SyncProgressEvent(
        phase: SyncPhase.pullManifest,
        label: '读取清单',
      ),
    );
    // 展开态有收起按钮（expand_less）。
    expect(find.byIcon(Icons.expand_less), findsOneWidget);
    await tester.tap(find.byIcon(Icons.expand_less));
    await tester.pump();
    expect(find.byIcon(Icons.expand_more), findsOneWidget);
    // 收起后详情文本消失，但两段的取消按钮仍在。
    expect(find.textContaining('读取清单'), findsNothing);
    expect(find.byIcon(Icons.close), findsNWidgets(2));
  });

  testWidgets('窄屏不溢出', (tester) async {
    await pumpHud(
      tester,
      dataState: SyncState.syncing,
      imageState: SyncState.syncing,
      dataProgress: const SyncProgressEvent(
        phase: SyncPhase.pushSnapshot,
        label: '上传快照及长文件名测试',
      ),
      imageProgress: const SyncProgressEvent(
        phase: SyncPhase.pushImages,
        label: '上传超长中文文件名测试图片.png',
        currentItem: 9,
        totalItems: 10,
      ),
      size: const Size(320, 640),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('点某段取消：只置对应平面的取消标记', (tester) async {
    final provider = await pumpHud(
      tester,
      dataState: SyncState.syncing,
      imageState: SyncState.syncing,
      dataProgress: const SyncProgressEvent(
        phase: SyncPhase.merge,
        label: '合并数据',
      ),
    );
    expect(provider.debugCancelRequested(SyncPlane.data), isFalse);
    expect(provider.debugCancelRequested(SyncPlane.images), isFalse);

    // 段顺序固定「数据 │ 图片」：last = 图片段取消按钮。
    await tester.tap(find.byIcon(Icons.close).last);
    await tester.pump();
    expect(provider.debugCancelRequested(SyncPlane.images), isTrue);
    expect(provider.debugCancelRequested(SyncPlane.data), isFalse,
        reason: '取消图片同步不影响正在合并的数据平面');

    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pump();
    expect(provider.debugCancelRequested(SyncPlane.data), isTrue);
  });

  testWidgets('GenerationBanner 可见时不遮挡：仍正常渲染', (tester) async {
    await pumpHud(
      tester,
      dataState: SyncState.syncing,
      dataProgress: const SyncProgressEvent(
        phase: SyncPhase.pullManifest,
        label: '读取清单',
      ),
      roundProvider: _FakeRoundProvider(const ['b1', 'b2']),
    );
    expect(find.textContaining('读取清单'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}