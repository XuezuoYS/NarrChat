import 'dart:typed_data';

import '../../database/sync_dao.dart';
import 'img_tombstones.dart';
import 'sync_action_planner.dart';
import 'sync_image_planner.dart';
import 'sync_local_snapshot.dart';
import 'sync_merge_planner.dart';
import 'sync_models.dart';
import 'sync_remote_store.dart';

/// 一次同步的结果。
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

/// 云同步编排服务。
///
/// 依赖注入以便测试：云存储（manifest/快照/图片/锁）、同步状态/共基存储、
/// 本地快照构建、快照字节构建、图片本地读写。工作流见方案定稿。
class SyncService {
  final SyncRemoteStore store;
  final SyncStateStore stateStore;
  final String deviceId;

  /// 构建本地部件快照（读业务表）。
  final Future<SyncLocalSnapshot> Function() buildLocalSnapshot;

  /// 构建"当前本地库"的快照字节（用于上传）。
  final Future<Uint8List> Function() buildSnapshotBytes;

  /// 当前本地库引用的图片路径集合（存活集）。
  final Future<List<String>> Function() referencedImages;

  /// 本地 `img/` 现存路径。
  final Future<List<String>> Function() localImages;

  final Future<Uint8List?> Function(String path) readLocalImage;
  final Future<void> Function(String path, Uint8List bytes) writeLocalImage;

  /// 删除本地 `img/` 下的图片文件（其它设备的删除传播；null 时跳过本地删除）。
  final Future<void> Function(String path)? deleteLocalImage;

  /// 图片删除墓碑工作副本（本地文件存取）。
  ///
  /// 墓碑不进入数据库：本地工作副本在删除/重新添加流程即时改写，
  /// 同步时与云端 `img_tombstones.json` 合并（并集 + 撤销 + 过期清除），
  /// 并把结果回写云端与本地。
  final SyncTombstoneStore tombstoneStore;

  final int keepVersions;
  final void Function(SyncProgressEvent)? onProgress;

  /// 协作式取消回调：返回 true 表示用户已请求取消，
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

  SyncService({
    required this.store,
    required this.stateStore,
    required this.deviceId,
    required this.buildLocalSnapshot,
    required this.buildSnapshotBytes,
    required this.referencedImages,
    required this.localImages,
    required this.readLocalImage,
    required this.writeLocalImage,
    SyncTombstoneStore? tombstoneStore,
    this.deleteLocalImage,
    this.keepVersions = 5,
    this.onProgress,
    this.isCancelled,
    this.applyRemotePlan,
    this.applyRemoteBooks,
    this.lockRetryDelay = const Duration(milliseconds: 400),
  }) : tombstoneStore = tombstoneStore ?? const _EmptyTombstoneStore();

  /// 执行一次完整同步：锁定 → pull→merge→push → 释放锁。
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

    final referenced = await referencedImages();
    final locImages = await localImages();
    // 图片规划以「云端实际存在的 blob」为准（而非 manifest 声明）：历史版本
    // 曾把图片写入 manifest 却未上传（或首次连接从未上传），若只信 manifest
    // 会导致缺失的图片永远不会被补传。实际清单缺失时会被判定为 toUpload。
    final cloudImageFiles = await store.listImages();
    // 删除墓碑：云端文件 ⊕ 本地工作副本（并集 / 撤销 / 过期清除），
    // 结果即本轮的最终删除意图（不进入数据库与 manifest）。
    final cloudTombstones =
        (await store.readImageTombstones()) ?? ImgTombstones.empty;
    final localTombstones = await tombstoneStore.load();
    final mergedTombstones = mergeTombstones(
      local: localTombstones,
      cloud: cloudTombstones,
      now: DateTime.now().millisecondsSinceEpoch,
    );
    final tombstones = [for (final e in mergedTombstones.entries) e.path];
    final action = SyncActionPlanner.plan(
      mergePlan: mergePlan,
      referencedImages: referenced,
      cloudImages: cloudImageFiles,
      localImages: locImages,
      tombstones: tombstones,
    );

    if (!action.hasChanges) {
      // 无其它变更也要做墓碑维护：每次同步清除过期条目、消费撤销清单，
      // 并把离线删除合并进云端墓碑文件（本分支无云端其他写入）。
      await _persistTombstones(mergedTombstones, cloudTombstones);
      return SyncResult(applied: false, generation: manifest.generation);
    }
    if (action.hasConflict) {
      return SyncResult(
        applied: false,
        hasConflict: true,
        generation: manifest.generation,
      );
    }

    // —— 先落地图片远端状态（拉取 / 删除传播）——幂等，且与是否推送无关：
    // 拉取与删除都不需要推进 manifest 代数（图片由独立墓碑文件传播），
    // 若把它们挂在「推送路径」上会导致每次同步都白推一代快照/清单。
    await _applyRemoteImages(action.images);

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
    // 只有「上传图片」需要随推送执行；拉取/删除已于上方落地，不再是推送理由。
    final hasImageUploads = action.images.toUpload.isNotEmpty;
    if (!_requiresPush(planAfter) && !hasImageUploads) {
      await _writeBase(localAfter);
      await _cleanupBases(localAfter);
      await stateStore.saveState(
        SyncStateRecord(
          deviceId: deviceId,
          lastSyncedAt: DateTime.now().millisecondsSinceEpoch,
          lastGeneration: manifest.generation,
        ),
      );
      // 无推送也执行墓碑维护：过期清除 / 撤销 / 离线删除合并到云端文件，
      // 并把本地工作副本刷新为云端内容（撤销清单已消费）。
      await _persistTombstones(mergedTombstones, cloudTombstones);
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

    _emit(SyncPhase.pushImages, '同步图片…');
    if (_cancelled) return const SyncResult(error: '已取消');
    await _uploadImages(action.images);

    await _pruneSnapshots();

    // 远端内容落地后重建本地快照：拉取的书需进入本代 manifest 与共基
    // （否则下一轮同步会把它们误判为「远端删除」或重复弹冲突）。
    // 注意：无变更不推进分支已提前返回，这里到达时必有推送。
    // 图片删除/复活意图经独立的墓碑文件传播（见 img_tombstones.dart），
    // 不进入 manifest（此处仅承载书籍 / Mod / 图片引用集合）。
    final newManifest = SyncManifest(
      generation: nextGen,
      lastWriterDeviceId: deviceId,
      knownDevices: {...manifest.knownDevices, deviceId}.toList(),
      books: _toBookEntries(localAfter.books, localAfter.bookMeta),
      mods: _toModEntries(localAfter.mods),
      images: referenced,
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
    // 推送成功后回写墓碑：删除/撤销/过期清除随云端墓碑文件持久化（失败路径
    // 不消费，本地工作副本保留离线改动，下次同步重放，保证不丢失删除意图）。
    await _persistTombstones(mergedTombstones, cloudTombstones);
    return SyncResult(applied: true, pushed: true, generation: nextGen);
  }

  // ---------------------------------------------------------------------------
  // 首次连接：把本地推上去初始化云端仓库。
  // ---------------------------------------------------------------------------
  Future<SyncResult> _bootstrap() async {
    _emit(SyncPhase.bootstrap, '初始化云端仓库…');
    final local = await buildLocalSnapshot();
    final snapshot = await buildSnapshotBytes();
    final snapshotName = WebDavSyncStore.snapshotName(1, DateTime.now());
    await store.writeSnapshot(snapshotName, snapshot);
    final referenced = await referencedImages();
    // 首次同步同样把本地图片上传到云端（此前仅写 manifest，
    // 导致图片从未真正出现在 WebDAV 中）。
    final locImages = await localImages();
    await _uploadImages(
      ImageSyncPlanner.plan(
        referencedImages: referenced,
        cloudImages: const [],
        localImages: locImages,
        tombstones: const [],
      ),
    );
    await store.writeManifest(
      SyncManifest(
        generation: 1,
        lastWriterDeviceId: deviceId,
        knownDevices: [deviceId],
        books: _toBookEntries(local.books, local.bookMeta),
        mods: _toModEntries(local.mods),
        images: referenced,
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
  /// 落地图片「远端状态」：拉取缺失 blob、删除传播（云端 blob / 本机文件）。
  ///
  /// 幂等且在推送前执行——拉取与删除不改变 manifest 内容，不应成为
  /// 「推送 / 推进代数」的理由；重复同步对已完成的删除不再产生动作。
  Future<void> _applyRemoteImages(ImageSyncPlan images) async {
    if (images.toPull.isNotEmpty) {
      await store.ensureImagesFolder();
      for (final p in images.toPull) {
        final bytes = await store.readImage(p);
        if (bytes == null) continue;
        await writeLocalImage(p, bytes);
      }
    }
    for (final p in images.toDeleteCloud) {
      await store.deleteImage(p);
    }
    final deleteLocal = images.toDeleteLocal;
    if (deleteLocal.isNotEmpty && deleteLocalImage != null) {
      // 删除传播：其它设备的删除意图 → 删除本机文件（即使仍被引用，剧情显示缺失）。
      for (final p in deleteLocal) {
        await deleteLocalImage!(p);
      }
    }
  }

  /// 上传本机图片到云端（仅推送路径：上传的内容会进入本代 manifest）。
  Future<void> _uploadImages(ImageSyncPlan images) async {
    if (images.toUpload.isEmpty) return;
    await store.ensureImagesFolder();
    for (final p in images.toUpload) {
      final bytes = await readLocalImage(p);
      if (bytes == null) continue;
      await store.writeImage(p, bytes);
    }
  }

  /// 回写墓碑：合并结果与云端文件不一致（离线删除 / 撤销 / 过期清除）时
  /// 覆盖云端 `img_tombstones.json`；随后把本地工作副本刷新为云端内容
  /// （撤销清单已消费；云端写入失败则抛错，本地工作副本保留离线改动）。
  Future<void> _persistTombstones(
    ImgTombstones merged,
    ImgTombstones cloud,
  ) async {
    if (!_sameTombstones(merged, cloud)) {
      await store.writeImageTombstones(merged);
    }
    await tombstoneStore.save(ImgTombstones(entries: merged.entries));
  }

  /// 两份墓碑文件是否语义一致（与条目顺序无关，按路径对齐比较）。
  static bool _sameTombstones(ImgTombstones a, ImgTombstones b) {
    if (a.entries.length != b.entries.length) return false;
    for (final e in a.entries) {
      final matches = b.entries.where((x) => x.path == e.path).toList();
      if (matches.length != 1) return false;
      if (matches.single.deletedAt != e.deletedAt ||
          matches.single.expiresAt != e.expiresAt) {
        return false;
      }
    }
    return true;
  }

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

  /// 落地后是否仍存在「需要推送的本地变更」。
  ///
  /// 无 → 本地已与远端一致（拉取 + 删除传播的结果），跳过写快照/写清单/推进代数。
  /// 说明：预检已排除真冲突；planAfter 中的 conflict 只可能来自"刚拉取的部件"
  /// （local==remote、都区别于 base 的三向假象），不应遮蔽真实的 localOnly 部件。
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

/// 空墓碑存储（未接入墓碑文件的纯只读编排 / 测试缺省）：不留存任何删除意图。
class _EmptyTombstoneStore implements SyncTombstoneStore {
  const _EmptyTombstoneStore();

  @override
  Future<ImgTombstones> load() async => ImgTombstones.empty;

  @override
  Future<void> save(ImgTombstones tombstones) async {}
}
