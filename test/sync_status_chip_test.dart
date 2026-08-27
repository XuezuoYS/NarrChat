import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/providers/cloud_sync_provider.dart';
import 'package:narrchat/services/sync/sync_models.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/sync_status_chip.dart';
import 'package:provider/provider.dart';

/// 同步状态章 widget 测试：两平面聚合为单枚指示，文案区分平面。
void main() {
  Future<CloudSyncProvider> pumpChip(
    WidgetTester tester, {
    SyncState data = SyncState.idle,
    SyncState images = SyncState.idle,
    bool configured = true,
  }) async {
    final provider = CloudSyncProvider();
    provider.debugSetConfigured(value: configured);
    provider.debugSetSyncState(SyncPlane.data, data);
    provider.debugSetSyncState(SyncPlane.images, images);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: provider,
        child: MaterialApp(
          theme: NarrChatTheme.light,
          home: Scaffold(body: Center(child: SyncStatusChip())),
        ),
      ),
    );
    await tester.pump();
    return provider;
  }

  testWidgets('未配置：不显示胶囊', (tester) async {
    await pumpChip(tester, configured: false);
    expect(find.byType(SyncStatusChip), findsOneWidget);
    expect(find.textContaining('已'), findsNothing);
    expect(find.textContaining('同步'), findsNothing);
  });

  testWidgets('两平面均空闲：显示「已连接」', (tester) async {
    await pumpChip(tester);
    expect(find.text('已连接'), findsOneWidget);
  });

  testWidgets('仅数据平面同步中：显示「数据同步中…」', (tester) async {
    await pumpChip(tester, data: SyncState.syncing);
    expect(find.text('数据同步中…'), findsOneWidget);
  });

  testWidgets('仅图片平面同步中：显示「图片同步中…」', (tester) async {
    await pumpChip(tester, images: SyncState.syncing);
    expect(find.text('图片同步中…'), findsOneWidget);
  });

  testWidgets('两平面同时同步：聚合为「同步中…」', (tester) async {
    await pumpChip(
      tester,
      data: SyncState.syncing,
      images: SyncState.syncing,
    );
    expect(find.text('同步中…'), findsOneWidget);
  });

  testWidgets('任一平面失败：优先显示「同步失败」（另一平面成功不遮蔽）', (tester) async {
    await pumpChip(
      tester,
      data: SyncState.error,
      images: SyncState.success,
    );
    expect(find.text('同步失败'), findsOneWidget);
  });

  testWidgets('任一平面成功（无同步中/失败）：显示「已同步」', (tester) async {
    await pumpChip(tester, images: SyncState.success);
    expect(find.text('已同步'), findsOneWidget);
  });
}
