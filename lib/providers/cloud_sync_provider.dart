import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;

import '../models/app_notice.dart';
import '../services/app_repositories.dart';
import '../services/cloud_backup/backup_book_purge.dart';
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
/// 云端目录约定（R3）——**数据与图片各进各的目录**：
/// - 数据面：用户设定的文件夹（默认 `narrchat`）下放各库快照
///   `narrchat_library_shot-g<N>.db` / `narrchat_mods_shot-g<N>.db` /
///   `narrbook_<uuid>_shot-g<N>.db`、清单 `manifest_<基名>.json` 与
///   `sync_config.json`；
/// - 图片面：同一文件夹下的 `img` 子目录（默认 `narrchat/img`）里放图片 blob
///   `<hash>.<ext>` 与图片墓碑 `img_tombstones.json`。
///
/// WebDAV 根目录不放任何应用文件；文件夹在首次同步 / 保存保留份数时自动建出。
class CloudSyncProvider extends ChangeNotifier with WidgetsBindingObserver {
  /// - [repositories]：注入仓储（测试传 `TestStack.repos`；生产不传，懒取全局单例）。
  /// - [backupRemoteFactory]：注入云端读写实现（测试传内存替身，不碰真实 WebDAV）。
  ///   替身不区分数据 / 图片目录；生产实现由 [WebDavBackupRemote.folder] 分层。
  /// - [webDavFactory]：注入云端目录读写（备份列表 / `sync_config.json` /
  ///   测试连接用；测试传内存替身，不碰网络）。
  /// - [tombstoneStore]：注入图片墓碑工作副本（测试传内存替身，不写真实 local_config）。
  ///
  /// 全都**构造注入**而不是 `debugSetXxx`：显式依赖一目了然，也不会出现
  /// 「测试之间互相串味」的可变全局状态。
  CloudSyncProvider({
    AppRepositories? repositories,
    BackupRemote Function()? backupRemoteFactory,
    WebDavService Function()? webDavFactory,
    SyncTombstoneStore? tombstoneStore,
  }) : _injectedRepositories = repositories,
       _remoteFactory = backupRemoteFactory,
       _davFactory = webDavFactory,
       _injectedTombstoneStore = tombstoneStore {
    _now = DateTime.now;
  }

  final AppRepositories? _injectedRepositories;
  final BackupRemote Function()? _remoteFactory;
  final WebDavService Function()? _davFactory;
  final SyncTombstoneStore? _injectedTombstoneStore;

  /// 懒取：裸构造（未注入、且全局未初始化）时只有真正用到才会抛，
  /// 不影响 `CloudSyncProvider()` 本身在测试里被创建。
  AppRepositories get _repos =>
      _injectedRepositories ?? AppRepositories.instance;

  BackupRemote _newRemote(String folder) =>
      _remoteFactory?.call() ??
      WebDavBackupRemote(_createDav(), folder: folder);

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

  /// 把用户输入的文件夹规范成云端相对路径。
  ///
  /// 去空白、去首尾 / 重复斜杠，丢掉 `.` 与 `..` 段（避免拼到基础地址外面），
  /// 空值回落 [defaultFolder]。
  static String normalizeFolder(String raw) {
    final segments = [
      for (final segment in raw.trim().split('/'))
        if (segment.isNotEmpty && segment != '.' && segment != '..') segment,
    ];
    return segments.isEmpty ? defaultFolder : segments.join('/');
  }

  /// 图片面的云端目录：数据目录下的 `img` 子目录（默认 `narrchat/img`）。
  static String imagesFolderOf(String folder) =>
      '${normalizeFolder(folder)}/img';

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
  List<BackupUnitEntry> _deletedBackupUnits = const [];
  Map<String, String> _bookTitlesCache = const {};
  Map<String, BackupDeletedBook> _deletedBookMarks = const {};
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

  /// 「保留历史版本」份数（云端 `sync_config.json` 唯一权威）。
  ///
  /// 进入云同步面板 / 点刷新 / 每次数据面同步前都会自动读一次；
  /// 从未读到过时保持默认 5，但 [keepVersionsLoaded] 为 false（面板显示「—」）。
  int get keepVersions => _keepVersions;
  bool get keepVersionsLoaded => _keepVersionsLoaded;
  bool get autoUpload => _autoUpload;
  SyncMode get syncMode => _syncMode;
  String get deviceId => _deviceId;

  bool get isConfigured =>
      _webdavUrl.trim().isNotEmpty && _webdavUsername.trim().isNotEmpty;

  /// 自动同步是否真的会跑（与 [triggerSync] 的门控同一套条件）。
  ///
  /// 删除书籍时用它决定：自动同步会跑就交给数据面按墓碑整理（library 先推，
  /// 云端只留最新一代）；不会跑才立即尽力整理一次。
  bool get autoSyncEnabled =>
      isConfigured && _syncMode == SyncMode.auto && _autoUpload;

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

  /// 云端备份的「库」列表（Library / Mod / 每本书，顺序固定；不含已删除）。
  List<BackupUnitEntry> get backupUnits => List.unmodifiable(_backupUnits);

  /// 已删除书籍的云端备份条目（每本一行，只有最新一代；按删除时间新 → 旧）。
  List<BackupUnitEntry> get deletedBackupUnits =>
      List.unmodifiable(_deletedBackupUnits);
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
    _resultToasts.add(
      SyncResultToast(id: _nextToastId++, message: message, kind: kind),
    );
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
      final remote = _newRemote(_folder);
      // 修剪份数以云端 sync_config.json 为唯一权威：冷启动的自动同步若直接用
      // 内存默认值，会把用户要求的更早快照误删（R2 同款保证）。
      final keepVersions = await _readKeepVersionsForSync(remote);
      final runner = BackupRunner(
        remote: remote,
        locator: BackupLocator(userDataDir: stores.paths.userDataDir),
        store: stores.sync,
        deviceId: _deviceId,
        keepVersions: keepVersions,
        onProgress: _onDataProgress,
        isCancelled: () => _cancelRequested,
      );

      final report = await runner.run(
        context: BackupContext(
          bookUuids: () async => [
            for (final book in await stores.library.books()) book.bookUuid,
          ],
          // 已删除的书不推数据库；runner 在书单元之前按墓碑清本机残留，
          // 云端只留最新一代，供「书籍回收站」还原。
          deletedBookUuids: () async => [
            for (final row in await stores.library.books(includeDeleted: true))
              if (row.isDeleted) row.bookUuid,
          ],
          purgeLocalBook: (bookUuid) => _repos.books.purgeBookData(bookUuid),
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
        remote: _newRemote(imagesFolderOf(_folder)),
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
    'retain' => SyncPhase.retainDeletedBooks,
    'done' => SyncPhase.idle,
    _ => SyncPhase.merge,
  };

  // --- 设置读写 ---------------------------------------------------------------

  Future<void> load() async {
    try {
      _webdavUrl = await LocalConfigService.readValue<String>(_keyUrl) ?? '';
      _webdavUsername =
          await LocalConfigService.readValue<String>(_keyUsername) ?? '';
      _folder = normalizeFolder(
        await LocalConfigService.readValue<String>(_keyFolder) ?? defaultFolder,
      );
      _autoUpload =
          await LocalConfigService.readValue<bool>(_keyAutoUpload) ?? false;
      _syncMode = SyncMode.auto;
      _deviceId =
          await LocalConfigService.readValue<String>(_keyDeviceId) ?? '';
      if (_deviceId.isEmpty) {
        _deviceId = _generateDeviceId();
        await LocalConfigService.update({_keyDeviceId: _deviceId});
      }
      _webdavPassword = await _secureStorage.read(key: _keyPassword) ?? '';
      final legacy = await LocalConfigService.readValue<String>(
        _legacyKeyKeepVersions,
      );
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
      _folder = normalizeFolder(folder);
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
    _deletedBackupUnits = const [];
    _bookTitlesCache = const {};
    _deletedBookMarks = const {};
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

  /// 强制从云端读一次「保留历史版本」。
  ///
  /// - 成功 / 云端本来没有该文件 → 返回 null 并刷新展示缓存；
  /// - 读取失败 → 返回**原生异常文本**（「保留历史版本」弹窗内联展示后可重试）。
  Future<String?> refreshKeepVersions() async {
    if (!isConfigured) return '尚未配置云备份';
    final dav = _createDav();
    try {
      _applyCloudSyncConfig(await dav.get(_folder, SyncConfig.remoteFileName));
      return null;
    } on WebDavException catch (error) {
      if (error.statusCode == 404) {
        _applyMissingCloudSyncConfig();
        return null;
      }
      return error.toString();
    } catch (error) {
      return error.toString();
    } finally {
      dav.close();
      notifyListeners();
    }
  }

  Future<String?> saveKeepVersions(int value) async {
    if (!isConfigured) return '尚未配置云备份';
    final clamped = value.clamp(
      SyncConfig.minKeepVersions,
      SyncConfig.maxKeepVersions,
    );
    final dav = _createDav();
    try {
      await dav.ensurePath(_folder);
      await dav.put(
        _folder,
        SyncConfig.remoteFileName,
        utf8.encode(jsonEncode({'keepVersions': clamped})),
      );
      _keepVersions = clamped;
      _keepVersionsLoaded = true;
      return null;
    } catch (error) {
      return error.toString();
    } finally {
      dav.close();
      notifyListeners();
    }
  }

  /// 展示缓存：读云端 `sync_config.json` 更新「保留历史版本」。
  ///
  /// 顺带刷新（面板打开 / 手动刷新 / 同步后）用：失败**静默保留上一次缓存**
  /// （从未读到过就继续显示「—」），错误框只归因备份列表；云端没有该文件
  /// 按默认值处理。
  Future<void> _syncKeepVersionsFromCloud(WebDavService dav) async {
    try {
      _applyCloudSyncConfig(await dav.get(_folder, SyncConfig.remoteFileName));
    } on WebDavException catch (error) {
      if (error.statusCode == 404) _applyMissingCloudSyncConfig();
    } catch (_) {
      // 静默：保留旧值（见 doc）。
    }
  }

  /// 数据面开始前解析本轮修剪份数（云端 `sync_config.json` 唯一权威）。
  ///
  /// - 读到 → 更新展示缓存并返回云端值；
  /// - 云端还没有该文件（404）→ 默认值（并标记已加载）；
  /// - 其它失败 → 0 = **本轮不修剪**（宁可多留，绝不误删）。
  Future<int> _readKeepVersionsForSync(BackupRemote remote) async {
    try {
      return _applyCloudSyncConfig(
        await remote.read(SyncConfig.remoteFileName),
      );
    } on BackupRemoteException catch (error) {
      if (error.statusCode == 404) return _applyMissingCloudSyncConfig();
      return 0;
    } catch (_) {
      return 0;
    }
  }

  /// 解析云端 `sync_config.json` 字节并更新展示缓存；返回生效的份数。
  ///
  /// 内容是空白 / 非法 JSON → 与「云端没配置」同义，按默认值处理。
  int _applyCloudSyncConfig(List<int> bytes) {
    final config = SyncConfig.tryParse(utf8.decode(bytes));
    final value = config?.keepVersions ?? SyncConfig.defaultKeepVersions;
    _keepVersions = value;
    _keepVersionsLoaded = true;
    return value;
  }

  /// 云端还没有 `sync_config.json`：默认值 + 标记已加载。
  int _applyMissingCloudSyncConfig() {
    const value = SyncConfig.defaultKeepVersions;
    _keepVersions = value;
    _keepVersionsLoaded = true;
    return value;
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
      // 生产按表单里的地址 / 账号临时建一个客户端；测试注入内存替身（不碰网络）。
      final dav = _davFactory?.call() ??
          WebDavService(
            baseUrl: targetUrl,
            username: targetUser,
            password: targetPass,
          );
      final dir = normalizeFolder(folder ?? _folder);
      await dav.ensurePath(dir);
      await dav.list(dir);
      dav.close();
      return null;
    } catch (error) {
      return error.toString();
    }
  }

  /// 刷新云端备份列表（**顺带**拉一次 `sync_config.json` 更新「保留历史版本」）。
  ///
  /// 面板打开 / 点「刷新」/ 同步完成后都会走到这里，因此保留份数无需先点开
  /// 弹窗就能显示云端真值（R2 同款行为，v3 重写时漏掉了）。
  Future<void> refreshBackups() async {
    if (!isConfigured) return;
    final dav = _createDav();
    try {
      await _loadBackups(dav);
      await _syncKeepVersionsFromCloud(dav);
    } catch (error) {
      _error = error.toString();
    } finally {
      dav.close();
      notifyListeners();
    }
  }

  Future<void> _loadBackups(WebDavService dav) async {
    final files = await _listCloudFolder(dav);
    _backups = [
      for (final file in files)
        if (BackupUnit.fromSnapshotName(file.name) != null) file,
    ]..sort(compareSnapshots);
    final snapshot = await _librarySnapshot();
    _bookTitlesCache = snapshot.titles;
    _deletedBookMarks = snapshot.deleted;
    _rebuildBackupCatalog();
    _backupsLoaded = true;
  }

  /// 列云端数据目录；目录还不存在（404）按空处理。
  ///
  /// 第一次配置后、首次同步前，文件夹本来就不存在。这时打开面板应该显示
  /// 「云端暂无备份」，而不是弹「列出失败」；真正建目录交给同步入口。
  Future<List<WebDavFile>> _listCloudFolder(WebDavService dav) async {
    try {
      return await dav.list(_folder);
    } on WebDavException catch (error) {
      if (error.statusCode == 404) return const [];
      rethrow;
    }
  }

  /// 一次读目录库，同时拿到「书 uuid → 书名」与「墓碑书 → 删除信息」。
  ///
  /// 直接读**目录库**（含墓碑）：墓碑书的书名与删除轮号都还在，且不需要
  /// 打开任何书库；读不出来（未初始化 / 目录损坏）就当没有，展示时用 uuid
  /// 前 8 位兜底。
  Future<({Map<String, String> titles, Map<String, BackupDeletedBook> deleted})>
  _librarySnapshot() async {
    try {
      final rows = await _repos.stores.library.books(includeDeleted: true);
      final titles = <String, String>{};
      final deleted = <String, BackupDeletedBook>{};
      for (final row in rows) {
        if (row.title.trim().isNotEmpty) {
          titles[row.bookUuid] = row.title;
        }
        if (row.isDeleted) {
          deleted[row.bookUuid] = BackupDeletedBook(
            deletedAt: row.deletedAt,
            roundIndex: row.deletedRoundIndex,
          );
        }
      }
      return (titles: titles, deleted: deleted);
    } catch (_) {
      return (
        titles: <String, String>{},
        deleted: <String, BackupDeletedBook>{},
      );
    }
  }

  /// 用当前云端文件 + 本机目录重建备份列表（活书 / 已删除分开）。
  void _rebuildBackupCatalog() {
    final entries = BackupCatalog.build(
      files: _backups,
      bookTitles: _bookTitlesCache,
      deletedBooks: _deletedBookMarks,
    );
    _backupUnits = [
      for (final entry in entries)
        if (!entry.isDeleted) entry,
    ];
    _deletedBackupUnits = [
      for (final entry in entries)
        if (entry.isDeleted) entry,
    ];
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
      final remote = _newRemote(_folder);
      final bytes = await remote.read(snapshotName);
      await _closeForReplace(unit);

      final target = File(locator.localPathOf(unit));
      await target.parent.create(recursive: true);
      final tmp = File('${target.path}.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      if (await target.exists()) await target.delete();
      await tmp.rename(target.path);
      await _afterUnitReplaced(unit);

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
  Future<String?> resolveConflict(
    BackupPlan plan,
    BackupConflictChoice choice,
  ) async {
    if (choice == BackupConflictChoice.skip) return null;
    final stores = _repos.stores;
    final locator = BackupLocator(userDataDir: stores.paths.userDataDir);
    final remote = _newRemote(_folder);
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
        await _afterUnitReplaced(plan.unit);
        await onDataRestored?.call();
      } else {
        // 保留本地：直接推一代上去（修剪份数同样以云端配置为准）。
        final keepVersions = await _readKeepVersionsForSync(remote);
        final runner = BackupRunner(
          remote: remote,
          locator: locator,
          store: stores.sync,
          deviceId: _deviceId,
          keepVersions: keepVersions,
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

  // --- 删除与回收站 -----------------------------------------------------------

  /// 一本书被删除后的云端动作。
  ///
  /// - 自动同步真的会跑：交给数据面（library 先推，runner 再按墓碑整理该书
  ///   单元，只留最新一代），顺序保证不会把刚删掉的书原地推回去；
  /// - 否则：立即尽力整理一次云端书单元，失败静默——墓碑还在，下次同步兜底。
  void handleBookDeleted(String bookUuid) {
    if (bookUuid.isEmpty) return;
    // 这本书都删了，留着它的冲突裁决没有意义。
    _dropUnresolvedConflict(BackupUnit.book(bookUuid));
    if (!isConfigured) return;
    if (autoSyncEnabled) {
      triggerSync(kind: SyncKind.data);
      return;
    }
    unawaited(
      retainDeletedBookBackup(bookUuid).then((error) {
        if (error != null) debugPrint('整理云端书备份失败（下次同步重试）：$error');
      }),
    );
  }

  /// 立即整理某本已删除书籍的云端备份：只留最新同步的一代（尽力而为）。
  ///
  /// 返回错误文本（成功为 null）。后台调用只记日志即可：墓碑还在，
  /// 下一次数据面同步会重试。
  Future<String?> retainDeletedBookBackup(String bookUuid) async {
    if (bookUuid.isEmpty || !isConfigured) return null;
    final remote = _newRemote(_folder);
    try {
      await remote.ensureReady();
      await retainLatestRemoteBookSnapshot(
        remote: remote,
        bookUuid: bookUuid,
        remoteNames: await remote.list(),
        store: _repos.stores.sync,
      );
      return null;
    } catch (error) {
      return error.toString();
    } finally {
      remote.close();
    }
  }

  /// 彻底删除某本已删除书籍的云端备份（墓碑保留）。
  ///
  /// 返回错误文本（成功为 null）。用于回收站的「彻底删除」，失败时条目
  /// 仍可重试。
  Future<String?> purgeDeletedBookBackup(String bookUuid) async {
    if (bookUuid.isEmpty || !isConfigured) return null;
    final remote = _newRemote(_folder);
    try {
      await remote.ensureReady();
      await purgeRemoteBook(
        remote: remote,
        bookUuid: bookUuid,
        remoteNames: await remote.list(),
        store: _repos.stores.sync,
      );
      return null;
    } catch (error) {
      return error.toString();
    } finally {
      remote.close();
    }
  }

  /// 回收站「还原此书」：下载保留的最新一代快照，清墓碑并让书回到列表。
  ///
  /// 只处理仍然是墓碑的书；如果别处已经恢复（墓碑被清），拒绝覆盖活书。
  Future<String?> restoreDeletedBook(BackupUnitEntry entry) async {
    if (!entry.unit.isBook || !entry.isDeleted) {
      return '这个条目不是可还原的已删除书籍';
    }
    if (!isConfigured) return '尚未配置云备份';
    final uuid = entry.unit.refUuid;
    final row = await _repos.stores.library.book(uuid);
    if (row == null || !row.isDeleted) {
      return '这本书已经恢复，请刷新备份列表';
    }
    final error = await restoreSnapshot(
      entry.latest.name,
      label: entry.displayName,
    );
    if (error != null) return error;
    // 本地墓碑已清：把它从「已删除」挪回活书列表，不必再等一次云端列表。
    // 快照里的书名可能与本机目录副本不同，reviveBook 已回写目录，这里同步
    // 更新列表缓存，避免刚还原的面板还显示旧书名。
    _deletedBookMarks = {..._deletedBookMarks}..remove(uuid);
    final restored = await _repos.stores.library.book(uuid);
    if (restored != null && restored.title.trim().isNotEmpty) {
      _bookTitlesCache = {..._bookTitlesCache, uuid: restored.title};
    }
    _rebuildBackupCatalog();
    _dropUnresolvedConflict(entry.unit);
    // 清墓碑要随 library 推上去；手动档不主动同步，交给用户点「同步」。
    if (autoSyncEnabled) triggerSync(kind: SyncKind.data);
    notifyListeners();
    return null;
  }

  /// 回收站「彻底删除」：删掉云端最后一份备份，条目消失，墓碑保留。
  Future<String?> permanentlyDeleteDeletedBook(BackupUnitEntry entry) async {
    if (!entry.unit.isBook || !entry.isDeleted) {
      return '这个条目不是可删除的回收站书籍';
    }
    if (!isConfigured) return '尚未配置云备份';
    final uuid = entry.unit.refUuid;
    final row = await _repos.stores.library.book(uuid);
    if (row == null || !row.isDeleted) {
      return '这本书已经恢复，请刷新备份列表';
    }
    _opsBusy = true;
    notifyListeners();
    try {
      final error = await purgeDeletedBookBackup(uuid);
      if (error != null) return error;
      // 正常删除时本机已清过；这里兜底清一次旧版本留下的残留。
      try {
        await _repos.books.purgeBookData(uuid);
      } catch (_) {
        // 本机残留不影响云端删除结果。
      }
      _deletedBookMarks = {..._deletedBookMarks}..remove(uuid);
      _backups = [
        for (final file in _backups)
          if (unitOfSnapshot(file.name) != entry.unit) file,
      ];
      _rebuildBackupCatalog();
      _dropUnresolvedConflict(entry.unit);
      notifyListeners();
      return null;
    } finally {
      _opsBusy = false;
      notifyListeners();
    }
  }

  /// 移除某个单元未裁决的冲突（书被删/被还原后不再有意义）。
  void _dropUnresolvedConflict(BackupUnit unit) {
    final before = _unresolvedConflicts.length;
    _unresolvedConflicts = [
      for (final plan in _unresolvedConflicts)
        if (plan.unit != unit) plan,
    ];
    if (_unresolvedConflicts.length != before) notifyListeners();
  }

  // --- 内部工具 ---------------------------------------------------------------

  /// 整份替换本地库之后的一致性处理。
  ///
  /// - 书库快照：还原出一份文件后把书的身份恢复成「活的」（清墓碑 / 补目录行）；
  ///   否则删掉过的书还原回来也永远不显示；
  /// - library 快照：按新目录里的墓碑清掉本机残留。
  Future<void> _afterUnitReplaced(BackupUnit unit) async {
    switch (unit.kind) {
      case BackupUnitKind.book:
        await _repos.books.reviveBook(unit.refUuid);
      case BackupUnitKind.library:
        await _repos.books.purgeTombstonedBooks();
      case BackupUnitKind.mods:
        break;
    }
  }

  WebDavService _createDav() =>
      _davFactory?.call() ??
      WebDavService(
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
  /// [deletedBooks] 是「书 uuid → 删除信息」，用来验证回收站分组。
  void debugSetBackups(
    List<WebDavFile> backups, {
    Map<String, String> bookTitles = const {},
    Map<String, BackupDeletedBook> deletedBooks = const {},
  }) {
    _backups = List.of(backups);
    _bookTitlesCache = Map.of(bookTitles);
    _deletedBookMarks = Map.of(deletedBooks);
    _rebuildBackupCatalog();
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

  /// 直接改「存储文件夹」（测试用，验证云端目录分层）。
  ///
  /// 生产里这个值只能从本地配置读（[load]）或经 [save] 写；测试不想碰
  /// flutter_secure_storage / 真实配置目录，用这个钩子注入指定文件夹。
  void debugSetFolder(String value) {
    _folder = normalizeFolder(value);
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
