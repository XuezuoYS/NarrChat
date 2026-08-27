import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/providers/cloud_sync_provider.dart';
import 'package:narrchat/services/sync/sync_models.dart';
import 'package:narrchat/services/webdav_service.dart';

/// `CloudSyncProvider` 统一触发接口与分平面排队门控测试
///（不触碰真实网络 / 真库 / 真密钥库）：
/// - 自动触发门控（未配置 / 手动模式忽略，data / images / both 一律如此）；
/// - 分平面排队：执行中触发 → 对应平面置待跑；kind 精确影响所属平面；
/// - 取消只作用于目标平面（另一平面排队保留）；
/// - 生命周期轮询：每分钟静默触发两平面、回前台触发一次；
/// - 同步结果提示：失败驻留、可复制、可手动关闭。
void main() {
  test('triggerSync：未配置时忽略（全部 kind）', () {
    final provider = CloudSyncProvider()..debugSetConfigured(value: false);
    provider.triggerSync();
    provider.triggerSync(kind: SyncKind.data);
    provider.triggerSync(kind: SyncKind.images);
    expect(provider.debugPendingSyncRequested(SyncPlane.data), isFalse);
    expect(provider.debugPendingSyncRequested(SyncPlane.images), isFalse);
    expect(provider.dataSyncState, SyncState.idle);
    expect(provider.imageSyncState, SyncState.idle);
  });

  test('triggerSync：手动模式下忽略（含仅图片触发）', () {
    final provider = CloudSyncProvider()..debugSetConfigured(value: true);
    provider.debugSetSyncMode(SyncMode.manual);
    provider.triggerSync();
    provider.triggerSync(kind: SyncKind.images);
    expect(provider.debugPendingSyncRequested(SyncPlane.data), isFalse);
    expect(provider.debugPendingSyncRequested(SyncPlane.images), isFalse);
  });

  test('triggerSync：both 默认 → 两平面各自排队（同平面多次触发合并）', () {
    final provider = CloudSyncProvider()
      ..debugSetConfigured(value: true)
      ..debugSetLaneBusy(true); // 占用执行道：只验证排队归属，不发网络。
    provider.triggerSync();
    provider.triggerSync();
    expect(provider.debugPendingSyncRequested(SyncPlane.data), isTrue);
    expect(provider.debugPendingSyncRequested(SyncPlane.images), isTrue,
        reason: '统一触发要把图片补跑排进去');
  });

  test('triggerSync：kind=images 只排图片平面，不触碰数据平面', () {
    final provider = CloudSyncProvider()
      ..debugSetConfigured(value: true)
      ..debugSetLaneBusy(true);
    provider.triggerSync(kind: SyncKind.images);
    expect(provider.debugPendingSyncRequested(SyncPlane.images), isTrue);
    expect(provider.debugPendingSyncRequested(SyncPlane.data), isFalse,
        reason: '图片删除不产生数据平面工作（不推代数的结构保证）');
  });

  test('triggerSync：kind=data 只排数据平面', () {
    final provider = CloudSyncProvider()
      ..debugSetConfigured(value: true)
      ..debugSetLaneBusy(true);
    provider.triggerSync(kind: SyncKind.data);
    expect(provider.debugPendingSyncRequested(SyncPlane.data), isTrue);
    expect(provider.debugPendingSyncRequested(SyncPlane.images), isFalse);
  });

  test('取消同步：只清本平面排队与标记，另一平面不受影响', () {
    final provider = CloudSyncProvider()
      ..debugSetConfigured(value: true)
      ..debugSetLaneBusy(true);
    provider.triggerSync(); // 两平面都排队
    expect(provider.debugPendingSyncRequested(SyncPlane.data), isTrue);

    provider.cancelSync(SyncPlane.data);
    expect(provider.debugPendingSyncRequested(SyncPlane.data), isFalse);
    expect(provider.debugCancelRequested(SyncPlane.data), isTrue);
    expect(provider.debugPendingSyncRequested(SyncPlane.images), isTrue,
        reason: '取消数据不影响图片的删除意图传播');
    expect(provider.debugCancelRequested(SyncPlane.images), isFalse);
  });

  test('生命周期轮询：每分钟在后台静默触发两平面', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    fakeAsync((async) {
      final provider = CloudSyncProvider()
        ..debugSetConfigured(value: true)
        // 占用执行道：轮询触发不会真正发起网络同步，只会排队（验证触发本身）。
        ..debugSetLaneBusy(true);
      provider.attachLifecycle();
      expect(provider.debugPendingSyncRequested(SyncPlane.data), isFalse);

      async.elapse(const Duration(minutes: 2));
      expect(provider.debugPendingSyncRequested(SyncPlane.data), isTrue,
          reason: '每分钟应触发一次同步（空闲时合并为待跑）');
      expect(provider.debugPendingSyncRequested(SyncPlane.images), isTrue,
          reason: '轮询同时兜底图片收敛');
      provider.detachLifecycle();
    });
  });

  test('回前台（resumed）→ 触发一次两平面同步请求', () {
    final provider = CloudSyncProvider()
      ..debugSetConfigured(value: true)
      ..debugSetLaneBusy(true);
    provider.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(provider.debugPendingSyncRequested(SyncPlane.data), isTrue);
    expect(provider.debugPendingSyncRequested(SyncPlane.images), isTrue);
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
    CloudSyncProvider.showSyncSnack('图片同步失败：连接超时（HTTP 408）', persistent: true);
    await tester.pump();

    // 内容以 SelectableText 呈现（可长按选择复制）。
    expect(find.byType(SelectableText), findsOneWidget);
    expect(find.text('图片同步失败：连接超时（HTTP 408）'), findsOneWidget);
    expect(find.text('关闭'), findsOneWidget);

    // 驻留：较长时间后仍不消失。
    await tester.pump(const Duration(seconds: 10));
    expect(find.text('图片同步失败：连接超时（HTTP 408）'), findsOneWidget);

    // 手动关闭。
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('图片同步失败：连接超时（HTTP 408）'), findsNothing);
  });

  testWidgets('showSyncSnack：普通消息自动消失', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        scaffoldMessengerKey: CloudSyncProvider.messengerKey,
        home: const Scaffold(body: SizedBox()),
      ),
    );
    CloudSyncProvider.showSyncSnack('数据已同步到云端（第 3 代）');
    await tester.pump();
    // 入场动画完成（停留计时从此时开始）。
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('数据已同步到云端（第 3 代）'), findsOneWidget);
    expect(find.text('关闭'), findsNothing);

    // 超过停留时长（4s）后自动消失。
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.text('数据已同步到云端（第 3 代）'), findsNothing);
  });
}
