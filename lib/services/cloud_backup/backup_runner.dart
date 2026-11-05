import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../database/sqflite_desktop.dart';
import '../../database/sync_store.dart';
import 'backup_digest.dart';
import 'backup_image_plane.dart';
import 'backup_manifest.dart';
import 'backup_planner.dart';
import 'backup_remote.dart';
import 'backup_unit.dart';

/// 冲突时用户的选择：整本二选一。
enum BackupConflictChoice { local, remote, skip }

typedef BackupConflictResolver = Future<BackupConflictChoice> Function(
  BackupPlan plan,
);

/// 备份需要的外部世界（书列表、内容时间、引用图片、换文件前后的钩子）。
///
/// 全部用回调注入，备份模块因此不依赖 provider / 具体数据库实现，
/// 测试可以直接给假实现。
class BackupContext {
  const BackupContext({
    required this.bookUuids,
    this.updatedAtOf,
    this.imagesOf,
    this.beforeReplace,
    this.afterReplace,
  });

  /// 当前**未删除**的书 uuid（删掉的书不推数据库，只靠 library 墓碑传播）。
  final Future<List<String>> Function() bookUuids;

  /// 单元的内容时间（书 = `book_meta.updated_at`），冲突默认裁决用。
  final Future<DateTime?> Function(BackupUnit unit)? updatedAtOf;

  /// 单元引用的图片相对路径（写进清单，还原时顺带拉图）。
  final Future<List<String>> Function(BackupUnit unit)? imagesOf;

  /// 用云端文件覆盖本地文件**之前**调用（上层负责关掉数据库连接）。
  final Future<void> Function(BackupUnit unit)? beforeReplace;

  /// 覆盖完成**之后**调用（上层负责重新打开连接 / 刷新页面）。
  final Future<void> Function(BackupUnit unit)? afterReplace;
}

/// 备份进度（UI 用）。
class BackupProgress {
  const BackupProgress({
    required this.phase,
    required this.index,
    required this.total,
    this.unit,
    this.message = '',
  });

  /// `prepare` / `digest` / `push` / `pull` / `images` / `done`。
  final String phase;
  final BackupUnit? unit;
  final int index;
  final int total;
  final String message;
}

/// 一次备份的结果。
class BackupReport {
  const BackupReport({
    this.plans = const [],
    this.pushed = 0,
    this.pulled = 0,
    this.upToDate = 0,
    this.skipped = 0,
    this.unresolved = const [],
    this.errors = const {},
    this.fatalError,
    this.cancelled = false,
    this.images,
  });

  final List<BackupPlan> plans;
  final int pushed;
  final int pulled;
  final int upToDate;
  final int skipped;

  /// 需要用户裁决但没给 resolver（或用户选了跳过）的单元。
  final List<BackupPlan> unresolved;

  /// 单元级失败：unitKey → 原因。
  final Map<String, String> errors;

  /// 结构性错误（清单损坏等），出现时整轮停止。
  final String? fatalError;

  final bool cancelled;

  final BackupImageReport? images;

  bool get hasConflicts => unresolved.isNotEmpty;

  bool get isClean =>
      !hasConflicts && errors.isEmpty && fatalError == null && !cancelled;
}

/// 云备份执行器。
///
/// 顺序与粒度：
/// 1. 一次只处理一个单元（先 library、再 mods、最后各本书），弱网下不会并发打满；
/// 2. 每单元先算本地摘要，再读云端清单，交给 [BackupPlanner] 决策；
/// 3. 冲突且没有裁决器 → 记进 `unresolved` 跳过，**不阻塞其它单元**；
/// 4. 数据单元走完再同步图片平面。
class BackupRunner {
  BackupRunner({
    required this.remote,
    required this.locator,
    required this.store,
    required this.deviceId,
    this.keepVersions = 5,
    this.onProgress,
    this.isCancelled,
    Future<Database> Function(String path)? openDatabase,
  }) : _openDatabase = openDatabase ?? _defaultOpenDatabase;

  final BackupRemote remote;
  final BackupLocator locator;
  final SyncStore store;
  final String deviceId;

  /// 每个库在云端保留的份数（各自计算）。
  final int keepVersions;

  final void Function(BackupProgress progress)? onProgress;
  final bool Function()? isCancelled;

  final Future<Database> Function(String path) _openDatabase;

  static Future<Database> _defaultOpenDatabase(String path) async {
    ensureDesktopSqfliteFactory();
    return databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
    );
  }

  Future<BackupReport> run({
    required BackupContext context,
    List<BackupUnit>? units,
    BackupConflictResolver? resolver,
    BackupImagePlane? images,
  }) async {
    await remote.ensureReady();
    final names = await remote.list();
    final targets = units ?? await _discoverUnits(context);
    final plans = <BackupPlan>[];
    final unresolved = <BackupPlan>[];
    final errors = <String, String>{};
    var pushed = 0;
    var pulled = 0;
    var upToDate = 0;
    var skipped = 0;
    String? fatalError;

    for (var i = 0; i < targets.length; i++) {
      if (_cancelled) break;
      final unit = targets[i];
      _emit('digest', i, targets.length, unit: unit, message: '检查 ${unit.unitKey}');
      try {
        final plan = await _planFor(unit, names, context);
        plans.add(plan);
        switch (plan.action) {
          case BackupAction.upToDate:
            upToDate++;
          case BackupAction.skipped:
            skipped++;
          case BackupAction.push:
            _emit('push', i, targets.length, unit: unit, message: '备份 ${unit.unitKey}');
            await _push(unit, plan, context);
            pushed++;
          case BackupAction.pull:
            _emit('pull', i, targets.length, unit: unit, message: '还原 ${unit.unitKey}');
            await _pull(unit, plan, context);
            pulled++;
          case BackupAction.conflict:
            final choice = await resolver?.call(plan) ?? BackupConflictChoice.skip;
            if (_cancelled) break;
            if (choice == BackupConflictChoice.local) {
              _emit('push', i, targets.length, unit: unit, message: '备份 ${unit.unitKey}');
              await _push(unit, plan, context);
              pushed++;
            } else if (choice == BackupConflictChoice.remote) {
              _emit('pull', i, targets.length, unit: unit, message: '还原 ${unit.unitKey}');
              await _pull(unit, plan, context);
              pulled++;
            } else {
              unresolved.add(plan);
            }
        }
      } on BackupManifestException catch (error) {
        // 清单存在但读不懂：立刻停止，绝不把它当空清单重新 bootstrap。
        fatalError = error.message;
        break;
      } catch (error) {
        errors[unit.unitKey] = error.toString();
      }
    }

    BackupImageReport? imageReport;
    if (images != null && !_cancelled && fatalError == null) {
      _emit('images', targets.length, targets.length, message: '同步图片');
      imageReport = await images.sync(isCancelled: isCancelled);
    }

    _emit('done', targets.length, targets.length, message: '完成');

    return BackupReport(
      plans: plans,
      pushed: pushed,
      pulled: pulled,
      upToDate: upToDate,
      skipped: skipped,
      unresolved: unresolved,
      errors: errors,
      fatalError: fatalError,
      cancelled: _cancelled,
      images: imageReport,
    );
  }

  Future<List<BackupUnit>> _discoverUnits(BackupContext context) async {
    final uuids = await context.bookUuids();
    return [
      BackupUnit.library,
      BackupUnit.mods,
      ...uuids.map(BackupUnit.book),
    ];
  }

  Future<BackupPlan> _planFor(
    BackupUnit unit,
    Set<String> names,
    BackupContext context,
  ) async {
    final localPath = locator.localPathOf(unit);
    final localFile = File(localPath);
    if (!await localFile.exists()) {
      return BackupPlan(
        unit: unit,
        action: BackupAction.skipped,
        base: await _baseOf(unit),
        localDigest: '',
        reason: '本地文件不存在',
      );
    }

    final localDigest = await _digestOf(unit, localPath);
    final base = await _baseOf(unit);
    final manifestName = unit.manifestName;
    BackupManifest? manifest;
    if (names.contains(manifestName)) {
      final bytes = await remote.read(manifestName);
      manifest = BackupManifest.decode(bytes);
      if (manifest.unitKey != unit.unitKey) {
        throw BackupManifestException(
          '清单与单元不匹配：期望 ${unit.unitKey}，实际 ${manifest.unitKey}',
        );
      }
    }
    return BackupPlanner.plan(
      unit: unit,
      localDigest: localDigest,
      base: base,
      remote: manifest,
    );
  }

  Future<BackupBase> _baseOf(BackupUnit unit) async {
    final row = await store.unit(unit.unitKey);
    if (row == null) return BackupBase.none;
    return BackupBase(generation: row.generation, baseDigest: row.baseDigest);
  }

  Future<String> _digestOf(BackupUnit unit, String path) async {
    final db = await _openDatabase(path);
    try {
      return await BackupDigest.ofUnit(unit, db);
    } finally {
      await db.close();
    }
  }

  Future<void> _push(
    BackupUnit unit,
    BackupPlan plan,
    BackupContext context,
  ) async {
    final localPath = locator.localPathOf(unit);
    final bytes = await File(localPath).readAsBytes();
    final generation = plan.nextGeneration;

    await remote.write(unit.snapshotName(generation), bytes);

    final updatedAt = await context.updatedAtOf?.call(unit);
    final images = await context.imagesOf?.call(unit) ?? const <String>[];
    final manifest = BackupManifest.build(
      unit: unit,
      generation: generation,
      digest: plan.localDigest,
      deviceId: deviceId,
      contentUpdatedAt: updatedAt,
      images: images,
    );
    await remote.write(unit.manifestName, manifest.encode());

    await store.putUnit(SyncUnitRow(
      unitKey: unit.unitKey,
      kind: unit.kind.name,
      refUuid: unit.refUuid,
      generation: generation,
      remoteDigest: plan.localDigest,
      baseDigest: plan.localDigest,
      lastSyncedAt: DateTime.now().toUtc(),
    ));

    await _prune(unit, generation);
  }

  Future<void> _pull(
    BackupUnit unit,
    BackupPlan plan,
    BackupContext context,
  ) async {
    final manifest = plan.remote;
    if (manifest == null) {
      throw BackupRemoteException('缺少云端清单，无法还原 ${unit.unitKey}');
    }
    final bytes = await remote.read(manifest.snapshotName);

    final localPath = locator.localPathOf(unit);
    await context.beforeReplace?.call(unit);
    await _replaceFile(localPath, bytes);
    await context.afterReplace?.call(unit);

    await store.putUnit(SyncUnitRow(
      unitKey: unit.unitKey,
      kind: unit.kind.name,
      refUuid: unit.refUuid,
      generation: manifest.generation,
      remoteDigest: manifest.digest,
      baseDigest: manifest.digest,
      lastSyncedAt: DateTime.now().toUtc(),
    ));
  }

  /// 原子替换：先写 `.tmp` 再改名，避免半截文件把库写坏。
  static Future<void> _replaceFile(String path, List<int> bytes) async {
    final target = File(path);
    await target.parent.create(recursive: true);
    final tmp = File('$path.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    if (await target.exists()) {
      await target.delete();
    }
    await tmp.rename(path);
  }

  /// 按 `keepVersions` 修剪旧快照（各库各算）。
  Future<void> _prune(BackupUnit unit, int latestGeneration) async {
    if (keepVersions <= 0) return;
    final threshold = latestGeneration - keepVersions;
    if (threshold <= 0) return;
    final pattern = RegExp('^${RegExp.escape(unit.baseName)}_shot-g(\\d+)\\.db\$');
    final names = await remote.list();
    for (final name in names) {
      final match = pattern.firstMatch(name);
      if (match == null) continue;
      final generation = int.tryParse(match.group(1)!);
      if (generation == null || generation > threshold) continue;
      await remote.delete(name);
    }
  }

  bool get _cancelled => isCancelled?.call() ?? false;

  void _emit(
    String phase,
    int index,
    int total, {
    BackupUnit? unit,
    String message = '',
  }) {
    onProgress?.call(BackupProgress(
      phase: phase,
      unit: unit,
      index: index,
      total: total,
      message: message,
    ));
  }
}
