import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/sync/sync_coordinator.dart';
import 'package:narrchat/services/sync/sync_models.dart';

/// [SyncCoordinator] 测试：统一触发 → 单执行道串行派发 + 分平面生命周期。
///
/// 用可控 Completer 的假任务处理器验证（无网络 / 无 Runner）：
/// - 排队合并（执行中触发 → 待跑一位，多次触发合并为一次补跑）；
/// - 双平面同时待跑时**数据优先**；
/// - 分平面取消（运行中 → 协作式标记；待跑 → 撤销排队；另一平面不受影响）；
/// - 分平面状态 / 进度互相独立；
/// - 静默标记与运算合并（任一非静默触发 → 不静默）。
void main() {
  late List<SyncTaskContext> started;
  late List<(SyncPlane, SyncTaskOutcome, bool)> finished;
  late Map<SyncPlane, Completer<SyncTaskOutcome>> pending;
  late int notifyCount;
  late SyncCoordinator coordinator;

  setUp(() {
    started = [];
    finished = [];
    pending = {};
    notifyCount = 0;
    coordinator = SyncCoordinator(
      runTask: (ctx) {
        started.add(ctx);
        final c = Completer<SyncTaskOutcome>();
        pending[ctx.plane] = c;
        return c.future;
      },
      onChanged: () => notifyCount++,
      onResult: (plane, outcome, silent) =>
          finished.add((plane, outcome, silent)),
    );
  });

  /// 完成当前运行中平面的任务。
  Future<void> complete(SyncPlane plane, SyncTaskOutcome outcome) async {
    pending.remove(plane)!.complete(outcome);
    // 让出事件循环：_execute 的 await 恢复、状态落定与自动补跑全部完成。
    await Future<void>.delayed(Duration.zero);
  }

  test('空闲触发 → 立即执行该平面，状态 syncing', () {
    coordinator.trigger(SyncPlane.images);
    expect(started.single.plane, SyncPlane.images);
    expect(coordinator.stateOf(SyncPlane.images), SyncState.syncing);
    expect(coordinator.stateOf(SyncPlane.data), SyncState.idle,
        reason: '另一平面状态不被遮蔽');
    expect(coordinator.isRunning, isTrue);
  });

  test('执行中再触发 → 合并为一次补跑（成功结束后自动执行）', () async {
    coordinator.trigger(SyncPlane.data);
    coordinator.trigger(SyncPlane.data);
    coordinator.trigger(SyncPlane.data);
    expect(started, hasLength(1));
    expect(coordinator.pendingOf(SyncPlane.data), isTrue);

    await complete(SyncPlane.data, const SyncTaskOutcome(SyncState.success));
    expect(started, hasLength(2), reason: '补跑一次（多次触发合并）');
    expect(coordinator.pendingOf(SyncPlane.data), isFalse);
  });

  test('双平面同时待跑 → 数据优先（数据落地改变图片引用集）', () async {
    coordinator.trigger(SyncPlane.data); // 立即执行
    coordinator.trigger(SyncPlane.images); // 排队
    coordinator.trigger(SyncPlane.data); // 合并到数据待跑
    expect(started.map((c) => c.plane).toList(), [SyncPlane.data]);

    await complete(SyncPlane.data, const SyncTaskOutcome(SyncState.success));
    // 数据待跑 + 图片待跑同时存在 → 先补数据。
    expect(started.last.plane, SyncPlane.data);
    await complete(SyncPlane.data, const SyncTaskOutcome(SyncState.success));
    expect(started.last.plane, SyncPlane.images);
  });

  test('两平面串行不并发：图片等待数据释放执行道', () async {
    coordinator.trigger(SyncPlane.data);
    coordinator.trigger(SyncPlane.images);
    // 数据在跑：图片仅排队，runTask 未被第二次调用。
    expect(started, hasLength(1));

    await complete(SyncPlane.data, const SyncTaskOutcome(SyncState.success));
    expect(started, hasLength(2));
    expect(started[1].plane, SyncPlane.images);
    expect(coordinator.stateOf(SyncPlane.data), SyncState.success);
    expect(coordinator.stateOf(SyncPlane.images), SyncState.syncing);
  });

  test('取消运行中平面：本平面 cancel 标记生效，另一平面排队不受影响', () {
    coordinator.trigger(SyncPlane.data);
    coordinator.trigger(SyncPlane.images);
    coordinator.cancel(SyncPlane.data);

    final ctx = started.single;
    expect(ctx.isCancelled(), isTrue, reason: 'Runner 阶段间可感知取消');
    expect(coordinator.pendingOf(SyncPlane.images), isTrue,
        reason: '只取消数据平面，图片排队保留');
    expect(coordinator.debugCancelRequested(SyncPlane.images), isFalse);
  });

  test('取消待跑平面：撤销排队（结束后不补跑）', () async {
    coordinator.trigger(SyncPlane.data);
    coordinator.trigger(SyncPlane.data); // 待跑
    coordinator.cancel(SyncPlane.data);

    await complete(SyncPlane.data, const SyncTaskOutcome(SyncState.success));
    expect(started, hasLength(1), reason: '待跑被取消，无补跑');
    expect(coordinator.stateOf(SyncPlane.data), SyncState.success);
  });

  test('取消标记在下一次运行开始时复位', () async {
    coordinator.trigger(SyncPlane.data);
    coordinator.cancel(SyncPlane.data);
    await complete(SyncPlane.data, const SyncTaskOutcome(SyncState.idle));

    coordinator.trigger(SyncPlane.data);
    expect(started.last.isCancelled(), isFalse, reason: '新任务不被旧取消污染');
  });

  test('静默与运算合并：执行中触发继承非静默（手动点击需要结果提示）', () async {
    coordinator.trigger(SyncPlane.data, silent: true); // 立即执行（轮询）
    coordinator.trigger(SyncPlane.data, silent: false); // 手动点击并入待跑
    await complete(SyncPlane.data, const SyncTaskOutcome(SyncState.success));

    expect(started, hasLength(2));
    expect(started[0].silent, isTrue, reason: '首发按自己的静默标记执行');
    expect(started[1].silent, isFalse, reason: '任一非静默触发 → 补跑不静默');
  });

  test('进度 / 结果按平面上报；结果回调携带静默标记', () async {
    coordinator.trigger(SyncPlane.images, silent: true);
    final ctx = started.single;
    ctx.reportProgress(
      const SyncProgressEvent(phase: SyncPhase.pushImages, label: '上传图片'),
    );
    expect(coordinator.progressOf(SyncPlane.images)!.phase, SyncPhase.pushImages);
    expect(coordinator.progressOf(SyncPlane.data), isNull);

    await complete(
      SyncPlane.images,
      const SyncTaskOutcome(SyncState.success, message: '图片同步完成'),
    );
    final (plane, outcome, silent) = finished.single;
    expect(plane, SyncPlane.images);
    expect(outcome.message, '图片同步完成');
    expect(silent, isTrue, reason: '静默标记随结果透传');
    expect(coordinator.progressOf(SyncPlane.images), isNull,
        reason: '结束后进度清空');
  });

  test('任务抛异常 → 平面落到 error，执行道继续服务另一平面', () async {
    coordinator = SyncCoordinator(
      runTask: (ctx) async {
        started.add(ctx);
        if (ctx.plane == SyncPlane.data) throw StateError('boom');
        return const SyncTaskOutcome(SyncState.success);
      },
      onChanged: () => notifyCount++,
      onResult: (plane, outcome, silent) => finished.add((plane, outcome, silent)),
    );
    coordinator.trigger(SyncPlane.data);
    await Future<void>.delayed(Duration.zero);
    expect(coordinator.stateOf(SyncPlane.data), SyncState.error);
    expect(finished.single.$2.persistent, isTrue, reason: '异常按失败驻留');

    // 执行道已释放：图片平面可继续。
    coordinator.trigger(SyncPlane.images);
    await Future<void>.delayed(Duration.zero);
    expect(coordinator.stateOf(SyncPlane.images), SyncState.success);
  });

  test('onIdle：全部执行道排空后完成', () async {
    coordinator.trigger(SyncPlane.data);
    coordinator.trigger(SyncPlane.images);
    var done = false;
    unawaited(coordinator.onIdle.then((_) => done = true));

    await complete(SyncPlane.data, const SyncTaskOutcome(SyncState.success));
    await Future<void>.delayed(Duration.zero);
    expect(done, isFalse, reason: '图片平面还在跑');
    await complete(SyncPlane.images, const SyncTaskOutcome(SyncState.success));
    await Future<void>.delayed(Duration.zero);
    expect(done, isTrue);
  });

  test('debugSetLaneBusy：强制占用执行道（触发只排队）', () {
    coordinator.debugSetLaneBusy(true);
    coordinator.trigger(SyncPlane.data);
    coordinator.trigger(SyncPlane.images);
    expect(started, isEmpty);
    expect(coordinator.pendingOf(SyncPlane.data), isTrue);
    expect(coordinator.pendingOf(SyncPlane.images), isTrue);

    coordinator.debugSetLaneBusy(false);
    expect(started, hasLength(1), reason: '解除占用后自动补跑（数据优先）');
    expect(started.single.plane, SyncPlane.data);
  });
}
