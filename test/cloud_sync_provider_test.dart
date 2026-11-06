import 'dart:convert';

import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/app_notice.dart';
import 'package:narrchat/providers/cloud_sync_provider.dart';
import 'package:narrchat/services/cloud_backup/backup_manifest.dart';
import 'package:narrchat/services/cloud_backup/backup_planner.dart';
import 'package:narrchat/services/cloud_backup/backup_runner.dart';
import 'package:narrchat/services/cloud_backup/backup_unit.dart';
import 'package:narrchat/services/sync/sync_models.dart';
import 'package:narrchat/services/webdav_service.dart';

import 'helpers/backup_fakes.dart';

/// `CloudSyncProvider`：触发门控、快照命名解析、整本冲突状态、结果提示队列。
///
/// R3 的数据面换成"一库一单元一代"（`<base>_shot-g<N>.db`），冲突只给整本书
/// 二选一；**不再有部件级合并**，本文件因此没有 merge/replace 断言。
/// 真正推拉、冲突裁决、prune 的过程见 `backup_runner_test.dart`（内存云端全流程）。
void main() {
  group('触发门控', () {
    test('未配置：triggerSync 一律忽略，两个平面都保持 idle', () {
      final provider = CloudSyncProvider()..debugSetConfigured(value: false);
      provider.triggerSync();
      provider.triggerSync(kind: SyncKind.data);
      provider.triggerSync(kind: SyncKind.images);
      expect(provider.dataSyncState, SyncState.idle);
      expect(provider.imageSyncState, SyncState.idle);
      expect(provider.isBusy, isFalse);
    });

    test('手动模式：triggerSync 被忽略（需显式调 sync）', () {
      final provider = CloudSyncProvider()
        ..debugSetConfigured(value: true)
        ..debugSetSyncMode(SyncMode.manual);
      provider.triggerSync();
      expect(provider.dataSyncState, SyncState.idle);
      expect(provider.imageSyncState, SyncState.idle);
    });

    test('未配置时手动 sync 直接返回 false', () async {
      final provider = CloudSyncProvider()..debugSetConfigured(value: false);
      expect(await provider.sync(), isFalse);
    });

    test('sync() 开始会清掉上一次的取消标记', () {
      final provider = CloudSyncProvider()..debugSetConfigured(value: false);
      provider.cancelSync(SyncPlane.data);
      expect(provider.debugCancelRequested(SyncPlane.data), isTrue);
      // 未配置时 sync 提前返回，标记仍在；配置后 sync 会复位它。
      provider.debugSetConfigured(value: true);
      provider.debugSetLaneBusy(true);
      expect(provider.debugCancelRequested(SyncPlane.data), isTrue);
    });
  });

  group('回前台自动触发（attachLifecycle 那条链）', () {
    /// 等内部 _pump 跑完（测试环境无网，HTTP 立刻 400，很快结束）。
    Future<void> drain(CloudSyncProvider provider) async {
      for (var i = 0; i < 200 && provider.isBusy; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    CloudSyncProvider providerAt(DateTime base) => CloudSyncProvider()
      ..debugSetConfigured()
      ..debugSetAutoUpload(true)
      ..debugSetNow(() => base)
      ..debugClearSyncRequestAt();

    test('首次回前台触发一次；非 resumed 状态不触发', () async {
      final base = DateTime(2026, 8, 28, 10);
      final provider = providerAt(base);

      provider.didChangeAppLifecycleState(AppLifecycleState.inactive);
      expect(provider.lastSyncRequestAt, isNull, reason: '非 resumed 不触发');

      provider.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(provider.lastSyncRequestAt, isNull);

      provider.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(provider.lastSyncRequestAt, base, reason: 'resumed 记录本次请求时刻');
      await drain(provider);
    });

    test('2 分钟节流：窗口内的回前台被跳过，满窗口后重新触发', () async {
      final base = DateTime(2026, 8, 28, 10);
      DateTime now = base;
      final provider = CloudSyncProvider()
        ..debugSetConfigured()
        ..debugSetAutoUpload(true)
        ..debugSetNow(() => now)
        ..debugClearSyncRequestAt();

      provider.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(provider.lastSyncRequestAt, base);
      await drain(provider);

      now = base.add(const Duration(minutes: 1, seconds: 59));
      provider.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(provider.lastSyncRequestAt, base,
          reason: '窗口内跳过，且不改写基准时刻');
      await drain(provider);

      now = base.add(const Duration(minutes: 2));
      provider.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(provider.lastSyncRequestAt, now, reason: '窗口结束后重新触发');
      await drain(provider);
    });

    test('自动同步关闭时回前台不触发', () async {
      final base = DateTime(2026, 8, 28, 10);
      final provider = CloudSyncProvider()
        ..debugSetConfigured()
        ..debugSetAutoUpload(false)
        ..debugSetNow(() => base)
        ..debugClearSyncRequestAt();

      provider.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(provider.lastSyncRequestAt, isNull);
      await drain(provider);
    });

    test('手动模式下即使开了自动同步，回前台也不触发', () async {
      final base = DateTime(2026, 8, 28, 10);
      final provider = CloudSyncProvider()
        ..debugSetConfigured()
        ..debugSetAutoUpload(true)
        ..debugSetSyncMode(SyncMode.manual)
        ..debugSetNow(() => base)
        ..debugClearSyncRequestAt();

      provider.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(provider.lastSyncRequestAt, isNull);
      await drain(provider);
    });

    test('未配置 WebDAV 时回前台不触发', () async {
      final base = DateTime(2026, 8, 28, 10);
      final provider = CloudSyncProvider()
        ..debugSetConfigured(value: false)
        ..debugSetAutoUpload(true)
        ..debugSetNow(() => base)
        ..debugClearSyncRequestAt();

      provider.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(provider.lastSyncRequestAt, isNull);
      await drain(provider);
    });

    test('attachLifecycle / detachLifecycle：不抛错且可重复调用', () {
      TestWidgetsFlutterBinding.ensureInitialized();
      final provider = CloudSyncProvider();
      provider.attachLifecycle();
      provider.attachLifecycle();
      provider.detachLifecycle();
      provider.detachLifecycle();
      expect(provider.lastSyncRequestAt, isNull);
    });
  });

  group('快照命名解析（一库一单元一代）', () {
    test('generationOfSnapshot：认得出 _shot-gN.db，认不出返回 -1', () {
      expect(
        CloudSyncProvider.generationOfSnapshot('narrbook_b1_shot-g12.db'),
        12,
      );
      expect(
        CloudSyncProvider.generationOfSnapshot('narrchat_library_shot-g1.db'),
        1,
      );
      expect(
        CloudSyncProvider.generationOfSnapshot('narrchat_snapshot_g3_x.db'),
        -1,
        reason: 'R2 的旧命名不再被识别',
      );
      expect(CloudSyncProvider.generationOfSnapshot('random.txt'), -1);
    });

    test('unitOfSnapshot：目录库 / Mod 库 / 每本书各自映射到单元', () {
      expect(
        CloudSyncProvider.unitOfSnapshot('narrchat_library_shot-g1.db')?.unitKey,
        'library',
      );
      expect(
        CloudSyncProvider.unitOfSnapshot('narrchat_mods_shot-g2.db')?.unitKey,
        'mods',
      );
      expect(
        CloudSyncProvider.unitOfSnapshot('narrbook_abc_shot-g3.db')?.unitKey,
        'book:abc',
      );
      expect(CloudSyncProvider.unitOfSnapshot('narrbook__shot-g3.db'), isNull);
      expect(CloudSyncProvider.unitOfSnapshot('unrelated.db'), isNull);
    });

    test('compareSnapshots：先按代数降序，同代按文件名倒序', () {
      final files = [
        const WebDavFile(name: 'narrbook_b1_shot-g2.db'),
        const WebDavFile(name: 'narrbook_b1_shot-g7.db'),
        const WebDavFile(name: 'narrchat_library_shot-g5.db'),
        const WebDavFile(name: 'narrchat_mods_shot-g5.db'),
      ]..sort(CloudSyncProvider.compareSnapshots);
      expect(
        files.map((f) => f.name).toList(),
        [
          'narrbook_b1_shot-g7.db',
          'narrchat_mods_shot-g5.db',
          'narrchat_library_shot-g5.db',
          'narrbook_b1_shot-g2.db',
        ],
      );
    });

    test('describeSnapshot：能识别的给出单元键，不能识别的标未知', () {
      final provider = CloudSyncProvider();
      expect(
        provider.describeSnapshot('narrchat_mods_shot-g4.db'),
        contains('mods'),
      );
      expect(provider.describeSnapshot('whatever.db'), '未知备份');
    });

    test('debugSetBackups：按库分组且书名生效', () {
      final provider = CloudSyncProvider();
      provider.debugSetBackups(
        [
          const WebDavFile(name: 'narrbook_b1_shot-g1.db'),
          const WebDavFile(name: 'narrchat_library_shot-g1.db'),
          const WebDavFile(name: 'narrbook_b1_shot-g2.db'),
          const WebDavFile(name: 'manifest_narrbook_b1.json'),
        ],
        bookTitles: const {'b1': '书一'},
      );

      expect(
        provider.backupUnits.map((entry) => entry.displayName).toList(),
        ['Library 库', '书籍《书一》库'],
      );
      expect(provider.backupUnits.last.totalCount, 2);
      expect(provider.backupUnits.last.latestGeneration, 2);
    });
  });

  group('刷新备份列表时顺带拉取保留代数', () {
    CloudSyncProvider providerWith(FakeWebDavService dav) =>
        CloudSyncProvider(webDavFactory: () => dav)..debugSetConfigured();

    test('读到云端值：列表与展示缓存一起更新，临时客户端关闭', () async {
      final dav = FakeWebDavService(files: {
        'narrchat_library_shot-g2.db': [1, 2, 3],
        'sync_config.json': utf8.encode('{"keepVersions":12}'),
      });
      final provider = providerWith(dav);

      await provider.refreshBackups();

      expect(provider.error, isNull);
      expect(provider.backupUnits.single.displayName, 'Library 库');
      expect(provider.keepVersions, 12);
      expect(provider.keepVersionsLoaded, isTrue);
      expect(dav.closed, isTrue, reason: '临时客户端必须关掉');
    });

    test('云端还没有 sync_config.json：默认值 + 标记已加载', () async {
      final dav = FakeWebDavService(files: {
        'narrchat_library_shot-g1.db': [1],
      });
      final provider = providerWith(dav);

      await provider.refreshBackups();

      expect(provider.keepVersionsLoaded, isTrue);
      expect(provider.keepVersions, SyncConfig.defaultKeepVersions);
    });

    test('sync_config 读取失败：不把默认值伪装成云端真值', () async {
      final dav = FakeWebDavService(
        files: {'narrchat_library_shot-g1.db': [1]},
        getError: '连接超时',
      );
      final provider = providerWith(dav);

      await provider.refreshBackups();

      expect(provider.error, isNull, reason: '顺带刷新失败不占错误框');
      expect(provider.backupUnits, isNotEmpty, reason: '备份列表本身照常刷新');
      expect(provider.keepVersionsLoaded, isFalse, reason: '没读到过就保持「—」');
      expect(provider.keepVersions, SyncConfig.defaultKeepVersions);
    });

    test('refreshKeepVersions：失败返回原生异常文本，成功返回 null', () async {
      final failing = FakeWebDavService(getError: '连接超时');
      final provider1 = providerWith(failing);
      expect(await provider1.refreshKeepVersions(), contains('连接超时'));
      expect(provider1.keepVersionsLoaded, isFalse);

      final ok = FakeWebDavService(files: {
        'sync_config.json': utf8.encode('{"keepVersions":7}'),
      });
      final provider2 = providerWith(ok);
      expect(await provider2.refreshKeepVersions(), isNull);
      expect(provider2.keepVersions, 7);
      expect(provider2.keepVersionsLoaded, isTrue);
    });
  });

  group('整本二选一（冲突状态）', () {
    test('初始没有待裁决冲突', () {
      final provider = CloudSyncProvider();
      expect(provider.unresolvedConflicts, isEmpty);
    });

    test('resolveConflict(skip)：直接返回 null，不改变冲突清单', () async {
      final provider = CloudSyncProvider();
      final unit = BackupUnit.book('b1');
      final plan = BackupPlanner.plan(
        unit: unit,
        localDigest: 'L2',
        base: const BackupBase(generation: 1, baseDigest: 'L'),
        remote: BackupManifest(
          unitKey: unit.unitKey,
          kind: unit.kind,
          refUuid: unit.refUuid,
          generation: 2,
          digest: 'R',
          snapshotName: unit.snapshotName(2),
          savedAt: '2026-01-01T00:00:00.000Z',
        ),
      );
      expect(plan.action, BackupAction.conflict);
      expect(
        await provider.resolveConflict(plan, BackupConflictChoice.skip),
        isNull,
      );
      expect(provider.unresolvedConflicts, isEmpty);
    });

    test('restoreSnapshot：无法识别的文件名给出明确错误', () async {
      final provider = CloudSyncProvider()..debugSetConfigured();
      expect(
        await provider.restoreSnapshot('random.db'),
        '无法识别的备份文件',
      );
    });

    test('restoreSnapshot：未配置云备份时拒绝', () async {
      final provider = CloudSyncProvider()..debugSetConfigured(value: false);
      expect(
        await provider.restoreSnapshot('narrchat_library_shot-g1.db'),
        '尚未配置云备份',
      );
    });
  });

  group('结果提示队列', () {
    test('入队并累计（R3 起不再按文案去重）', () {
      final provider = CloudSyncProvider();
      provider.showSyncResult('云端记录 #3：数据已同步', NoticeKind.success);
      provider.showSyncResult('云端记录 #3：数据已同步', NoticeKind.success);
      expect(provider.resultToasts, hasLength(2));

      provider.showSyncResult('图片同步：完成（上传 3）', NoticeKind.success);
      expect(provider.resultToasts, hasLength(3));
    });

    test('空文案不入队', () {
      final provider = CloudSyncProvider();
      provider.showSyncResult('   ', NoticeKind.info);
      expect(provider.resultToasts, isEmpty);
    });

    test('超过上限时挤掉最早一条', () {
      final provider = CloudSyncProvider();
      for (var i = 1; i <= CloudSyncProvider.maxResultToasts + 1; i++) {
        provider.showSyncResult('消息 $i', NoticeKind.success);
      }
      expect(
        provider.resultToasts,
        hasLength(CloudSyncProvider.maxResultToasts),
      );
      expect(
        provider.resultToasts.first.message,
        '消息 2',
        reason: '最早一条被挤掉',
      );
    });

    test('dismissSyncResult：按 id 关闭指定条目，且不影响其它条目', () {
      final provider = CloudSyncProvider();
      provider.showSyncResult('已取消数据同步', NoticeKind.info);
      provider.showSyncResult('图片同步：连接超时（HTTP 408）', NoticeKind.error);

      final error = provider.resultToasts
          .firstWhere((t) => t.kind == NoticeKind.error);
      provider.dismissSyncResult(error.id);

      expect(
        provider.resultToasts.map((t) => t.message).toList(),
        ['已取消数据同步'],
      );

      // 重复关闭：无副作用。
      provider.dismissSyncResult(error.id);
      expect(provider.resultToasts, hasLength(1));
    });

    test('结果条目驻留时长：成功 3 秒、警告 5 秒、失败 15 秒', () {
      final provider = CloudSyncProvider();
      provider.showSyncResult('数据已同步', NoticeKind.success);
      provider.showSyncResult('数据同步失败：超时', NoticeKind.error);
      provider.showSyncResult('一般警告', NoticeKind.warning);
      final dwells = {
        for (final t in provider.resultToasts) t.message: t.dwell,
      };
      expect(dwells['数据已同步'], const Duration(seconds: 3));
      expect(dwells['数据同步失败：超时'], const Duration(seconds: 15));
      expect(dwells['一般警告'], const Duration(seconds: 5));
    });
  });
}
