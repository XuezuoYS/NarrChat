import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/providers/cloud_sync_provider.dart';
import 'package:narrchat/services/sync/sync_models.dart';
import 'package:narrchat/services/webdav_service.dart';

/// `CloudSyncProvider` 统一触发接口与分平面排队门控测试
///（不触碰真实网络 / 真库 / 真密钥库）：
/// - 自动触发门控（未配置 / 手动模式忽略，data / images / both 一律如此）；
/// - 分平面排队：执行中触发 → 对应平面置待跑；kind 精确影响所属平面；
/// - 取消只作用于目标平面（另一平面排队保留）；
/// - 生命周期：空闲不产生任何定时轮询；回前台触发 + 2 分钟节流窗口；
/// - 结果提示队列：同文案去重、上限挤掉最早提示、按 id 关闭移除
///   （气泡渲染与自动消失 / 驻留关闭语义见 sync_result_bubble_test.dart）。
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

  /// 构造「已配置 + 自动模式 + 执行道被占用」的 provider：
  /// 触发只排队、不触碰真实网络，便于断言触发本身。
  CloudSyncProvider laneBusyProvider({DateTime Function()? now}) {
    TestWidgetsFlutterBinding.ensureInitialized();
    final provider = CloudSyncProvider()
      ..debugSetConfigured(value: true)
      ..debugSetLaneBusy(true);
    provider.debugSetNow(now);
    provider.debugClearSyncRequestAt();
    return provider;
  }

  /// 撤销排队位（把"已触发"复位成"空闲"，不引入真实任务执行）。
  void clearQueue(CloudSyncProvider provider) {
    provider.cancelSync(SyncPlane.data);
    provider.cancelSync(SyncPlane.images);
  }

  test('空闲不轮询：attachLifecycle 之后停留 30 分钟也不产生任何同步', () {
    fakeAsync((async) {
      final provider = laneBusyProvider();
      provider.attachLifecycle();
      expect(provider.debugPendingSyncRequested(SyncPlane.data), isFalse);

      async.elapse(const Duration(minutes: 30));
      expect(provider.debugPendingSyncRequested(SyncPlane.data), isFalse,
          reason: '自动同步只由用户操作节点发起，空闲时不得打网络');
      expect(provider.debugPendingSyncRequested(SyncPlane.images), isFalse,
          reason: '图片平面同样不再有定时兜底（随下一次操作节点收敛）');
      expect(async.pendingTimers, isEmpty, reason: 'provider 不再挂任何定时器');
      provider.detachLifecycle();
    });
  });

  test('回前台（resumed）→ 本次运行首次触发两平面同步请求', () {
    final base = DateTime(2026, 8, 28, 10);
    final provider = laneBusyProvider(now: () => base);

    provider.didChangeAppLifecycleState(AppLifecycleState.inactive);
    expect(provider.debugPendingSyncRequested(SyncPlane.data), isFalse,
        reason: '非 resumed 生命周期状态不触发');

    provider.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(provider.debugPendingSyncRequested(SyncPlane.data), isTrue);
    expect(provider.debugPendingSyncRequested(SyncPlane.images), isTrue);
    expect(provider.lastSyncRequestAt, base);
  });

  test('回前台节流：距上次同步请求不足 2 分钟时跳过，满窗口后恢复触发', () {
    final base = DateTime(2026, 8, 28, 10);
    DateTime now = base;
    final provider = laneBusyProvider(now: () => now);

    provider.didChangeAppLifecycleState(AppLifecycleState.resumed);
    clearQueue(provider);

    now = base.add(const Duration(minutes: 1, seconds: 59));
    provider.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(provider.debugPendingSyncRequested(SyncPlane.data), isFalse,
        reason: '节流窗口内的回前台不再重复打网络');
    expect(provider.debugPendingSyncRequested(SyncPlane.images), isFalse);
    expect(provider.lastSyncRequestAt, base, reason: '被跳过的触发不改写基准时刻');

    now = base.add(const Duration(minutes: 2));
    provider.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(provider.debugPendingSyncRequested(SyncPlane.data), isTrue,
        reason: '窗口结束后回前台重新触发');
    expect(provider.debugPendingSyncRequested(SyncPlane.images), isTrue);
    expect(provider.lastSyncRequestAt, now);
  });

  test('用户操作节点刷新节流基准：刚同步过则紧随其后的回前台被跳过', () {
    final base = DateTime(2026, 8, 28, 10);
    DateTime now = base;
    final provider = laneBusyProvider(now: () => now);

    provider.triggerSync(); // 例：轮次落库 / 保存书籍设置
    clearQueue(provider);
    expect(provider.lastSyncRequestAt, base);

    now = base.add(const Duration(seconds: 30));
    provider.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(provider.debugPendingSyncRequested(SyncPlane.data), isFalse);
    expect(provider.debugPendingSyncRequested(SyncPlane.images), isFalse);
  });

  test('未配置 / 手动模式下回前台不记录同步请求时刻（触发被门控忽略）', () {
    final provider = CloudSyncProvider()..debugSetConfigured(value: false);
    provider.debugClearSyncRequestAt();
    provider.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(provider.lastSyncRequestAt, isNull);

    provider.debugSetConfigured(value: true);
    provider.debugSetSyncMode(SyncMode.manual);
    provider.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(provider.lastSyncRequestAt, isNull,
        reason: '手动模式下回前台同样静默忽略，不占用节流窗口');
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

  test('showSyncResult：同文案去重，不同文案各自入队', () {
    final provider = CloudSyncProvider();
    provider.showSyncResult('云端记录 #3：数据已同步');
    provider.showSyncResult('云端记录 #3：数据已同步');
    expect(provider.resultToasts, hasLength(1));

    provider.showSyncResult('图片同步：完成（上传 3）');
    expect(provider.resultToasts, hasLength(2));
    expect(
      provider.resultToasts.map((t) => t.message).toList(),
      ['云端记录 #3：数据已同步', '图片同步：完成（上传 3）'],
    );
  });

  test('showSyncResult：超过上限时优先挤掉最早的临时提示，驻留错误不轻易丢', () {
    final provider = CloudSyncProvider();
    provider.showSyncResult('A');
    provider.showSyncResult('B');
    provider.showSyncResult('C');

    // 第 4 条：A 是临时提示（成功类）→ 被挤掉；B / C 保留。
    provider.showSyncResult('D');
    expect(provider.resultToasts.map((t) => t.message).toList(), ['B', 'C', 'D']);

    // 全是驻留错误时丢弃最早一条。
    final allError = CloudSyncProvider();
    for (final m in ['E1', 'E2', 'E3', 'E4']) {
      allError.showSyncResult(m, kind: SyncToastKind.error);
    }
    expect(allError.resultToasts.map((t) => t.message).toList(), ['E2', 'E3', 'E4']);
  });

  test('dismissSyncResult：按 id 关闭指定条目，且不影响其它条目', () {
    final provider = CloudSyncProvider();
    provider.showSyncResult('已取消数据同步', kind: SyncToastKind.info);
    provider.showSyncResult('图片同步：连接超时（HTTP 408）', kind: SyncToastKind.error);

    final error = provider.resultToasts
        .firstWhere((t) => t.kind == SyncToastKind.error);
    provider.dismissSyncResult(error.id);

    expect(
      provider.resultToasts.map((t) => t.message).toList(),
      ['已取消数据同步'],
    );

    // 重复关闭：无副作用（不再通知）。
    provider.dismissSyncResult(error.id);
    expect(provider.resultToasts, hasLength(1));
  });

  // ---------------------------------------------------------------------------
  // 「保留历史版本」：本地不存，唯一权威来源是云端 sync_config.json
  // ---------------------------------------------------------------------------

  test('saveKeepVersions：越界直接返回文案，不打网络、缓存不变', () async {
    final provider = CloudSyncProvider()..debugSetConfigured(value: true);

    expect(await provider.saveKeepVersions(0), '需为 1 ~ 99 的整数');
    expect(await provider.saveKeepVersions(100), '需为 1 ~ 99 的整数');
    expect(provider.keepVersions, SyncConfig.defaultKeepVersions,
        reason: '校验失败不触碰缓存');
  });

  test('saveKeepVersions：未配置 → 返回「请先保存 WebDAV 连接配置」', () async {
    final provider = CloudSyncProvider()..debugSetConfigured(value: false);
    expect(await provider.saveKeepVersions(5), '请先保存 WebDAV 连接配置');
  });

  test('refreshKeepVersions：未配置 → 返回文案且不置已加载', () async {
    final provider = CloudSyncProvider()..debugSetConfigured(value: false);
    expect(await provider.refreshKeepVersions(), '请先保存 WebDAV 连接配置');
    expect(provider.keepVersionsLoaded, isFalse);
  });

  test('keepVersions 初始为默认 5 且未从云端读取过（展示「—」依据）', () {
    final provider = CloudSyncProvider();
    expect(provider.keepVersions, SyncConfig.defaultKeepVersions);
    expect(provider.keepVersionsLoaded, isFalse);
  });

  test('debugSetKeepVersions：注入缓存后 loaded 为 true（测试钩子）', () {
    final provider = CloudSyncProvider();
    provider.debugSetKeepVersions(12);
    expect(provider.keepVersions, 12);
    expect(provider.keepVersionsLoaded, isTrue);
  });
}
