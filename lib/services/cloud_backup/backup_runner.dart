import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../database/sqflite_desktop.dart';
import '../../database/sync_store.dart';
import 'backup_book_purge.dart';
import 'backup_digest.dart';
import 'backup_image_plane.dart';
import 'backup_manifest.dart';
import 'backup_metrics.dart';
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
    this.deletedBookUuids,
    this.purgeLocalBook,
    this.imagesOf,
    this.beforeReplace,
    this.afterReplace,
    this.afterStructuralUnits,
  });

  /// 当前**未删除**的书 uuid（删掉的书不推数据库，只靠 library 墓碑传播）。
  final Future<List<String>> Function() bookUuids;

  /// 当前 library 里所有墓碑书的 uuid。
  ///
  /// 数据面每轮按它整理：先清本机残留，云端只保留最新同步的一代快照
  /// （更早的代删掉），供「书籍回收站」还原。
  final Future<List<String>> Function()? deletedBookUuids;

  /// 清掉某本书的本机数据（书库 / 缓存行 / 高度 / 图片引用），**不动墓碑**。
  final Future<void> Function(String bookUuid)? purgeLocalBook;

  /// 单元引用的图片相对路径（写进清单，还原时顺带拉图）。
  final Future<List<String>> Function(BackupUnit unit)? imagesOf;

  /// 用云端文件覆盖本地文件**之前**调用（上层负责关掉数据库连接）。
  final Future<void> Function(BackupUnit unit)? beforeReplace;

  /// 覆盖完成**之后**调用（上层负责重新打开连接 / 刷新页面）。
  final Future<void> Function(BackupUnit unit)? afterReplace;

  /// library / mods 处理完、墓碑整理与书单元发现**之前**调用。
  ///
  /// 上层在这里做「书架按行自动合并」：合并后本机的墓碑清单与书单元才准确，
  /// 否则会按合并前的旧目录去推书 / 整理云端。参数是**本轮的云端连接**，
  /// 复用它可以省掉一次握手，也保证读的是同一个云端目录。
  final Future<void> Function(BackupRemote remote)? afterStructuralUnits;
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

  /// `prepare` / `digest` / `push` / `pull` / `images` / `retain` / `done`。
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
    this.trimmed = 0,
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

  /// 本轮真正删掉旧代快照的已删除书籍数（正常删除只留最新一代）。
  final int trimmed;

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
///
/// 已删除的书不参与推拉：处理完 library 后，按其墓碑清本机残留，并把云端
/// 该书单元整理成**只剩最新同步的一代**。
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
    var names = await remote.list();
    final state = _RunState();

    // 1) 先处理结构性单元：library 的墓碑必须先落地，后面的书单元清单才可靠。
    final structural = units ?? const [BackupUnit.library, BackupUnit.mods];
    final aborted = await _runUnits(
      targets: structural,
      state: state,
      names: names,
      context: context,
      resolver: resolver,
    );

    // 2) 书架按行合并（见 [BackupContext.afterStructuralUnits]）：必须在墓碑
    // 整理与书单元发现之前，合并后的目录才决定「哪些书该清、哪些该补下来」。
    if (!aborted && units == null && !_cancelled) {
      await context.afterStructuralUnits?.call(remote);

      // 3) 按墓碑整理已删除的书（本机清残留 + 云端只留最新一代），再做书单元
      // 的发现与推拉。
      //
      // 顺序很关键：拉下来的 library 若带着新墓碑，必须在发现书单元**之前**
      // 整理，否则会把刚删掉的书原地推回云端。
      final deleted =
          await context.deletedBookUuids?.call() ?? const <String>[];
      if (deleted.isNotEmpty) {
        // 刷新一次列表：吃掉别处刚推上来的文件，避免只处理到旧名单。
        names = await remote.list();
        for (var i = 0; i < deleted.length; i++) {
          if (_cancelled) break;
          final bookUuid = deleted[i];
          _emit('retain', i, deleted.length, message: '整理已删除的书');
          final unitKey = BackupUnit.book(bookUuid).unitKey;
          // 本机清不掉（文件被锁）不能连累云端：两边分别尝试、分别记错。
          var localError = '';
          try {
            await context.purgeLocalBook?.call(bookUuid);
          } catch (error) {
            localError = error.toString();
          }
          try {
            final retained = await retainLatestRemoteBookSnapshot(
              remote: remote,
              bookUuid: bookUuid,
              remoteNames: names,
              store: store,
            );
            if (retained.removed > 0) state.trimmed++;
          } catch (error) {
            state.errors[unitKey] = error.toString();
          }
          if (localError.isNotEmpty) {
            state.errors.putIfAbsent(unitKey, () => localError);
          }
        }
      }
      if (!_cancelled) {
        final books = [
          for (final uuid in await context.bookUuids()) BackupUnit.book(uuid),
        ];
        await _runUnits(
          targets: books,
          state: state,
          names: names,
          context: context,
          resolver: resolver,
        );
      }
    }

    BackupImageReport? imageReport;
    if (images != null && !_cancelled && state.fatalError == null) {
      _emit('images', structural.length, structural.length, message: '同步图片');
      imageReport = await images.sync(isCancelled: isCancelled);
    }

    _emit('done', structural.length, structural.length, message: '完成');

    return BackupReport(
      plans: state.plans,
      pushed: state.pushed,
      pulled: state.pulled,
      upToDate: state.upToDate,
      skipped: state.skipped,
      trimmed: state.trimmed,
      unresolved: state.unresolved,
      errors: state.errors,
      fatalError: state.fatalError,
      cancelled: _cancelled,
      images: imageReport,
    );
  }

  /// 依次处理一批单元；返回是否因结构性错误（清单损坏）中止整轮。
  Future<bool> _runUnits({
    required List<BackupUnit> targets,
    required _RunState state,
    required Set<String> names,
    required BackupContext context,
    required BackupConflictResolver? resolver,
  }) async {
    for (var i = 0; i < targets.length; i++) {
      if (_cancelled) return false;
      final unit = targets[i];
      _emit(
        'digest',
        i,
        targets.length,
        unit: unit,
        message: '检查 ${unit.unitKey}',
      );
      try {
        final plan = await _planFor(unit, names, context);
        state.plans.add(plan);
        switch (plan.action) {
          case BackupAction.upToDate:
            state.upToDate++;
          case BackupAction.skipped:
            state.skipped++;
          case BackupAction.push:
            _emit(
              'push',
              i,
              targets.length,
              unit: unit,
              message: '备份 ${unit.unitKey}',
            );
            await _push(unit, plan, context);
            state.pushed++;
          case BackupAction.pull:
            _emit(
              'pull',
              i,
              targets.length,
              unit: unit,
              message: '还原 ${unit.unitKey}',
            );
            await _pull(unit, plan, context);
            state.pulled++;
          case BackupAction.conflict:
            final choice =
                await resolver?.call(plan) ?? BackupConflictChoice.skip;
            if (_cancelled) return false;
            if (choice == BackupConflictChoice.local) {
              _emit(
                'push',
                i,
                targets.length,
                unit: unit,
                message: '备份 ${unit.unitKey}',
              );
              await _push(unit, plan, context);
              state.pushed++;
            } else if (choice == BackupConflictChoice.remote) {
              _emit(
                'pull',
                i,
                targets.length,
                unit: unit,
                message: '还原 ${unit.unitKey}',
              );
              await _pull(unit, plan, context);
              state.pulled++;
            } else {
              state.unresolved.add(plan);
            }
        }
      } on BackupManifestException catch (error) {
        // 清单存在但读不懂：立刻停止，绝不把它当空清单重新 bootstrap。
        state.fatalError = error.message;
        return true;
      } catch (error) {
        state.errors[unit.unitKey] = error.toString();
      }
    }
    return false;
  }

  Future<BackupPlan> _planFor(
    BackupUnit unit,
    Set<String> names,
    BackupContext context,
  ) async {
    final base = await _baseOf(unit);
    final manifest = await _manifestOf(unit, names);
    final localPath = locator.localPathOf(unit);
    if (!await File(localPath).exists()) {
      // 本机没有这个库 / 这本书：云端有清单就补下来（换设备后的首轮、或本机
      // 文件被手动删掉）。云端也没有才算跳过。
      if (manifest != null) {
        return BackupPlan(
          unit: unit,
          action: BackupAction.pull,
          base: base,
          localDigest: '',
          remote: manifest,
          reason: '本机还没有这个库，从云端补齐',
        );
      }
      return BackupPlan(
        unit: unit,
        action: BackupAction.skipped,
        base: base,
        localDigest: '',
        reason: '本地文件不存在',
      );
    }

    final local = await _localInfoOf(unit, localPath);
    return BackupPlanner.plan(
      unit: unit,
      localDigest: local.digest,
      localMetrics: local.metrics,
      base: base,
      remote: manifest,
    );
  }

  /// 读云端清单；没有该文件返回 null（清单存在但读不懂照样抛异常）。
  Future<BackupManifest?> _manifestOf(
    BackupUnit unit,
    Set<String> names,
  ) async {
    final manifestName = unit.manifestName;
    if (!names.contains(manifestName)) return null;
    final manifest = BackupManifest.decode(await remote.read(manifestName));
    if (manifest.unitKey != unit.unitKey) {
      throw BackupManifestException(
        '清单与单元不匹配：期望 ${unit.unitKey}，实际 ${manifest.unitKey}',
      );
    }
    return manifest;
  }

  Future<BackupBase> _baseOf(BackupUnit unit) async {
    final row = await store.unit(unit.unitKey);
    if (row == null) return BackupBase.none;
    return BackupBase(generation: row.generation, baseDigest: row.baseDigest);
  }

  /// 一次开库同时取「内容摘要」与「内容指标」（PK / 写清单共用，不重复开库）。
  Future<({String digest, BackupUnitMetrics metrics})> _localInfoOf(
    BackupUnit unit,
    String path,
  ) async {
    return _withFileRetry(() async {
      final db = await _openDatabase(path);
      try {
        return (
          digest: await BackupDigest.ofUnit(unit, db),
          metrics: await BackupMetricsReader.read(unit, db),
        );
      } finally {
        await db.close();
      }
    });
  }

  /// 短暂的文件锁在 Windows 上很常见（系统索引 / 杀毒 / 刚关闭的连接）。
  ///
  /// 只对**读**做极少次重试（3 次、退避 30/120ms）：写操作重试有产生半截
  /// 状态的风险，宁可失败。重试只是为了吃掉"另一条连接刚关、系统还没放锁"。
  static Future<T> _withFileRetry<T>(Future<T> Function() action) async {
    const delays = [Duration(milliseconds: 30), Duration(milliseconds: 120)];
    for (var attempt = 0; ; attempt++) {
      try {
        return await action();
      } catch (_) {
        if (attempt >= delays.length) rethrow;
        await Future<void>.delayed(delays[attempt]);
      }
    }
  }

  Future<void> _push(
    BackupUnit unit,
    BackupPlan plan,
    BackupContext context,
  ) async {
    final localPath = locator.localPathOf(unit);
    final bytes = await _withFileRetry(() => File(localPath).readAsBytes());
    final generation = plan.nextGeneration;

    await remote.write(unit.snapshotName(generation), bytes);

    final metrics = plan.localMetrics;
    final images = await context.imagesOf?.call(unit) ?? const <String>[];
    final manifest = BackupManifest.build(
      unit: unit,
      generation: generation,
      digest: plan.localDigest,
      deviceId: deviceId,
      contentUpdatedAt: metrics?.updatedAt,
      latestRoundIndex: metrics?.latestRoundIndex ?? 0,
      roundGenerationCount: metrics?.roundGenerationCount ?? 0,
      images: images,
    );
    await remote.write(unit.manifestName, manifest.encode());

    await store.putUnit(
      SyncUnitRow(
        unitKey: unit.unitKey,
        kind: unit.kind.name,
        refUuid: unit.refUuid,
        generation: generation,
        remoteDigest: plan.localDigest,
        baseDigest: plan.localDigest,
        lastSyncedAt: DateTime.now().toUtc(),
      ),
    );

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

    await store.putUnit(
      SyncUnitRow(
        unitKey: unit.unitKey,
        kind: unit.kind.name,
        refUuid: unit.refUuid,
        generation: manifest.generation,
        remoteDigest: manifest.digest,
        baseDigest: manifest.digest,
        lastSyncedAt: DateTime.now().toUtc(),
      ),
    );
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
    final pattern = RegExp(
      '^${RegExp.escape(unit.baseName)}_shot-g(\\d+)\\.db\$',
    );
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
    onProgress?.call(
      BackupProgress(
        phase: phase,
        unit: unit,
        index: index,
        total: total,
        message: message,
      ),
    );
  }
}

/// 一轮同步的累计结果（分两批处理单元时共用一套计数器）。
class _RunState {
  final List<BackupPlan> plans = [];
  final List<BackupPlan> unresolved = [];
  final Map<String, String> errors = {};

  int pushed = 0;
  int pulled = 0;
  int upToDate = 0;
  int skipped = 0;
  int trimmed = 0;

  String? fatalError;
}
