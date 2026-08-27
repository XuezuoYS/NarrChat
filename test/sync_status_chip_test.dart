import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/providers/cloud_sync_provider.dart';
import 'package:narrchat/services/sync/sync_models.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/sync_status_chip.dart';
import 'package:provider/provider.dart';

/// 同步状态章 widget 测试。
void main() {
  Future<CloudSyncProvider> pumpChip(
    WidgetTester tester, {
    SyncState state = SyncState.idle,
    bool configured = true,
  }) async {
    final provider = CloudSyncProvider();
    provider.debugSetConfigured(value: configured);
    provider.debugSetSyncState(state);
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

  testWidgets('已连接(idle)：显示「已连接」', (tester) async {
    await pumpChip(tester, state: SyncState.idle);
    expect(find.text('已连接'), findsOneWidget);
  });

  testWidgets('同步中：显示「同步中…」', (tester) async {
    await pumpChip(tester, state: SyncState.syncing);
    expect(find.text('同步中…'), findsOneWidget);
  });

  testWidgets('成功：显示「已同步」', (tester) async {
    await pumpChip(tester, state: SyncState.success);
    expect(find.text('已同步'), findsOneWidget);
  });

  testWidgets('失败：显示「同步失败」', (tester) async {
    await pumpChip(tester, state: SyncState.error);
    expect(find.text('同步失败'), findsOneWidget);
  });
}
