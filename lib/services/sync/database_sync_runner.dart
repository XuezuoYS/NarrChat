import 'dart:typed_data';

import '../../database/sync_dao.dart';
import 'sync_action_planner.dart';
import 'sync_local_snapshot.dart';
import 'sync_merge_planner.dart';
import 'sync_models.dart';
import 'sync_remote_store.dart';

/// 一次**数据平面**同步的结果。
///
/// 代数（manifest.generation）只在本平面推进；图片平面没有代数通道
///（见 `image_sync_runner.dart`），图片动作在结构上不可能误推代数。
class SyncResult {
  /// 是否发生了落地变更（拉取 / 删除传播 / 推送）。
  final bool applied;

  /// 是否**推送**了云端新版本（写快照 + 推进代数）。
  ///
  /// false 且 [applied] 为 true：仅拉取/删除传播落地，云端未变，代数不推进。
  final bool pushed;

  /// 是否检测到需人工介入的冲突（由调用方打开合并决策页）。
  final bool hasConflict;
  final int? generation;
  final String? error;

  const SyncResult({
    this.applied = false,
    this.pushed = false,
    this.hasConflict = false,
    this.generation,
    this.error,
  });
}

/// 数据平面同步执行器：锁 → pull→merge→push → 释放锁。
///
/// 只负责数据平面的文件与迭代：`manifest.json`（第 N 代）、
/// `narrchat_snapshot_gN_*.db`、本地共基 / 状态（`sync_book_base` /
/// `sync_mod_base` / `sync_state`）。图片 blob 与删除墓碑属独立图片平面
///（`ImageSyncRunner`），本类结构上**不读写** `img/*` 与
/// `img_tombstones.json`——manifest 的 `images` 字段仅承载引用集快照
///（派生展示信息，图片缺失/多余都由图片平面按实际清单自愈）。
///
/// 依赖注入以便测试：云存储、同步状态/共基存储、本地快照构建、
/// 快照字节构建、远端落地回调。工作流见 docs/sync_auto_triggers.md。
class DatabaseSyncRunner {
  final SyncRemoteStore store;
  final SyncStateStore stateStore;
  final String deviceId;

  /// 构建本地部件快照（读业务表）。
  final Future<SyncLocalSnapshot> Function() buildLocalSnapshot;

  /// 构建"当前本地库"的快照字节（用于上传）。
  final Future<Uint8List> Function() buildSnapshotBytes;

  /// 当前本地库引用的图片路径集合（存活集，仅用于 manifest.images）。
  final Future<List<String>> Function() referencedImages;

  final int keepVersions;
  final void Function(SyncProgressEvent)? onProgress;

  /// 协作式取消回调：返回 true 表示用户已请求取消本平面的同步，
  /// 在阶段之间检查，取消后提前返回（不写入云端）。
  final bool Function()? isCancelled;

  /// 把远端 [SyncAction]（拉取 / 删除传播）落地到本地库。
  ///
  /// 由调用方注入（生产走真实 DAO，测试走替身）。同步在检出无冲突后、
  /// 推送前调用；`null` 表示不落库（纯只读编排）。
  final Future<void> Function(SyncAction action)? applyRemotePlan;

  /// 拉取远端独有 / `remoteOnly` 部件的**内容**到本地库。
  ///
  /// 同步在检出无冲突后、有 `pullBookUuids` / `pullModUuids` 时读取**当前代
  /// 远端快照**，把 [SyncMergePlan] 的逐书部件决策、[SyncAction] 的拉取清单
  /// 与快照字节交给调用方落地（生产按决策把远端书的部件合并进本地同名书 /
  /// 整本复制新书 / 新增或更新独立 Mod；测试注入替身）。`null` 表示纯只读编排（不落库）。
  final Future<void> Function(
    SyncMergePlan mergePlan,
    SyncAction action,
    Uint8List snapshotBytes,
  )?
  applyRemoteBooks;

  /// 云端锁被占用时的重试间隔（测试可注入 [Duration.zero]）。
  final Duration lockRetryDelay;

  DatabaseSyncRunner({
    required this.store,
    required this.stateStore,
    required this.deviceId,
    required this.buildLocalSnapshot,
    required this.buildSnapshotBytes,
    required this.referencedImages,
    this.keepVersions = 5,
    this.onProgress,
    this.isCancelled,
    this.applyRemotePlan,
    this.applyRemoteBooks,
    this.lockRetryDelay = const Duration(milliseconds: 400),
  });

  /// 执行一次完整数据同步：锁定 → pull→merge→push → 释放锁。
  Future<SyncResult> sync() async {
    if (_cancelled) return const SyncResult(error: '已取消');
    var lockHeld = false;
    for (var attempt = 0; attempt < 3; attempt++) {
      lockHeld = await store.acquireLock(deviceId: deviceId);
      if (lockHeld) break;
      if (attempt < 2 && lockRetryDelay > Duration.zero) {
        await Future<void>.delayed(lockRetryDelay);
      }
    }
    if (!lockHeld) {
      return const SyncResult(applied: false, error: '另一台设备正在同步，请稍后重试');
    }
    try {
      return await _syncLocked();
    } finally {
      await store.releaseLock(deviceId: deviceId);
    }
  }

  Future<SyncResult> _syncLocked() async {
    if (_cancelled) return const SyncResult(error: '已取消');
    _emit(SyncPhase.pullManifest, '读取云端清单…');
    final manifest = await store.readManifest();
    if (manifest == null) {
      return _bootstrap();
    }

    final local = await buildLocalSnapshot();
    final baseBooks = await _readBaseBooks();
    final baseMods = await _readBaseMods();
    final remoteBooks = _toRemoteBooks(manifest.books);
    final remoteMods = _toRemoteMods(manifest.mods);
    final mergePlan = SyncMergePlanner.plan(
      base: baseBooks,
      local: local.books,
      remote: remoteBooks,
      localMods: local.mods,
      remoteMods: remoteMods,
      baseMods: baseMods,
    );

    final action = SyncActionPlanner.plan(mergePlan: mergePlan);
    if (!action.hasChanges) {
      return SyncResult(applied: false, generation: manifest.generation);
    }
    if (action.hasConflict) {
      return SyncResult(
        applied: false,
        hasConflict: true,
        generation: manifest.generation,
      );
    }

    // —— apply 远端：拉取 / 删除传播落地本地库 ——
    final hasPulls =
        action.pullBookUuids.isNotEmpty || action.pullModUuids.isNotEmpty;
    if (hasPulls) {
      if (applyRemoteBooks == null) {
        // 纯只读编排：不落库（无 applyRemoteBooks 时跳过）。
      } else {
        final snapshotName = await _latestSnapshotName(manifest);
        var bytes = snapshotName == null
            ? null
            : await store.readSnapshot(snapshotName);
        // 读取失败重试一次；仍失败 → 中止同步，绝不带旧内容推送覆盖远端。
        if (bytes == null && snapshotName != null) {
          bytes = await store.readSnapshot(snapshotName);
        }
        if (bytes == null) {
          return SyncResult(
            applied: false,
            error: '无法获取云端快照（第 ${manifest.generation} 代），请稍后重试',
          );
        }
        _emit(SyncPhase.pullSnapshot, '下载远端快照…');
        await applyRemoteBooks!(mergePlan, action, bytes);
      }
    }
    if (applyRemotePlan != null) {
      _emit(SyncPhase.applyLocal, '应用远端变更…');
      await applyRemotePlan!(action);
      if (_cancelled) return const SyncResult(error: '已取消');
    }

    // —— 落地后复算：本地若无独立变更 → 不推进代数（拉取结果与远端一致）——
    final localAfter = await buildLocalSnapshot();
    final planAfter = SyncMergePlanner.plan(
      base: baseBooks,
      local: localAfter.books,
      remote: remoteBooks,
      localMods: localAfter.mods,
      remoteMods: remoteMods,
      baseMods: baseMods,
    );
    if (!_requiresPush(planAfter)) {
      await _writeBase(localAfter);
      await _cleanupBases(localAfter);
      await stateStore.saveState(
        SyncStateRecord(
          deviceId: deviceId,
          lastSyncedAt: DateTime.now().millisecondsSinceEpoch,
          lastGeneration: manifest.generation,
        ),
      );
      return SyncResult(
        applied: true,
        pushed: false,
        generation: manifest.generation,
      );
    }

    // —— push ——
    _emit(SyncPhase.pushSnapshot, '上传快照…');
    if (_cancelled) return const SyncResult(error: '已取消');
    final snapshotBytes = await buildSnapshotBytes();
    final nextGen = manifest.generation + 1;
    final snapshotName = WebDavSyncStore.snapshotName(nextGen, DateTime.now());
    await store.writeSnapshot(snapshotName, snapshotBytes);

    await _pruneSnapshots();

    // 远端内容落地后重建本地快照：拉取的书需进入本代 manifest 与共基
    //（否则下一轮同步会把它们误判为「远端删除」或重复弹冲突）。
    // 注意：无变更不推进分支已提前返回，这里到达时必有推送。
    // manifest.images 仅承载引用集快照（展示/审计用途）；图片 blob 的实际
    // 收敛与删除意图由独立图片平面（ImageSyncRunner + 墓碑文件）负责，
    // 因此图片缺失/多余都**不构成**本平面的推送理由。
    final newManifest = SyncManifest(
      generation: nextGen,
      lastWriterDeviceId: deviceId,
      knownDevices: {...manifest.knownDevices, deviceId}.toList(),
      books: _toBookEntries(localAfter.books, localAfter.bookMeta),
      mods: _toModEntries(localAfter.mods),
      images: await referencedImages(),
    );

    // 写前校验：云端 generation 已变（并发窗口）→ 放弃本次推送，保留云端。
    final latest = await store.readManifest();
    if (latest == null || latest.generation != manifest.generation) {
      return SyncResult(applied: false, error: '云端状态在同步期间已更新，请重新同步');
    }
    await store.writeManifest(newManifest);

    await _writeBase(localAfter);
    await _cleanupBases(localAfter);
    await stateStore.saveState(
      SyncStateRecord(
        deviceId: deviceId,
        lastSyncedAt: DateTime.now().millisecondsSinceEpoch,
        lastGeneration: nextGen,
      ),
    );
    return SyncResult(applied: true, pushed: true, generation: nextGen);
  }

  // ---------------------------------------------------------------------------
  // 首次连接：把本地推上去初始化云端仓库（仅数据平面；图片由图片平面
  // 独立收敛——统一触发时紧随其后，单发图片同步也不依赖 manifest 存在）。
  // ---------------------------------------------------------------------------
  Future<SyncResult> _bootstrap() async {
    _emit(SyncPhase.bootstrap, '初始化云端仓库…');
    final local = await buildLocalSnapshot();
    final snapshot = await buildSnapshotBytes();
    final snapshotName = WebDavSyncStore.snapshotName(1, DateTime.now());
    await store.writeSnapshot(snapshotName, snapshot);
    await store.writeManifest(
      SyncManifest(
        generation: 1,
        lastWriterDeviceId: deviceId,
        knownDevices: [deviceId],
        books: _toBookEntries(local.books, local.bookMeta),
        mods: _toModEntries(local.mods),
        images: await referencedImages(),
      ),
    );
    await _writeBase(local);
    await _cleanupBases(local);
    await stateStore.saveState(
      SyncStateRecord(
        deviceId: deviceId,
        lastSyncedAt: DateTime.now().millisecondsSinceEpoch,
        lastGeneration: 1,
      ),
    );
    return const SyncResult(applied: true, pushed: true, generation: 1);
  }

  // ---------------------------------------------------------------------------
  // 内部
  // ---------------------------------------------------------------------------
  /// 修剪超量快照，始终保留最新 [keepVersions] 份。
  Future<void> _pruneSnapshots() async {
    final names = await store.listSnapshotNames();
    final keep = keepVersions < 1 ? 1 : keepVersions;
    if (names.length <= keep) return;
    // 按代际新 → 旧排序，超量部分删除（同代字典序即时间序）。
    final ordered = [...names]
      ..sort((a, b) {
        final ag = WebDavSyncStore.generationOf(a) ?? -1;
        final bg = WebDavSyncStore.generationOf(b) ?? -1;
        if (ag != bg) return bg.compareTo(ag);
        return b.compareTo(a);
      });
    for (final name in ordered.skip(keep)) {
      try {
        await store.deleteSnapshot(name);
      } catch (_) {
        // 单个删除失败不阻断整体。
      }
    }
  }

  /// 取云端当前代（最高代）的快照名；无快照返回 null。
  Future<String?> _latestSnapshotName(SyncManifest manifest) async {
    return store.latestSnapshotName(generation: manifest.generation);
  }

  Future<Map<String, SyncBookBaseParts>> _readBaseBooks() async {
    final bases = await stateStore.getAllBookBases();
    return {
      for (final e in bases.entries)
        if (e.value.uuid.isNotEmpty)
          e.value.uuid: SyncBookBaseParts(
            title: e.value.title,
            settingsFp: e.value.settingsFp,
            roundsFp: e.value.roundsFp,
            worldBookFp: e.value.worldbookFp,
            bookModsFp: e.value.bookmodsFp,
          ),
    };
  }

  Future<Map<String, SyncModBaseParts>> _readBaseMods() async {
    final mods = await stateStore.getAllModBases();
    return {
      for (final e in mods.entries)
        if (e.value.uuid.isNotEmpty)
          e.value.uuid: SyncModBaseParts(
            name: e.value.name,
            fingerprint: e.value.fingerprint,
          ),
    };
  }

  Future<void> _writeBase(SyncLocalSnapshot local) async {
    for (final e in local.books.entries) {
      final meta = local.bookMeta[e.key];
      await stateStore.putBookBase(
        SyncBookBase(
          uuid: e.value.uuid,
          title: e.value.title,
          settingsFp: e.value.parts.settingsFp,
          roundsFp: e.value.parts.roundsFp,
          worldbookFp: e.value.parts.worldBookFp,
          bookmodsFp: e.value.parts.bookModsFp,
          settingsUpdatedAt: meta?.settingsUpdatedAt ?? 0,
          roundsUpdatedAt: meta?.roundsUpdatedAt ?? 0,
          worldbookUpdatedAt: 0,
          bookmodsUpdatedAt: 0,
        ),
      );
    }
    for (final e in local.mods.entries) {
      await stateStore.putModBase(
        SyncModBase(
          uuid: e.value.uuid,
          name: e.value.name,
          fingerprint: e.value.fingerprint,
        ),
      );
    }
  }

  /// 清理"已不在本地快照中"的共基行（删除的书/Mod 不残留，避免误判）。
  Future<void> _cleanupBases(SyncLocalSnapshot local) async {
    final bookBases = await stateStore.getAllBookBases();
    for (final e in [...bookBases.entries]) {
      if (!local.books.containsKey(e.key)) {
        await stateStore.deleteBookBase(e.key);
      }
    }
    final modBases = await stateStore.getAllModBases();
    for (final e in [...modBases.entries]) {
      if (!local.mods.containsKey(e.key)) {
        await stateStore.deleteModBase(e.key);
      }
    }
  }

  /// 落地后是否仍存在「需要推送的本地变更」（仅数据平面；图片平面永不推代数）。
  ///
  /// 无 → 本地已与远端一致（拉取 + 删除传播的结果），跳过写快照/写清单/推进代数。
  /// 说明：预检已排除真冲突；planAfter 中的 conflict 只可能来自"刚拉取的部件"
  ///（local==remote、都区别于 base 的三向假象），不应遮蔽真实的 localOnly 部件。
  static bool _requiresPush(SyncMergePlan plan) {
    for (final b in plan.books) {
      switch (b.presence) {
        case SyncBookPresence.localOnly:
        case SyncBookPresence.deletedOnLocal:
          return true;
        case SyncBookPresence.both:
          if (b.settings == SyncPartStatus.localOnly ||
              b.rounds == SyncPartStatus.localOnly ||
              b.worldBook == SyncPartStatus.localOnly ||
              b.bookMods == SyncPartStatus.localOnly) {
            return true;
          }
        default:
          break;
      }
    }
    for (final m in plan.mods) {
      if (m.status == SyncModStatus.localOnly ||
          m.status == SyncModStatus.deletedOnLocal) {
        return true;
      }
    }
    return false;
  }

  /// 远端 manifest 条目 → uuid 键的部件映射（uuid 为空时用 legacy 键回退）。
  ///
  /// 部件内的 [RemoteBookParts.uuid] 同样使用**有效键**（含 legacy 回退），
  /// 保证决策 / 动作清单里的远端标识可直接用于落地层定位。
  Map<String, RemoteBookParts> _toRemoteBooks(List<SyncBookEntry> books) {
    return {
      for (final b in books)
        _remoteKey(b.uuid, b.title): RemoteBookParts(
          uuid: _remoteKey(b.uuid, b.title),
          title: b.title,
          deleted: b.deleted,
          settingsFp: b.settingsFp,
          roundsFp: b.roundsFp,
          worldBookFp: b.worldBookFp,
          bookModsFp: b.bookModsFp,
        ),
    };
  }

  Map<String, RemoteModParts> _toRemoteMods(List<SyncModEntry> mods) {
    return {
      for (final m in mods)
        _remoteKey(m.uuid, m.name): RemoteModParts(
          uuid: _remoteKey(m.uuid, m.name),
          name: m.name,
          deleted: m.deleted,
          fingerprint: m.fingerprint,
        ),
    };
  }

  static String _remoteKey(String uuid, String name) =>
      uuid.isNotEmpty ? uuid : 'legacy:$name';

  List<SyncBookEntry> _toBookEntries(
    Map<String, SyncBookRecord> books,
    Map<String, SyncBookMeta> bookMeta,
  ) {
    return [
      for (final e in books.entries)
        SyncBookEntry(
          uuid: e.value.uuid,
          title: e.value.title,
          deleted: e.value.parts.deleted,
          settingsFp: e.value.parts.settingsFp,
          settingsUpdatedAt: bookMeta[e.key]?.settingsUpdatedAt ?? 0,
          roundsFp: e.value.parts.roundsFp,
          roundsUpdatedAt: bookMeta[e.key]?.roundsUpdatedAt ?? 0,
          worldBookFp: e.value.parts.worldBookFp,
          bookModsFp: e.value.parts.bookModsFp,
        ),
    ];
  }

  List<SyncModEntry> _toModEntries(Map<String, SyncModRecord> mods) {
    return [
      for (final e in mods.entries)
        SyncModEntry(
          uuid: e.value.uuid,
          name: e.value.name,
          deleted: false,
          updatedAt: 0,
          fingerprint: e.value.fingerprint,
        ),
    ];
  }

  void _emit(SyncPhase phase, String label) => onProgress?.call(
        SyncProgressEvent(phase: phase, label: label),
      );

  bool get _cancelled => isCancelled?.call() ?? false;
}
