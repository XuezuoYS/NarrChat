import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;

import '../models/app_notice.dart';
import '../services/app_repositories.dart';
import '../services/cloud_backup/backup_catalog.dart';
import '../services/cloud_backup/backup_image_plane.dart';
import '../services/cloud_backup/backup_planner.dart';
import '../services/cloud_backup/backup_remote.dart';
import '../services/cloud_backup/backup_runner.dart';
import '../services/cloud_backup/backup_unit.dart';
import '../services/local_config_service.dart';
import '../services/sync/img_tombstones.dart';
import '../services/sync/sync_models.dart';
import '../services/webdav_service.dart';
import '../utils/timestamp_format.dart';

/// 云备份（R3）。
///
/// 数据面完全交给 `lib/services/cloud_backup/`：一个数据库文件 = 一个同步单元
/// = 一个独立代数，冲突只给「整本书」一个选择。这里只负责：
/// - 凭据与设置（URL / 账号 / 密码 / 目录 / 模式 / 保留份数）；
/// - 触发队列（自动 / 手动 / 生命周期恢复）；
/// - 两个平面（数据 / 图片）的状态、进度与提示。
///
/// 云端文件约定（R3）：
/// - `narrchat_library_shot-g<N>.db` / `narrchat_mods_shot-g<N>.db` /
///   `narrbook_<uuid>_shot-g<N>.db`：各库快照；
/// - `manifest_<基名>.json`：每个库一份清单（代数 / 摘要 / 设备 / 引用图片）；
/// - `<hash>.<ext>`：图片 blob；`img_tombstones.json`：图片删除墓碑；
/// - `sync_config.json`：云备份设置（保留份数）。
class CloudSyncProvider extends ChangeNotifier with WidgetsBindingObserver {
  /// - [repositories]：注入仓储（测试传 `TestStack.repos`；生产不传，懒取全局单例）。
  /// - [backupRemoteFactory]：注入云端读写实现（测试传内存替身，不碰真实 WebDAV）。
  /// - [tombstoneStore]：注入图片墓碑工作副本（测试传内存替身，不写真实 local_config）。
  ///
  /// 三者都**构造注入**而不是 `debugSetXxx`：显式依赖一目了然，也不会出现
  /// 「测试之间互相串味」的可变全局状态。
  CloudSyncProvider({
    AppRepositories? repositories,
    BackupRemote Function()? backupRemoteFactory,
    SyncTombstoneStore? tombstoneStore,
  })  : _injectedRepositories = repositories,
        _remoteFactory = backupRemoteFactory,
        _injectedTombstoneStore = tombstoneStore {
    _now = DateTime.now;
  }

  final AppRepositories? _injectedRepositories;
  final BackupRemote Function()? _remoteFactory;
  final SyncTombstoneStore? _injectedTombstoneStore;

  /// 懒取：裸构造（未注入、且全局未初始化）时只有真正用到才会抛，
  /// 不影响 `CloudSyncProvider()` 本身在测试里被创建。
  AppRepositories get _repos => _injectedRepositories ?? AppRepositories.instance;

  BackupRemote _newRemote() =>
      _remoteFactory?.call() ?? WebDavBackupRemote(_createDav());

  SyncTombstoneStore get _tombstones =>
      _injectedTombstoneStore ?? FileTombstoneStore();

  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();

  static const String _keyPassword = 'webdav_password';
  static const String _keyUrl = 'webdavUrl';
  static const String _keyUsername = 'webdavUsername';
  static const String _keyFolder = 'webdavFolder';
  static const String _keyAutoUpload = 'webdavAutoUpload';
  static const String _keySyncMode = 'syncMode';
  static const String _keyDeviceId = 'syncDeviceId';

  /// 旧版本曾把「保留历史版本」存到本地 JSON；现由云端 sync_config.json 持有。
  static const String _legacyKeyKeepVersions = 'webdavKeepVersions';

  static const String defaultFolder = 'narrchat';

  String _webdavUrl = '';
  String _webdavUsername = '';
  String _webdavPassword = '';
  String _folder = defaultFolder;
  int _keepVersions = SyncConfig.defaultKeepVersions;
  bool _keepVersionsLoaded = false;
  bool _autoUpload = false;
  SyncMode _syncMode = SyncMode.auto;
  String _deviceId = '';

  /// 两个平面各自的状态与进度（面板 / 驻场岛直接读）。
  SyncState _dataState = SyncState.idle;
  SyncState _imageState = SyncState.idle;
  SyncProgressEvent? _dataProgress;
  SyncProgressEvent? _imageProgress;
  String? _dataError;
  String? _imageError;
  String? _error;

  List<WebDavFile> _backups = [];
  List<BackupUnitEntry> _backupUnits = const [];
  bool _backupsLoaded = false;

  bool _opsBusy = false;
  bool _running = false;
  bool _cancelRequested = false;
  bool _pendingData = false;
  bool _pendingImages = false;
  final List<Completer<bool>> _manualWaiters = [];

  DateTime? _lastSyncRequestAt;
  DateTime Function() _now = DateTime.now;
  bool _lastDataOk = false;

  /// 数据面还原完成后由外层注册（刷新首页 / 重开书）。
  Future<void> Function()? onDataRestored;

  /// 冲突裁决器：由面板注入（后台同步没有它就把冲突留待用户处理）。
  Future<BackupConflictChoice> Function(BackupPlan plan)? conflictResolver;

  /// 本次同步里没被裁决的冲突（面板用来列出来让用户逐个处理）。
  List<BackupPlan> _unresolvedConflicts = const [];

  List<BackupPlan> get unresolvedConflicts =>
      List.unmodifiable(_unresolvedConflicts);

  /// 串行唤醒的导航器（提示 / 弹窗用）。
  static GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  // --- 设置读取 ---------------------------------------------------------------

  String get webdavUrl => _webdavUrl;
  String get webdavUsername => _webdavUsername;
  String get webdavPassword => _webdavPassword;
  String get folder => _folder;
  int get keepVersions => _keepVersions;
  bool get keepVersionsLoaded => _keepVersionsLoaded;
  bool get autoUpload => _autoUpload;
  SyncMode get syncMode => _syncMode;
  String get deviceId => _deviceId;

  bool get isConfigured =>
      _webdavUrl.trim().isNotEmpty && _webdavUsername.trim().isNotEmpty;

  // --- 状态 -------------------------------------------------------------------

  SyncState get dataSyncState => _dataState;
  SyncState get imageSyncState => _imageState;
  SyncProgressEvent? get dataProgress => _dataProgress;
  SyncProgressEvent? get imageProgress => _imageProgress;
  String? get dataError => _dataError;
  String? get imageError => _imageError;
  String? get error => _error ?? _dataError ?? _imageError;
  bool get isBusy => _opsBusy || _running;
  List<WebDavFile> get backups => List.unmodifiable(_backups);

  /// 云端备份的「库」列表（Library / Mod / 每本书，顺序固定）。
  List<BackupUnitEntry> get backupUnits => List.unmodifiable(_backupUnits);
  bool get backupsLoaded => _backupsLoaded;
  DateTime? get lastSyncRequestAt => _lastSyncRequestAt;

  bool debugPendingSyncRequested(SyncPlane plane) =>
      plane == SyncPlane.data ? _pendingData : _pendingImages;

  bool debugCancelRequested(SyncPlane plane) => _cancelRequested;

  static const int maxResultToasts = 3;
  final List<SyncResultToast> _resultToasts = [];
  int _nextToastId = 0;

  List<SyncResultToast> get resultToasts => List.unmodifiable(_resultToasts);

  /// 推一条同步结果提示（驻场岛展示）。
  void showSyncResult(String message, NoticeKind kind) {
    if (message.trim().isEmpty) return;
    _resultToasts.add(SyncResultToast(
      id: _nextToastId++,
      message: message,
      kind: kind,
    ));
    while (_resultToasts.length > maxResultToasts) {
      _resultToasts.removeAt(0);
    }
    notifyListeners();
  }

  void dismissSyncResult(int id) {
    final before = _resultToasts.length;
    _resultToasts.removeWhere((toast) => toast.id == id);
    if (_resultToasts.length != before) notifyListeners();
  }

  // --- 生命周期 ---------------------------------------------------------------

  static const Duration resumeSyncThrottle = Duration(minutes: 2);

  void attachLifecycle() {
    WidgetsBinding.instance.removeObserver(this);
    WidgetsBinding.instance.addObserver(this);
  }

  void detachLifecycle() {
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (!_autoUpload || _syncMode != SyncMode.auto || !isConfigured) return;
    final last = _lastSyncRequestAt;
    if (last != null && _now().difference(last) < resumeSyncThrottle) return;
    triggerSync();
  }

  /// 触发一次同步（自动档才有意义；手动档只走 [sync]）。
  void triggerSync({SyncKind kind = SyncKind.both, bool silent = false}) {
    // 先过门控再记时刻：被忽略的触发不该占用 2 分钟的节流窗口，
    // 否则用户"在手动模式回前台"会把紧随其后的自动触发也吃掉。
    if (!isConfigured) return;
    if (_syncMode == SyncMode.manual && !silent) return;
    if (_cancelRequested) return;
    _lastSyncRequestAt = _now();
    if (kind != SyncKind.images) _pendingData = true;
    if (kind != SyncKind.data) _pendingImages = true;
    unawaited(_pump());
  }

  /// 手动同步：等这一轮跑完再返回，供按钮展示结果。
  Future<bool> sync() async {
    if (!isConfigured) return false;
    _cancelRequested = false;
    _pendingData = true;
    _pendingImages = true;
    final completer = Completer<bool>();
    _manualWaiters.add(completer);
    unawaited(_pump());
    return completer.future;
  }

  /// 取消当前同步（两个平面共用一个取消位）。
  void cancelSync(SyncPlane plane) {
    _cancelRequested = true;
    notifyListeners();
  }

  // --- 主循环 -----------------------------------------------------------------

  Future<void> _pump() async {
    if (_running) return;
    _running = true;
    notifyListeners();
    try {
      while (_pendingData || _pendingImages) {
        if (_cancelRequested) break;
        if (_pendingData) {
          _pendingData = false;
          final ok = await _runDataPlane();
          _lastDataOk = ok;
        }
        if (_pendingImages) {
          _pendingImages = false;
          await _runImagePlane();
        }
      }
    } finally {
      _running = false;
      _cancelRequested = false;
      final ok = _lastDataOk;
      for (final waiter in List<Completer<bool>>.of(_manualWaiters)) {
        if (!waiter.isCompleted) waiter.complete(ok);
      }
      _manualWaiters.clear();
      notifyListeners();
    }
  }

  Future<bool> _runDataPlane() async {
    _dataState = SyncState.syncing;
    _dataError = null;
    _dataProgress = const SyncProgressEvent(
      phase: SyncPhase.pullManifest,
      label: '准备备份',
    );
    notifyListeners();

    try {
      final stores = _repos.stores;
      final remote = _newRemote();
      final runner = BackupRunner(
        remote: remote,
        locator: BackupLocator(userDataDir: stores.paths.userDataDir),
        store: stores.sync,
        deviceId: _deviceId,
        keepVersions: _keepVersions,
        onProgress: _onDataProgress,
        isCancelled: () => _cancelRequested,
      );

      final report = await runner.run(
        context: BackupContext(
          bookUuids: () async => [
            for (final book in await stores.library.books())
              book.bookUuid,
          ],
          updatedAtOf: (unit) async {
            if (!unit.isBook) return null;
            try {
              final db = await stores.books.open(unit.refUuid);
              return (await db.meta.read()).updatedAt;
            } catch (_) {
              return null;
            }
          },
          imagesOf: (unit) async {
            if (!unit.isBook) return const [];
            try {
              final refs = await stores.cache.imageRefsOf(unit.refUuid);
              return [for (final ref in refs) ref.imagePath];
            } catch (_) {
              return const [];
            }
          },
          beforeReplace: _closeForReplace,
          afterReplace: (_) async {},
        ),
        resolver: conflictResolver,
      );

      _unresolvedConflicts = report.unresolved;
      _dataProgress = null;

      if (report.fatalError != null) {
        _dataState = SyncState.error;
        _dataError = report.fatalError;
        return false;
      }
      if (report.cancelled) {
        _dataState = SyncState.idle;
        return false;
      }

      final failures = report.errors.length;
      if (failures > 0) {
        _dataState = SyncState.error;
        _dataError = report.errors.values.first;
      } else {
        _dataState = SyncState.success;
      }

      if (report.pulled > 0) {
        await onDataRestored?.call();
      }
      if (report.unresolved.isNotEmpty) {
        showSyncResult(
          '有 ${report.unresolved.length} 项云端与本地都改过，请打开云备份设置逐项选择',
          NoticeKind.warning,
        );
      }
      return failures == 0 && !report.hasConflicts;
    } catch (error) {
      _dataState = SyncState.error;
      _dataError = error.toString();
      _dataProgress = null;
      return false;
    } finally {
      notifyListeners();
    }
  }

  Future<void> _runImagePlane() async {
    _imageState = SyncState.syncing;
    _imageError = null;
    _imageProgress = const SyncProgressEvent(
      phase: SyncPhase.pushImages,
      label: '同步图片',
    );
    notifyListeners();

    try {
      final stores = _repos.stores;
      final plane = BackupImagePlane(
        remote: _newRemote(),
        imagesDir: p.join(stores.paths.userDataDir, 'img'),
        tombstoneStore: _tombstones,
      );
      final report = await plane.sync(isCancelled: () => _cancelRequested);
      _imageProgress = null;
      if (report.error != null) {
        _imageState = SyncState.error;
        _imageError = report.error;
      } else {
        _imageState = SyncState.success;
      }
    } catch (error) {
      _imageState = SyncState.error;
      _imageError = error.toString();
      _imageProgress = null;
    } finally {
      notifyListeners();
    }
  }

  /// 换文件前必须把连接关掉：Windows 上文件被占用时替换会失败。
  /// 三个 store 都是懒连接，关掉后下次使用会自动重开。
  Future<void> _closeForReplace(BackupUnit unit) async {
    final stores = _repos.stores;
    switch (unit.kind) {
      case BackupUnitKind.library:
        await stores.library.close();
      case BackupUnitKind.mods:
        await stores.mods.close();
      case BackupUnitKind.book:
        await stores.books.close(unit.refUuid);
    }
  }

  void _onDataProgress(BackupProgress progress) {
    _dataProgress = SyncProgressEvent(
      phase: _phaseOf(progress.phase),
      label: progress.message.isEmpty ? '同步中' : progress.message,
      currentItem: progress.index,
      totalItems: progress.total,
    );
    notifyListeners();
  }

  static SyncPhase _phaseOf(String phase) => switch (phase) {
        'push' => SyncPhase.pushSnapshot,
        'pull' => SyncPhase.pullSnapshot,
        'images' => SyncPhase.pushImages,
        'done' => SyncPhase.idle,
        _ => SyncPhase.merge,
      };

  // --- 设置读写 ---------------------------------------------------------------

  Future<void> load() async {
    try {
      _webdavUrl = await LocalConfigService.readValue<String>(_keyUrl) ?? '';
      _webdavUsername = await LocalConfigService.readValue<String>(_keyUsername) ?? '';
      _folder = await LocalConfigService.readValue<String>(_keyFolder) ?? defaultFolder;
      _autoUpload = await LocalConfigService.readValue<bool>(_keyAutoUpload) ?? false;
      _syncMode = SyncMode.auto;
      _deviceId = await LocalConfigService.readValue<String>(_keyDeviceId) ?? '';
      if (_deviceId.isEmpty) {
        _deviceId = _generateDeviceId();
        await LocalConfigService.update({_keyDeviceId: _deviceId});
      }
      _webdavPassword = await _secureStorage.read(key: _keyPassword) ?? '';
      final legacy = await LocalConfigService.readValue<String>(_legacyKeyKeepVersions);
      if (legacy != null) {
        await LocalConfigService.update({_legacyKeyKeepVersions: null});
      }
    } catch (_) {
      // 读配置失败按"未配置"处理，不影响启动。
    }
    notifyListeners();
  }

  Future<bool> save({
    required String webdavUrl,
    required String webdavUsername,
    required String webdavPassword,
    required String folder,
    SyncMode? syncMode,
    bool? autoUpload,
  }) async {
    _opsBusy = true;
    _error = null;
    notifyListeners();
    try {
      _webdavUrl = webdavUrl.trim();
      _webdavUsername = webdavUsername.trim();
      _webdavPassword = webdavPassword;
      _folder = folder.trim().isEmpty ? defaultFolder : folder.trim();
      if (autoUpload != null) _autoUpload = autoUpload;
      if (syncMode != null) _syncMode = syncMode;

      await LocalConfigService.update({
        _keyUrl: _webdavUrl,
        _keyUsername: _webdavUsername,
        _keyFolder: _folder,
        _keyAutoUpload: _autoUpload,
        _keySyncMode: _syncMode.name,
      });
      if (_webdavPassword.isEmpty) {
        await _secureStorage.delete(key: _keyPassword);
      } else {
        await _secureStorage.write(key: _keyPassword, value: _webdavPassword);
      }
      return true;
    } catch (error) {
      _error = error.toString();
      return false;
    } finally {
      _opsBusy = false;
      notifyListeners();
    }
  }

  Future<bool> setSyncMode(SyncMode mode) async {
    _syncMode = mode;
    try {
      await LocalConfigService.update({_keySyncMode: mode.name});
    } catch (_) {
      // 存不下去也只影响下次启动的默认档位。
    }
    notifyListeners();
    return true;
  }

  Future<void> disconnect() async {
    _webdavUrl = '';
    _webdavUsername = '';
    _webdavPassword = '';
    _folder = defaultFolder;
    _autoUpload = false;
    _backups = [];
    _backupUnits = const [];
    _backupsLoaded = false;
    _dataState = SyncState.idle;
    _imageState = SyncState.idle;
    _dataError = null;
    _imageError = null;
    try {
      await LocalConfigService.update({_keyUrl: null, _keyUsername: null});
      await _secureStorage.delete(key: _keyPassword);
    } catch (_) {
      // 忽略。
    }
    notifyListeners();
  }

  // --- 保留份数（云端 sync_config.json） ---------------------------------------

  Future<String?> refreshKeepVersions() async {
    if (!isConfigured) return '尚未配置云备份';
    try {
      final dav = _createDav();
      await _syncKeepVersionsFromCloud(dav);
      return null;
    } catch (error) {
      return error.toString();
    } finally {
      notifyListeners();
    }
  }

  Future<String?> saveKeepVersions(int value) async {
    if (!isConfigured) return '尚未配置云备份';
    final clamped = value.clamp(
      SyncConfig.minKeepVersions,
      SyncConfig.maxKeepVersions,
    );
    try {
      final dav = _createDav();
      await dav.ensureCollection('');
      await dav.put(
        '',
        SyncConfig.remoteFileName,
        utf8.encode(jsonEncode({'keepVersions': clamped})),
      );
      _keepVersions = clamped;
      _keepVersionsLoaded = true;
      return null;
    } catch (error) {
      return error.toString();
    } finally {
      notifyListeners();
    }
  }

  Future<void> _syncKeepVersionsFromCloud(WebDavService dav) async {
    try {
      final bytes = await dav.get('', SyncConfig.remoteFileName);
      final config = SyncConfig.tryParse(utf8.decode(bytes));
      if (config != null) {
        _keepVersions = config.keepVersions;
      }
      _keepVersionsLoaded = true;
    } catch (_) {
      // 云端还没有配置：用默认值，不算失败。
      _keepVersionsLoaded = true;
    }
  }

  // --- 连接测试 / 备份列表 -----------------------------------------------------

  Future<String?> testConnection({
    String? url,
    String? username,
    String? password,
    String? folder,
  }) async {
    final targetUrl = (url ?? _webdavUrl).trim();
    final targetUser = (username ?? _webdavUsername).trim();
    final targetPass = password ?? _webdavPassword;
    if (targetUrl.isEmpty) return '请填写服务器地址';
    try {
      final dav = WebDavService(
        baseUrl: targetUrl,
        username: targetUser,
        password: targetPass,
      );
      final dir = (folder ?? _folder).trim();
      await dav.ensureCollection('');
      if (dir.isNotEmpty) await dav.ensureCollection(dir);
      await dav.list('');
      dav.close();
      return null;
    } catch (error) {
      return error.toString();
    }
  }

  Future<void> refreshBackups() async {
    if (!isConfigured) return;
    try {
      final dav = _createDav();
      await _loadBackups(dav);
    } catch (error) {
      _error = error.toString();
    } finally {
      notifyListeners();
    }
  }

  Future<void> _loadBackups(WebDavService dav) async {
    final files = await dav.list('');
    _backups = [
      for (final file in files)
        if (BackupUnit.fromSnapshotName(file.name) != null) file,
    ]..sort(compareSnapshots);
    _backupUnits = BackupCatalog.build(
      files: _backups,
      bookTitles: await _bookTitles(),
    );
    _backupsLoaded = true;
  }

  /// 云端各本书的书名（列表展示用）。
  ///
  /// 读本地缓存索引：一次查询拿到全部书名，不用为每本云书开书库。
  /// 读不出来（未初始化 / 缓存损坏）就当没有书名，展示时用 uuid 前 8 位兜底。
  Future<Map<String, String>> _bookTitles() async {
    try {
      final rows = await _repos.stores.cache.allIndex(includeDeleted: true);
      return {
        for (final row in rows)
          if (row.title.trim().isNotEmpty) row.bookUuid: row.title,
      };
    } catch (_) {
      return const {};
    }
  }

  /// 快照从新到旧排序：先按代数降序，再按名字。
  static int compareSnapshots(WebDavFile a, WebDavFile b) =>
      BackupCatalog.compareSnapshots(a, b);

  /// 快照名里的代数（认不出返回 -1）。
  static int generationOfSnapshot(String name) =>
      BackupUnit.generationOfSnapshotName(name);

  /// 快照名 → 同步单元（认不出返回 null）。
  static BackupUnit? unitOfSnapshot(String snapshotName) =>
      BackupUnit.fromSnapshotName(snapshotName);

  /// 用指定快照覆盖本地对应的库。
  ///
  /// 只换**一个单元**：库文件替换后由各 store 懒重开。整本二选一的语义在这里
  /// 落到"用户明确挑了一个快照"。
  ///
  /// [label] 只影响结果提示里的名字（二级页传「书籍《书名》库」这种友好名），
  /// 不传就退回 `unitKey`。
  Future<String?> restoreSnapshot(String snapshotName, {String? label}) async {
    final unit = unitOfSnapshot(snapshotName);
    if (unit == null) return '无法识别的备份文件';
    if (!isConfigured) return '尚未配置云备份';
    _opsBusy = true;
    notifyListeners();
    try {
      final stores = _repos.stores;
      final locator = BackupLocator(userDataDir: stores.paths.userDataDir);
      final remote = _newRemote();
      final bytes = await remote.read(snapshotName);
      await _closeForReplace(unit);

      final target = File(locator.localPathOf(unit));
      await target.parent.create(recursive: true);
      final tmp = File('${target.path}.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      if (await target.exists()) await target.delete();
      await tmp.rename(target.path);

      await onDataRestored?.call();
      showSyncResult('已还原 ${label ?? unit.unitKey}', NoticeKind.success);
      return null;
    } catch (error) {
      return error.toString();
    } finally {
      _opsBusy = false;
      notifyListeners();
    }
  }

  /// 把某个单元的冲突裁决应用到本地/云端（面板里逐个处理用）。
  Future<String?> resolveConflict(BackupPlan plan, BackupConflictChoice choice) async {
    if (choice == BackupConflictChoice.skip) return null;
    final stores = _repos.stores;
    final locator = BackupLocator(userDataDir: stores.paths.userDataDir);
    final remote = _newRemote();
    try {
      if (choice == BackupConflictChoice.remote) {
        final manifest = plan.remote;
        if (manifest == null) return '云端清单缺失';
        final bytes = await remote.read(manifest.snapshotName);
        await _closeForReplace(plan.unit);
        final target = File(locator.localPathOf(plan.unit));
        final tmp = File('${target.path}.tmp');
        await tmp.writeAsBytes(bytes, flush: true);
        if (await target.exists()) await target.delete();
        await tmp.rename(target.path);
        await onDataRestored?.call();
      } else {
        // 保留本地：直接推一代上去。
        final runner = BackupRunner(
          remote: remote,
          locator: locator,
          store: stores.sync,
          deviceId: _deviceId,
          keepVersions: _keepVersions,
        );
        await runner.run(
          context: BackupContext(
            bookUuids: () async => [plan.unit.refUuid],
            beforeReplace: _closeForReplace,
          ),
          units: [plan.unit],
          resolver: (_) async => BackupConflictChoice.local,
        );
      }
      _unresolvedConflicts = [
        for (final item in _unresolvedConflicts)
          if (item.unit != plan.unit) item,
      ];
      notifyListeners();
      return null;
    } catch (error) {
      return error.toString();
    }
  }

  // --- 内部工具 ---------------------------------------------------------------

  WebDavService _createDav() => WebDavService(
        baseUrl: _webdavUrl,
        username: _webdavUsername,
        password: _webdavPassword,
      );

  static String _generateDeviceId() {
    final rand = math.Random.secure();
    final bytes = List<int>.generate(8, (_) => rand.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  // --- 调试钩子（测试用，尽量与旧 API 对齐） -----------------------------------

  void debugSetSyncState(SyncPlane plane, SyncState state) {
    if (plane == SyncPlane.data) {
      _dataState = state;
    } else {
      _imageState = state;
    }
    notifyListeners();
  }

  void debugSetProgress(SyncPlane plane, SyncProgressEvent? event) {
    if (plane == SyncPlane.data) {
      _dataProgress = event;
    } else {
      _imageProgress = event;
    }
    notifyListeners();
  }

  void debugSetPlaneErrors({String? data, String? images}) {
    _dataError = data;
    _imageError = images;
    notifyListeners();
  }

  /// 直接塞入备份列表（测试用）。[bookTitles] 是「书 uuid → 书名」，
  /// 用来验证分组列表的书名与兜底。
  void debugSetBackups(
    List<WebDavFile> backups, {
    Map<String, String> bookTitles = const {},
  }) {
    _backups = List.of(backups);
    _backupUnits = BackupCatalog.build(files: _backups, bookTitles: bookTitles);
    _backupsLoaded = true;
    notifyListeners();
  }

  void debugSetConfigured({bool value = true}) {
    _webdavUrl = value ? 'https://example.invalid/dav' : '';
    _webdavUsername = value ? 'tester' : '';
    _webdavPassword = value ? 'secret' : '';
    notifyListeners();
  }

  /// 直接改「自动同步」开关（测试用）。
  ///
  /// 生产里这个值只能从本地配置读（[load]）或经 [save] 写，而
  /// [didChangeAppLifecycleState] 的门控要求它为 true —— 没有这个钩子，
  /// 「回前台触发 + 节流」那条链在测试里根本走不到。
  @visibleForTesting
  void debugSetAutoUpload(bool value) {
    _autoUpload = value;
    notifyListeners();
  }

  void debugSetNow(DateTime Function()? now) {
    _now = now ?? DateTime.now;
  }

  void debugClearSyncRequestAt() {
    _lastSyncRequestAt = null;
  }

  void debugSetSyncMode(SyncMode mode) {
    _syncMode = mode;
    notifyListeners();
  }

  void debugSetKeepVersions(int value) {
    _keepVersions = value;
    _keepVersionsLoaded = true;
    notifyListeners();
  }

  void debugSetLaneBusy(bool value) {
    _opsBusy = value;
    notifyListeners();
  }

  /// 当前快照命中的单元（面板展示用）。
  String describeSnapshot(String name) {
    final unit = unitOfSnapshot(name);
    if (unit == null) return '未知备份';
    final stamp = formatTimestamp(DateTime.now());
    return '${unit.unitKey} · $stamp';
  }
}
