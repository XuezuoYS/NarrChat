import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/providers/cloud_sync_provider.dart';
import 'package:narrchat/services/sync/sync_models.dart';
import 'package:narrchat/services/webdav_service.dart';

/// `CloudSyncProvider` 纯逻辑单元测试（不触碰真实网络 / 真库 / 真密钥库）：
/// - 自动同步触发门控（未配置 / 手动模式忽略）；
/// - 同步队列：进行中再触发 → 排队补跑；取消清空排队；
/// - 生命周期轮询：每分钟静默触发一次、回前台触发一次；
/// - 同步结果提示：失败驻留、可复制、可手动关闭。
void main() {
  test('triggerAutoSync：未配置时忽略', () {
    final provider = CloudSyncProvider()..debugSetConfigured(value: false);
    provider.triggerAutoSync();
    expect(provider.debugPendingSyncRequested, isFalse);
    expect(provider.syncState, SyncState.idle);
  });

  test('triggerAutoSync：手动模式下忽略', () {
    final provider = CloudSyncProvider()..debugSetConfigured(value: true);
    // 手动模式：不自动同步（改状态即可，无需写配置）。
    provider.debugSetSyncMode(SyncMode.manual);
    provider.triggerAutoSync();
    expect(provider.debugPendingSyncRequested, isFalse);
  });

  test('triggerAutoSync：同步进行中 → 排队（合并多次触发）', () {
    final provider = CloudSyncProvider()..debugSetConfigured(value: true);
    provider.debugSetBusy(true);
    provider.triggerAutoSync();
    provider.triggerAutoSync();
    provider.triggerAutoSync();
    expect(provider.debugPendingSyncRequested, isTrue, reason: '多次触发合并为一个待跑');
  });

  test('取消同步清空排队的自动同步', () {
    final provider = CloudSyncProvider()..debugSetConfigured(value: true);
    provider.debugSetBusy(true);
    provider.triggerAutoSync();
    expect(provider.debugPendingSyncRequested, isTrue);

    provider.debugSetSyncState(SyncState.syncing);
    provider.cancelSync();
    expect(provider.debugPendingSyncRequested, isFalse);
    expect(provider.debugCancelRequested, isTrue);  });

  test('生命周期轮询：每分钟在后台触发一次静默同步', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    fakeAsync((async) {
      final provider = CloudSyncProvider()
        ..debugSetConfigured(value: true)
        // 置忙：轮询触发不会真正发起网络同步，只会排队（验证触发本身）。
        ..debugSetBusy(true);
      provider.attachLifecycle();
      expect(provider.debugPendingSyncRequested, isFalse);

      async.elapse(const Duration(minutes: 2));
      expect(provider.debugPendingSyncRequested, isTrue,
          reason: '每分钟应触发一次同步（空闲时合并为待跑）');
      provider.detachLifecycle();
    });
  });

  test('回前台（resumed）→ 触发一次同步请求', () {
    final provider = CloudSyncProvider()
      ..debugSetConfigured(value: true)
      ..debugSetBusy(true);
    provider.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(provider.debugPendingSyncRequested, isTrue);
  });

  test('compareSnapshots：按代际新 → 旧，同代按文件名（内嵌时间）倒序', () {
    final files = [
      const WebDavFile(name: 'narrchat_snapshot_g2_20260816_100000.db'),
      const WebDavFile(name: 'narrchat_snapshot_g7_20260816_120000.db'),
      const WebDavFile(name: 'narrchat_snapshot_g5_20260816_110000.db'),
      const WebDavFile(name: 'narrchat_snapshot_g5_20260816_090000.db'),
    ]..sort(CloudSyncProvider.compareSnapshots);
    expect(
      files.map((f) => f.name).toList(),
      [
        'narrchat_snapshot_g7_20260816_120000.db',
        'narrchat_snapshot_g5_20260816_110000.db',
        'narrchat_snapshot_g5_20260816_090000.db',
        'narrchat_snapshot_g2_20260816_100000.db',
      ],
    );
  });

  testWidgets('showSyncSnack：失败消息驻留、内容可复制、可手动关闭', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        scaffoldMessengerKey: CloudSyncProvider.messengerKey,
        home: const Scaffold(body: SizedBox()),
      ),
    );
    CloudSyncProvider.showSyncSnack('同步失败：连接超时（HTTP 408）', persistent: true);
    await tester.pump();

    // 内容以 SelectableText 呈现（可长按选择复制）。
    expect(find.byType(SelectableText), findsOneWidget);
    expect(find.text('同步失败：连接超时（HTTP 408）'), findsOneWidget);
    expect(find.text('关闭'), findsOneWidget);

    // 驻留：较长时间后仍不消失。
    await tester.pump(const Duration(seconds: 10));
    expect(find.text('同步失败：连接超时（HTTP 408）'), findsOneWidget);

    // 手动关闭。
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('同步失败：连接超时（HTTP 408）'), findsNothing);
  });

  testWidgets('showSyncSnack：普通消息自动消失', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        scaffoldMessengerKey: CloudSyncProvider.messengerKey,
        home: const Scaffold(body: SizedBox()),
      ),
    );
    CloudSyncProvider.showSyncSnack('已同步到云端（第 3 代）');
    await tester.pump();
    // 入场动画完成（停留计时从此时开始）。
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('已同步到云端（第 3 代）'), findsOneWidget);
    expect(find.text('关闭'), findsNothing);

    // 超过停留时长（4s）后自动消失。
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.text('已同步到云端（第 3 代）'), findsNothing);
  });
}
