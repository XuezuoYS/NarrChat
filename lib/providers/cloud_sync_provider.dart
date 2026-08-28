import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../database/database_helper.dart';
import '../database/book_dao.dart';
import '../database/mod_dao.dart';
import '../database/sync_dao.dart';
import '../services/cloud_sync_service.dart';
import '../services/database_merge_service.dart';
import '../services/image_store.dart';
import '../services/local_config_service.dart';
import '../services/sync/sync_action_planner.dart';
import '../services/sync/sync_bootstrapper.dart';
import '../services/sync/sync_coordinator.dart';
import '../services/sync/sync_local_snapshot.dart';
import '../services/sync/sync_merge_planner.dart';
import '../services/sync/sync_models.dart';
import '../services/sync/database_sync_runner.dart';
import '../services/sync/image_sync_runner.dart';
import '../services/sync/remote_snapshot_applier.dart';
import '../services/sync/sync_remote_store.dart';
import '../services/sync/img_tombstones.dart';
import '../services/webdav_service.dart';
import '../screens/database_merge_screen.dart';
import '../widgets/sync_bootstrap_dialog.dart';
import '../widgets/sync_conflict_dialog.dart';

/// 云同步（WebDAV）设置与同步操作状态管理。
///
/// **两平面架构**（数据 / 图片，两条独立生命周期 + 统一触发接口）：
/// - [triggerSync]：统一触发入口（`SyncKind.both / data / images`）；
/// - [SyncCoordinator]：同设备单执行道串行派发 + 分平面排队合并 / 取消 /
///   状态与进度（两平面共享同一 WebDAV 目录与软锁，不并发打网络）；
/// - [DatabaseSyncRunner]：manifest / 快照 / 共基（唯一推进代数的平面）；
/// - [ImageSyncRunner]：`img/*` blob + `img_tombstones.json`（无代数）。
///
/// **自动触发白名单**（全自动模式下只有这些用户操作节点会发起备份，
/// 空闲 / 定时一律不打网络；详见 docs/sync_auto_triggers.md）：
/// 打开 APP（冷启动首帧）、回到前台（距上次同步 [resumeSyncThrottle] 内跳过）、
/// 进入书籍、打开书籍设置（拉取最新设置）、保存书籍设置 / 世界书、
/// 新轮次结束（成功 / 失败 / 中断）、Mod 设置保存、图片库删除（仅图片平面）、
/// 手动点击「同步」。新增触发点前请先确认它对应一次真实的用户操作。
///
/// 存储策略（符合 AGENTS.md 数据结构规范）：
/// - **密码**：写入 `flutter_secure_storage`（系统密钥库），禁止明文落盘；
/// - 其余设置（服务器地址、用户名、文件夹、保留版本数、自动上传、
///   同步模式、设备标识）：写入本地明文 JSON 配置文件
///   `local_config/app_settings.json`（[LocalConfigService]），不进入云存储。
///
/// 云端文件约定（新版同步规则）：
/// - `manifest.json`：数据平面增量索引（仅数据平面读写）；
/// - `narrchat_snapshot_g<gen>_<yyyyMMdd_HHmmss>.db`：数据库快照（版本备份）；
/// - `img/<hash>.<ext>`：图片 blob（仅图片平面读写）；
/// - `img_tombstones.json`：图片删除墓碑（仅图片平面读写）。
class CloudSyncProvider extends ChangeNotifier with WidgetsBindingObserver {
  CloudSyncProvider() {
    _coordinator = SyncCoordinator(
      runTask: _runPlaneTask,
      onChanged: notifyListeners,
      onResult: _onPlaneResult,
    );
  }


  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();

  static const String _keyPassword = 'webdav_password';

  /// 本地 JSON 配置文件中的键名（camelCase）。
  static const String _keyUrl = 'webdavUrl';
  static const String _keyUsername = 'webdavUsername';
  static const String _keyFolder = 'webdavFolder';
  static const String _keyKeepVersions = 'webdavKeepVersions';
  static const String _keyAutoUpload = 'webdavAutoUpload';
  static const String _keySyncMode = 'syncMode';
  static const String _keyDeviceId = 'syncDeviceId';

  static const String defaultFolder = 'narrchat';
  static const int defaultKeepVersions = 5;

  String _webdavUrl = '';
  String _webdavUsername = '';
  String _webdavPassword = '';
  String _folder = defaultFolder;
  int _keepVersions = defaultKeepVersions;
  bool _autoUpload = false;

  /// 同步模式：登录后默认全自动，可关闭为半自动（手动「同步」按钮）。
  SyncMode _syncMode = SyncMode.auto;

  /// 本设备标识（首连时自动生成，用于 manifest 的 knownDevices）。
  String _deviceId = '';

  /// 两平面统一协调层（触发 / 排队 / 分平面状态与进度）。
  late final SyncCoordinator _coordinator;

  /// 手动同步进行期间的数据平面最近结果（[sync] 的返回值来源）。
  bool _lastDataOk = false;

  /// 设置类操作（备份列表 / 测试连接 / 下载恢复）的执行中标记。
  bool _opsBusy = false;

  /// 分平面最近一次错误（面板状态徽章 / 错误框用；成功或重跑后清除）。
  String? _dataError;
  String? _imageError;

  String? _error;
  List<WebDavFile> _backups = [];
  bool _backupsLoaded = false;

  String get webdavUrl => _webdavUrl;
  String get webdavUsername => _webdavUsername;
  String get webdavPassword => _webdavPassword;
  String get folder => _folder;
  int get keepVersions => _keepVersions;
  bool get autoUpload => _autoUpload;

  /// 同步模式（auto=全自动 / manual=手动「同步」按钮）。
  SyncMode get syncMode => _syncMode;
  String get deviceId => _deviceId;

  // ---------------------------------------------------------------------------
  // 分平面状态（供 HUD / 状态章 / 设置面板）
  // ---------------------------------------------------------------------------

  /// 数据平面当前同步状态（供「数据同步」指示器）。
  SyncState get dataSyncState => _coordinator.stateOf(SyncPlane.data);

  /// 图片平面当前同步状态（供「图片同步」指示器）。
  SyncState get imageSyncState => _coordinator.stateOf(SyncPlane.images);

  /// 数据平面当前进度事件（无进行中的数据同步时为 null）。
  SyncProgressEvent? get dataProgress => _coordinator.progressOf(SyncPlane.data);

  /// 图片平面当前进度事件（无进行中的图片同步时为 null）。
  SyncProgressEvent? get imageProgress =>
      _coordinator.progressOf(SyncPlane.images);

  /// 数据平面最近一次错误（null = 无未决错误）。
  String? get dataError => _dataError;

  /// 图片平面最近一次错误（null = 无未决错误）。
  String? get imageError => _imageError;

  /// 首次连接分支决策（首次连接弹窗的选择结果）。
  SyncBootstrapDecision? get bootstrapDecision => _bootstrapDecision;

  /// 应用级 Navigator key：供同步流程在无 UI Context 时弹出首连分支 / 冲突对话框。
  ///
  /// 默认持有独立 key；main.dart 会把它绑定到与应用相同的 navigator，
  /// 使同步流程能复用现有路由（通知跳转与同步对话框共用同一 Navigator）。
  static GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  /// 结果提示队列上限：数据 / 图片两平面依次结束最多各一条，超出时挤掉
  /// 最早的临时提示（全是驻留错误时才丢弃最早一条）。
  static const int maxResultToasts = 3;

  final List<SyncResultToast> _resultToasts = [];
  int _nextToastId = 0;

  /// 云同步结果提示（应用级悬浮气泡 [SyncResultBubble] 的数据源；
  /// 成功 / 取消类悬浮约 2 秒后自动消失，失败类驻留等待用户关闭）。
  List<SyncResultToast> get resultToasts => List.unmodifiable(_resultToasts);

  /// 展示一条云同步结果提示（由 [SyncResultBubble] 跨页面渲染）。
  ///
  /// - [kind]：成功 / 取消等（短暂悬浮后自动消失）；错误（驻留 + 关闭按钮）；
  /// - 内容以可选中的 [SelectableText] 呈现（用户可长按选择复制，含报错详情）；
  /// - 相同文案去重（连续同步结果相同时不叠加）。
  void showSyncResult(
    String message, {
    SyncToastKind kind = SyncToastKind.success,
  }) {
    if (_resultToasts.any((t) => t.message == message)) return;
    _resultToasts.add(
      SyncResultToast(id: _nextToastId++, message: message, kind: kind),
    );
    if (_resultToasts.length > maxResultToasts) {
      // 优先挤掉已自动消失的临时提示；全是驻留错误时丢弃最早一条。
      final oldestTransient =
          _resultToasts.indexWhere((t) => !t.persistent);
      _resultToasts.removeAt(oldestTransient >= 0 ? oldestTransient : 0);
    }
    notifyListeners();
  }

  /// 关闭一条结果提示（气泡「关闭」按钮 / 成功类到点自动移除的回调）。
  void dismissSyncResult(int id) {
    final before = _resultToasts.length;
    _resultToasts.removeWhere((t) => t.id == id);
    if (_resultToasts.length != before) notifyListeners();
  }

  /// 请求取消指定平面的同步（HUD 分平面取消按钮回调）。
  ///
  /// 运行中 → 协作式停止（Runner 在阶段间 / 逐文件检查）；待跑 → 撤销排队。
  /// 另一平面不受影响（两平面取消语义独立）。
  void cancelSync(SyncPlane plane) => _coordinator.cancel(plane);

  /// 接入应用生命周期：只注册观察者，让「回到前台」按 [resumeSyncThrottle]
  /// 节流后触发一次静默同步（视作"打开 APP"节点的延续）。
  ///
  /// **不做任何定时轮询**：自动同步只由用户操作节点发起（见类注释的触发白名单），
  /// 空闲停留首页时不再周期性打网络。
  void attachLifecycle() {
    WidgetsBinding.instance.addObserver(this);
  }

  /// 解除生命周期监听（测试 / 应用退出时调用）。
  void detachLifecycle() {
    WidgetsBinding.instance.removeObserver(this);
  }

  /// 回前台（resumed）触发的节流窗口：距上一次同步请求不足该时长时跳过。
  ///
  /// 窗口内说明刚刚已经同步过（冷启动 / 进书 / 轮次落库 / 手动等任一节点），
  /// 再拉一次只是重复打网络。resumed 在实际使用中非常密集（见 dart:ui
  /// [AppLifecycleState]：resumed = 可见且持有输入焦点）：Android 每次切回应用、
  /// Windows 每次窗口重新获得焦点（alt-tab 回来 / 点回窗口 / 从最小化恢复）、
  /// 文件选择等系统弹窗关闭返回，都会命中一次，故必须节流。
  static const Duration resumeSyncThrottle = Duration(minutes: 2);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    final last = _lastSyncRequestAt;
    if (last != null && _now().difference(last) < resumeSyncThrottle) return;
    triggerSync(silent: true);
  }

  /// 最近一次同步请求的时刻（自动触发 / 手动「同步」均计入；null = 本次运行内没有过）。
  DateTime? get lastSyncRequestAt => _lastSyncRequestAt;
  DateTime? _lastSyncRequestAt;

  /// 时刻源（测试可经 [debugSetNow] 注入固定时钟）。
  DateTime Function() _now = DateTime.now;

  // ---------------------------------------------------------------------------
  // 统一触发接口
  // ---------------------------------------------------------------------------

  /// 全自动同步统一触发入口（**仅**规定的用户操作节点调用，见类注释白名单）。
  ///
  /// 每次真正发起请求都会记录 [lastSyncRequestAt]，作为回前台节流的基准。
  ///
  /// - 未配置 WebDAV 或当前为手动模式：忽略；
  /// - [kind]：`both`（默认，数据 + 图片补跑）/ `data` / `images`；
  /// - 空闲：立即派发对应平面任务（同执行道串行，数据优先）；
  /// - 执行中：置对应平面待跑位（多个触发点合并为一次补跑，同步本身幂等，
  ///   见 docs/sync_auto_triggers.md）。
  /// - [silent] 为 true（回前台 / 打开书籍设置等被动触发）时，
  ///   成功类结果不弹提示（失败仍提示）。
  void triggerSync({SyncKind kind = SyncKind.both, bool silent = false}) {
    if (!isConfigured || _syncMode != SyncMode.auto) return;
    _lastSyncRequestAt = _now();
    if (kind != SyncKind.images) _coordinator.trigger(SyncPlane.data, silent: silent);
    if (kind != SyncKind.data) {
      _coordinator.trigger(SyncPlane.images, silent: silent);
    }
  }

  // ---------------------------------------------------------------------------
  // 测试钩子
  // ---------------------------------------------------------------------------

  /// 测试用：指定平面是否有排队待跑的触发。
  @visibleForTesting
  bool debugPendingSyncRequested(SyncPlane plane) =>
      _coordinator.pendingOf(plane);

  /// 测试用：读取指定平面的取消请求标记（HUD 取消按钮断言用）。
  @visibleForTesting
  bool debugCancelRequested(SyncPlane plane) =>
      _coordinator.debugCancelRequested(plane);

  /// 测试用：直接改写指定平面同步状态（避免依赖真实网络路径）。
  @visibleForTesting
  void debugSetSyncState(SyncPlane plane, SyncState state) =>
      _coordinator.debugSetState(plane, state);

  /// 测试用：直接改写指定平面同步进度事件。
  @visibleForTesting
  void debugSetProgress(SyncPlane plane, SyncProgressEvent? event) =>
      _coordinator.debugSetProgress(plane, event);

  /// 测试用：强制占用执行道（验证排队逻辑，避免触发真实网络）。
  @visibleForTesting
  void debugSetLaneBusy(bool value) => _coordinator.debugSetLaneBusy(value);

  /// 测试用：直接改写数据平面错误（验证分平面错误显示）。
  @visibleForTesting
  void debugSetPlaneErrors({String? data, String? images}) {
    _dataError = data;
    _imageError = images;
    notifyListeners();
  }

  /// 测试用：直接写入云端备份列表（与 [_loadBackups] 相同过滤 + 排序语义）。
  @visibleForTesting
  void debugSetBackups(List<WebDavFile> backups) {
    _backups = backups
        .where((f) => WebDavSyncStore.isSnapshot(f.name))
        .toList()
      ..sort(compareSnapshots);
    _backupsLoaded = true;
    notifyListeners();
  }

  /// 测试用：直接标志为"已配置"（填写非空 URL/用户名），避免触碰平台存储。
  @visibleForTesting
  void debugSetConfigured({bool value = true}) {
    if (value) {
      _webdavUrl = 'https://dav.example.com/dav/';
      _webdavUsername = 'user';
    } else {
      _webdavUrl = '';
      _webdavUsername = '';
    }
    notifyListeners();
  }

  /// 测试用：注入固定时钟（传 null 恢复 [DateTime.now]），
  /// 用于验证回前台节流窗口而不必等待真实时间流逝。
  @visibleForTesting
  void debugSetNow(DateTime Function()? now) {
    _now = now ?? DateTime.now;
  }

  /// 测试用：清空「最近一次同步请求」时刻（模拟本次运行从未同步过）。
  @visibleForTesting
  void debugClearSyncRequestAt() {
    _lastSyncRequestAt = null;
  }

  /// 测试用：直接改写同步模式（避免触碰本地配置文件）。
  @visibleForTesting
  void debugSetSyncMode(SyncMode mode) {
    _syncMode = mode;
    _autoUpload = mode == SyncMode.auto;
    notifyListeners();
  }

  bool get isBusy => _opsBusy || _coordinator.isRunning;
  String? get error => _error ?? _dataError ?? _imageError;

  /// 云端备份列表（快照，按代际新 → 旧）。
  List<WebDavFile> get backups => List.unmodifiable(_backups);
  bool get backupsLoaded => _backupsLoaded;

  /// WebDAV 配置是否已就绪（地址与登录用户名均非空）。
  bool get isConfigured =>
      _webdavUrl.trim().isNotEmpty && _webdavUsername.trim().isNotEmpty;

  /// 数据恢复（下载替换/合并）完成后的刷新回调，
  /// 由 main.dart 注册：重载书籍 / Mod / 轮次 / 世界书等本地状态。
  Future<void> Function()? onDataRestored;

  /// 从安全存储与本地 JSON 配置文件中加载设置。
  Future<void> load() async {
    try {
      final password = await _secureStorage.read(key: _keyPassword);
      _webdavPassword = password ?? '';
      final cfg = await LocalConfigService.read();
      _webdavUrl = (cfg[_keyUrl] as String?) ?? '';
      _webdavUsername = (cfg[_keyUsername] as String?) ?? '';
      _folder = (cfg[_keyFolder] as String?) ?? defaultFolder;
      _keepVersions =
          (cfg[_keyKeepVersions] as num?)?.toInt() ?? defaultKeepVersions;
      _autoUpload = (cfg[_keyAutoUpload] as bool?) ?? false;
      _syncMode = _parseSyncMode(cfg[_keySyncMode]);
      _deviceId = (cfg[_keyDeviceId] as String?) ?? '';
      if (_deviceId.isEmpty) {
        _deviceId = _generateDeviceId();
        await LocalConfigService.update({_keyDeviceId: _deviceId});
      }
    } catch (e) {
      _error = e.toString();
    }
    notifyListeners();
  }

  /// 保存设置。密码写入安全存储，其余写入本地 JSON 配置文件。
  ///
  /// 云同步是否"已登录"由 [webdavUrl]/[webdavUsername] 是否填写决定。
  Future<bool> save({
    required String webdavUrl,
    required String webdavUsername,
    required String webdavPassword,
    required String folder,
    required int keepVersions,
    required SyncMode syncMode,
  }) async {
    try {
      final trimmedUrl = webdavUrl.trim();
      final trimmedUsername = webdavUsername.trim();
      final trimmedFolder = folder.trim();

      if (trimmedUrl.isEmpty || trimmedUsername.isEmpty) {
        _error = '服务器地址与用户名不能为空';
        notifyListeners();
        return false;
      }
      if (trimmedFolder.isEmpty) {
        _error = '存储文件夹不能为空';
        notifyListeners();
        return false;
      }
      if (keepVersions < 1 || keepVersions > 99) {
        _error = '保留历史版本数需在 1 ~ 99 之间';
        notifyListeners();
        return false;
      }
      if (webdavPassword.isNotEmpty) {
        await _secureStorage.write(key: _keyPassword, value: webdavPassword);
      }
      if (_deviceId.isEmpty) {
        _deviceId = _generateDeviceId();
      }
      await LocalConfigService.update({
        _keyUrl: trimmedUrl,
        _keyUsername: trimmedUsername,
        _keyFolder: trimmedFolder,
        _keyKeepVersions: keepVersions,
        _keyAutoUpload: syncMode == SyncMode.auto,
        _keySyncMode: syncMode.name,
        _keyDeviceId: _deviceId,
      });

      _webdavUrl = trimmedUrl;
      _webdavUsername = trimmedUsername;
      _webdavPassword = webdavPassword;
      _folder = trimmedFolder;
      _keepVersions = keepVersions;
      _syncMode = syncMode;
      _autoUpload = syncMode == SyncMode.auto;
      _error = null;
      notifyListeners();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  /// 切换同步模式（auto/manual）并持久化。
  Future<bool> setSyncMode(SyncMode mode) async {
    _syncMode = mode;
    _autoUpload = mode == SyncMode.auto;
    notifyListeners();
    try {
      await LocalConfigService.update({
        _keySyncMode: mode.name,
        _keyAutoUpload: mode == SyncMode.auto,
      });
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  static SyncMode _parseSyncMode(Object? raw) {
    if (raw is String) {
      return SyncMode.values.firstWhere(
        (m) => m.name == raw,
        orElse: () => SyncMode.auto,
      );
    }
    if (raw is bool) return raw ? SyncMode.auto : SyncMode.manual;
    return SyncMode.auto;
  }

  /// 生成一个本地设备标识（无额外依赖：时间戳 + 随机十六进制）。
  static String _generateDeviceId() {
    final now = DateTime.now().millisecondsSinceEpoch.toRadixString(16);
    final random = List<int>.generate(8, (_) => _rand.nextInt(256));
    final rnd = random.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '$now-$rnd';
  }

  static final _rand = math.Random();

  /// 删除当前 WebDAV 连接：清除安全存储中的密码与本地 JSON 中的连接配置，
  /// 恢复到未配置状态（不影响云端备份与本地数据）。
  Future<void> disconnect() async {
    try {
      await _secureStorage.delete(key: _keyPassword);
      final cfg = await LocalConfigService.read();
      cfg
        ..remove(_keyUrl)
        ..remove(_keyUsername)
        ..remove(_keyFolder)
        ..remove(_keyKeepVersions)
        ..remove(_keyAutoUpload)
        ..remove(_keySyncMode);
      await LocalConfigService.write(cfg);
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return;
    }
    _webdavUrl = '';
    _webdavUsername = '';
    _webdavPassword = '';
    _folder = defaultFolder;
    _keepVersions = defaultKeepVersions;
    _autoUpload = false;
    _syncMode = SyncMode.auto;
    _backups = [];
    _backupsLoaded = false;
    _error = null;
    _dataError = null;
    _imageError = null;
    notifyListeners();
  }

  WebDavService _buildDav() {
    final url = _webdavUrl.trim();
    if (url.isEmpty) {
      throw StateError('请先填写 WebDAV 服务器地址');
    }
    return WebDavService(
      baseUrl: url,
      username: _webdavUsername.trim(),
      password: _webdavPassword,
    );
  }

  // ---------------------------------------------------------------------------
  // 统一入口：手动「同步」
  // ---------------------------------------------------------------------------

  /// 手动「同步」：同时派发数据 + 图片两个平面（经协调层单执行道串行，
  /// 数据先、图片后），等待整条执行道空闲后返回。
  ///
  /// 返回 true 表示**数据平面**本轮完成（含「已是最新版本」与「冲突已引导
  /// 处理」）；false 表示失败 / 用户取消 / 冲突待处理 / 执行道忙排队。
  /// 图片平面的结果独立提示，不影响返回值语义。
  Future<bool> sync() async {
    if (isBusy) {
      // 执行中：并入两平面待跑（与 [triggerSync] 语义一致；手动触发非静默）。
      _coordinator.trigger(SyncPlane.data);
      _coordinator.trigger(SyncPlane.images);
      return false;
    }
    _lastDataOk = false;
    _error = null;
    // 手动点击同样计入"最近一次同步请求"，避免紧接着的回前台再拉一次。
    _lastSyncRequestAt = _now();
    _coordinator.trigger(SyncPlane.data);
    _coordinator.trigger(SyncPlane.images);
    await _coordinator.onIdle;
    return _lastDataOk;
  }

  /// 首次连接分支决策（首次连接弹窗的选择结果；否则为 null）。
  SyncBootstrapDecision? _bootstrapDecision;

  /// 协调层回调：按平面派发具体任务。
  Future<SyncTaskOutcome> _runPlaneTask(SyncTaskContext ctx) {
    return switch (ctx.plane) {
      SyncPlane.data => _runDataPlane(ctx),
      SyncPlane.images => _runImagePlane(ctx),
    };
  }

  /// 协调层回调：分平面结果 → 应用级悬浮气泡提示 + 分平面错误记录。
  void _onPlaneResult(
    SyncPlane plane,
    SyncTaskOutcome outcome,
    bool silent,
  ) {
    if (plane == SyncPlane.data) {
      _lastDataOk = outcome.state == SyncState.success;
      _dataError = outcome.state == SyncState.error ? outcome.message : null;
    } else {
      _imageError = outcome.state == SyncState.error ? outcome.message : null;
    }
    // 静默模式（回前台 / 打开书籍设置等被动触发）只保留失败类提示，
    // 避免"已是最新版本"类消息刷屏；两平面各自独立提示。
    if (outcome.message != null && (!silent || outcome.persistent)) {
      showSyncResult(
        outcome.message!,
        kind: outcome.persistent
            ? SyncToastKind.error
            : outcome.state == SyncState.idle
                ? SyncToastKind.info
                : SyncToastKind.success,
      );
    }
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // 数据平面任务：首连分支 → merge/pull/push →（冲突引导）→ 备份列表刷新
  // ---------------------------------------------------------------------------
  Future<SyncTaskOutcome> _runDataPlane(SyncTaskContext ctx) async {
    _dataError = null;
    WebDavService? dav;
    try {
      dav = _buildDav();
      final davStore = WebDavSyncStore(dav: dav, folder: _folder.trim());
      await davStore.ensureFolder();
      final preflight = await _handleFirstConnect(davStore, ctx);
      switch (preflight.outcome) {
        case _FirstConnectOutcome.aborted:
          return const SyncTaskOutcome(
            SyncState.idle,
            message: '已取消数据同步',
          );
        case _FirstConnectOutcome.completed:
          final gen = preflight.generation;
          await _loadBackups(dav);
          return SyncTaskOutcome(
            SyncState.success,
            message: gen == null
                ? '已导入云端数据'
                : '已导入云端数据（第 $gen 代）',
            generation: gen,
          );
        case _FirstConnectOutcome.continueSync:
          break;
      }

      final runner = _buildDatabaseRunner(davStore, ctx);
      final result = await runner.sync();
      if (ctx.isCancelled()) {
        return const SyncTaskOutcome(SyncState.idle, message: '已取消数据同步');
      }
      if (result.error != null) {
        // 「已取消」＝用户通过 HUD 主动取消，非失败。
        final cancelled = result.error == '已取消';
        return cancelled
            ? const SyncTaskOutcome(
                SyncState.idle,
                message: '已取消数据同步',
              )
            : SyncTaskOutcome(
                SyncState.error,
                message: '数据同步失败：${result.error}',
                persistent: true,
              );
      }
      if (result.hasConflict) {
        final handled = await _handleConflict(davStore, ctx);
        if (handled.ok) {
          // 已进入冲突解决页，无需再提示；合并落定后经补同步推送。
          await _loadBackups(dav);
          return const SyncTaskOutcome(SyncState.success);
        }
        if (handled.error != null) {
          return SyncTaskOutcome(
            SyncState.error,
            message: '数据同步失败：${handled.error}',
            persistent: true,
          );
        }
        return SyncTaskOutcome(SyncState.idle, message: handled.message);
      }
      // 「无变更（已是最新）」「仅拉取落地」「有变更并已推送」都视为成功。
      // 有落地变更（拉取 / 删除传播）时刷新内存态数据：
      // 否则另一台设备同步后 UI 仍显示缓存的旧轮次 / 旧书籍列表。
      if (result.applied) await onDataRestored?.call();
      final gen = result.generation;
      final suffix = gen == null ? '' : '（第 $gen 代）';
      final message = result.pushed
          ? '数据已同步到云端$suffix'
          : result.applied
          ? '已拉取最新数据$suffix'
          : '数据已是最新版本$suffix';
      // 刷新备份列表（展示最新一代快照）。
      await _loadBackups(dav);
      return SyncTaskOutcome(SyncState.success, message: message, generation: gen);
    } catch (e) {
      return SyncTaskOutcome(
        SyncState.error,
        message: '数据同步失败：$e',
        persistent: true,
      );
    } finally {
      dav?.close();
    }
  }

  // ---------------------------------------------------------------------------
  // 图片平面任务：墓碑合并 → blob 收敛（无代数、不碰 manifest）
  // ---------------------------------------------------------------------------
  Future<SyncTaskOutcome> _runImagePlane(SyncTaskContext ctx) async {
    _imageError = null;
    WebDavService? dav;
    try {
      dav = _buildDav();
      final davStore = WebDavSyncStore(dav: dav, folder: _folder.trim());
      await davStore.ensureFolder();
      final runner = ImageSyncRunner(
        store: davStore,
        deviceId: _deviceId,
        localImages: _localImagePaths,
        readLocalImage: _readLocalImage,
        writeLocalImage: _writeLocalImage,
        deleteLocalImage: _deleteLocalImage,
        tombstoneStore: FileTombstoneStore(),
        onProgress: ctx.reportProgress,
        isCancelled: ctx.isCancelled,
      );
      final result = await runner.sync();
      if (result.error == '已取消') {
        return const SyncTaskOutcome(SyncState.idle, message: '已取消图片同步');
      }
      if (result.error != null) {
        return SyncTaskOutcome(
          SyncState.error,
          message: '图片同步失败：${result.error}',
          persistent: true,
        );
      }
      // 无 blob 变更时不提示（静默收敛：仅墓碑维护）；有变更给出计数摘要。
      final parts = <String>[
        if (result.uploaded > 0) '上传 ${result.uploaded}',
        if (result.pulled > 0) '下载 ${result.pulled}',
        if (result.deleted > 0) '删除 ${result.deleted}',
      ];
      return SyncTaskOutcome(
        SyncState.success,
        message: result.applied
            ? '图片同步完成（${parts.join(' · ')}）'
            : null,
      );
    } catch (e) {
      return SyncTaskOutcome(
        SyncState.error,
        message: '图片同步失败：$e',
        persistent: true,
      );
    } finally {
      dav?.close();
    }
  }

  // ---------------------------------------------------------------------------
  // 首次连接分支
  // ---------------------------------------------------------------------------

  /// 首次连接分支处理：
  /// - 无需弹窗（老用户 / 仅一端有数据）：直接走常规同步；
  /// - 弹窗后按用户选择落地：`pullCloud` 用云端覆盖本地并完成，
  ///   `initCloud` 把云端设为共基后走常规同步（推送本地），
  ///   `mergeBoth` 走常规同步（真冲突进入冲突处理）。
  Future<_FirstConnectResult> _handleFirstConnect(
    WebDavSyncStore davStore,
    SyncTaskContext ctx,
  ) async {
    final decision = await _computeFirstConnectDecision(davStore);
    if (decision == null) {
      return const _FirstConnectResult(_FirstConnectOutcome.continueSync);
    }
    final summary = SyncBootstrapSummary(
      localBooks: await _localCount('books'),
      localMods: await _localCount('mods'),
      cloudBooks:
          decision == SyncBootstrapDecision.mergeBoth
              ? await _cloudBookCount(davStore)
              : 0,
      cloudMods:
          decision == SyncBootstrapDecision.mergeBoth
              ? await _cloudModCount(davStore)
              : 0,
    );
    final navCtx = navigatorKey.currentState?.context;
    if (navCtx == null) {
      // 无可渲染的 Navigator（如纯后台自动同步）时记录并跳过，走常规同步；
      // 常规同步检出冲突后走冲突处理（同样会因无 Navigator 而记录错误）。
      _bootstrapDecision = decision;
      return const _FirstConnectResult(_FirstConnectOutcome.continueSync);
    }
    // navCtx 取自应用级 Navigator（常驻），非会话内会失效的局部 context，忽略该告警。
    // ignore: use_build_context_synchronously
    final chosen = await showSyncBootstrapDialog(navCtx, summary: summary);
    if (chosen == null) {
      return const _FirstConnectResult(_FirstConnectOutcome.aborted);
    }
    _bootstrapDecision = chosen;
    if (chosen == SyncBootstrapDecision.pullCloud) {
      final gen = await _applyCloudOverLocal(davStore, ctx);
      return _FirstConnectResult(
        _FirstConnectOutcome.completed,
        generation: gen,
      );
    }
    if (chosen == SyncBootstrapDecision.initCloud) {
      // 本地覆盖云端：先让远端内容成为共基，常规同步即会以 localOnly 推送本地。
      await _adoptRemoteAsBase(davStore);
    }
    return const _FirstConnectResult(_FirstConnectOutcome.continueSync);
  }

  /// 计算首次连接分支：仅"从未同步且两端都有数据"返回 `mergeBoth` 暗示需弹窗，
  /// 否则返回 null（无需弹窗）。
  Future<SyncBootstrapDecision?> _computeFirstConnectDecision(
    WebDavSyncStore davStore,
  ) async {
    final state = await SyncStateDao().getState();
    if (state.lastGeneration > 0) return null;
    final localHasData =
        (await _localCount('books')) > 0 || (await _localCount('mods')) > 0;
    final cloudHasData = await davStore.readManifest() != null;
    if (!localHasData || !cloudHasData) return null;
    return SyncBootstrapper.decide(
      localHasData: true,
      cloudHasData: true,
    );
  }

  /// 「用云端覆盖本地」：下载当前代快照整体替换本地，并把云端内容设为共基
  ///（替换后本地与云端一致，下次同步为「无变更」）。
  ///
  /// 返回落地的云端代际（无快照可下载时返回 null）。
  Future<int?> _applyCloudOverLocal(
    WebDavSyncStore davStore,
    SyncTaskContext ctx,
  ) async {
    final manifest = await davStore.readManifest();
    final name = await davStore.latestSnapshotName(
      generation: manifest?.generation,
    );
    if (name == null) return null;
    final bytes = await davStore.readSnapshot(name);
    if (bytes == null) return null;
    ctx.reportProgress(
      const SyncProgressEvent(
        phase: SyncPhase.pullSnapshot,
        label: '下载云端快照…',
      ),
    );
    final tempPath = await CloudSyncService.saveSnapshotToTemp(name, bytes);
    try {
      await CloudSyncService.applyReplace(tempPath);
      // 用云端内容修正本地共基，避免下次同步把远端当作变化拉回。
      await _adoptRemoteAsBase(davStore);
      await onDataRestored?.call();
      return manifest?.generation;
    } finally {
      _cleanupTemp(tempPath);
    }
  }

  /// 把**当前云端 manifest** 的内容写成本地同步共基（`sync_book_base` /
  /// `sync_mod_base` / `sync_state.lastGeneration`）。
  ///
  /// 用于「本地覆盖云端 / 恢复备份 / 合并决策落定」之后：本地从此被视为
  /// 相对远端的新版本，下一次同步会以 localOnly 推送本地（云端回滚到本地状态）。
  /// uuid 缺失（旧版清单）时以 `legacy:<title/name>` 键写入，合并层按名称回退匹配。
  Future<void> _adoptRemoteAsBase(WebDavSyncStore davStore) async {
    final manifest = await davStore.readManifest();
    if (manifest == null) return;
    final dao = SyncStateDao();
    for (final b in manifest.books) {
      await dao.putBookBase(
        SyncBookBase(
          uuid: b.uuid.isNotEmpty ? b.uuid : 'legacy:${b.title}',
          title: b.title,
          settingsFp: b.settingsFp,
          roundsFp: b.roundsFp,
          worldbookFp: b.worldBookFp,
          bookmodsFp: b.bookModsFp,
          settingsUpdatedAt: b.settingsUpdatedAt,
          roundsUpdatedAt: b.roundsUpdatedAt,
        ),
      );
    }
    for (final m in manifest.mods) {
      await dao.putModBase(
        SyncModBase(
          uuid: m.uuid.isNotEmpty ? m.uuid : 'legacy:${m.name}',
          name: m.name,
          fingerprint: m.fingerprint,
          updatedAt: m.updatedAt,
        ),
      );
    }
    final state = await dao.getState();
    await dao.saveState(
      SyncStateRecord(
        deviceId: state.deviceId.isEmpty ? _deviceId : state.deviceId,
        lastSyncedAt: DateTime.now().millisecondsSinceEpoch,
        lastGeneration: manifest.generation,
      ),
    );
  }

  /// 恢复 / 合并落定后：把云端内容设为共基，并触发一次自动同步推送本地结果。
  ///
  /// 失败（如离线）不阻塞恢复结果本身；自动同步由 [triggerSync] 门控。
  Future<void> _rebaseAndQueuedSync() async {
    WebDavService? dav;
    try {
      dav = _buildDav();
      await _adoptRemoteAsBase(
        WebDavSyncStore(dav: dav, folder: _folder.trim()),
      );
    } catch (e) {
      _error = e.toString();
    } finally {
      dav?.close();
    }
    triggerSync();
  }

  // ---------------------------------------------------------------------------
  // 冲突处理（数据平面）
  // ---------------------------------------------------------------------------

  /// 同步检出冲突后的引导对话框：
  /// - 取消同步：中止本次同步（数据平面）并把同步模式改为手动；
  /// - 解决冲突：下载当前代快照，进入合并决策页逐本确认。
  Future<_ConflictResult> _handleConflict(
    WebDavSyncStore davStore,
    SyncTaskContext ctx,
  ) async {
    final navCtx = navigatorKey.currentState?.context;
    if (navCtx == null) {
      return const _ConflictResult(
        ok: false,
        error: '检测到同步冲突，请打开「设置 → 云同步」处理。',
      );
    }
    // 更新数据平面指示器：检出冲突 → 等待用户选择，而不是停留在上一步描述。
    ctx.reportProgress(
      const SyncProgressEvent(
        phase: SyncPhase.merge,
        label: '检测到同步冲突，等待处理…',
      ),
    );
    // navCtx 取自应用级 Navigator（常驻），忽略该告警。
    // ignore: use_build_context_synchronously
    final action = await showSyncConflictDialog(navCtx);
    if (action == SyncConflictAction.cancelSync) {
      await setSyncMode(SyncMode.manual);
      return const _ConflictResult(
        ok: false,
        message: '已取消数据同步，同步模式已切换为手动。需要时请点击「同步」按钮。',
      );
    }
    final resolved = await _openConflictResolver(davStore, ctx);
    if (!resolved) {
      return const _ConflictResult(
        ok: false,
        error: '冲突解决失败：无法下载/解析远端快照，请稍后重试或改用「云端备份」列表处理。',
      );
    }
    // 已引导进入合并决策页；合并落定后由 applyMergePlan 触发补同步推送结果。
    return const _ConflictResult(ok: true);
  }

  /// 打开冲突解决页：下载当前代快照 → 构建合并计划 → 进入 [DatabaseMergeScreen]。
  Future<bool> _openConflictResolver(
    WebDavSyncStore davStore,
    SyncTaskContext ctx,
  ) async {
    final navCtx = navigatorKey.currentState?.context;
    if (navCtx == null) return false;
    // 更新指示器文案：走下一步（下载快照），避免停留在上一步描述。
    ctx.reportProgress(
      const SyncProgressEvent(
        phase: SyncPhase.pullSnapshot,
        label: '下载远端快照…',
      ),
    );
    final manifest = await davStore.readManifest();
    final name = await davStore.latestSnapshotName(
      generation: manifest?.generation,
    );
    if (name == null) return false;
    final bytes = await davStore.readSnapshot(name);
    if (bytes == null) return false;
    final tempPath = await CloudSyncService.saveSnapshotToTemp(name, bytes);
    final DatabaseMergePlan plan;
    try {
      plan = await DatabaseMergeService.buildPlanFromBackup(tempPath);
    } catch (e) {
      _cleanupTemp(tempPath);
      return false;
    }
    _cleanupTemp(tempPath);
    // 进入合并决策页：提示"等待处理"，同步本身挂起等合并落定后的补同步。
    ctx.reportProgress(
      const SyncProgressEvent(
        phase: SyncPhase.merge,
        label: '检测到冲突，请在合并页选择处理方式…',
      ),
    );
    // 合并页弹在应用级 Navigator 上；onApply 由 applyMergePlan 落地并补同步。
    await DatabaseMergeScreen.open(
      // ignore: use_build_context_synchronously
      navCtx,
      plan: plan,
      onApply: (p, bd, md) => applyMergePlan(p, bd, md),
    );
    return true;
  }

  // ---------------------------------------------------------------------------
  // 同步执行器构建
  // ---------------------------------------------------------------------------

  Future<int> _localCount(String table) async {
    final db = await DatabaseHelper.instance.database;
    final rows = await db.rawQuery('SELECT COUNT(*) AS c FROM $table');
    return ((rows.first['c'] as int?) ?? 0);
  }

  Future<int> _cloudBookCount(WebDavSyncStore davStore) async =>
      (await davStore.readManifest())?.books.length ?? 0;

  Future<int> _cloudModCount(WebDavSyncStore davStore) async =>
      (await davStore.readManifest())?.mods.length ?? 0;

  /// 构建驱动**数据平面**同步的 [DatabaseSyncRunner]（真实 WebDAV + 本地库）。
  ///
  /// 只注入数据平面依赖（快照构建 / 引用集 / 落地回调）；图片依赖
  ///（本地盘读写 / 墓碑文件）只归 [ImageSyncRunner]，两平面互不共享。
  DatabaseSyncRunner _buildDatabaseRunner(
    WebDavSyncStore store,
    SyncTaskContext ctx,
  ) {
    return DatabaseSyncRunner(
      store: store,
      stateStore: SyncStateDao(),
      deviceId: _deviceId,
      buildLocalSnapshot: () async =>
          SyncLocalSnapshot.build(await DatabaseHelper.instance.database),
      buildSnapshotBytes: CloudSyncService.buildSnapshotBytes,
      referencedImages: _referencedImages,
      keepVersions: _keepVersions,
      onProgress: ctx.reportProgress,
      isCancelled: ctx.isCancelled,
      applyRemotePlan: _applyRemotePlan,
      applyRemoteBooks: _applyRemoteBooks,
    );
  }

  /// 把远端快照里的变更按部件级决策落地到本地库
  ///（远端独有书整本复制；同名书按 remoteOnly 部件就地合并）。
  Future<void> _applyRemoteBooks(
    SyncMergePlan mergePlan,
    SyncAction action,
    Uint8List snapshotBytes,
  ) => const RemoteSnapshotApplier().apply(
    mergePlan: mergePlan,
    action: action,
    snapshotBytes: snapshotBytes,
  );

  /// 把远端拉取 / 删除传播的 [SyncAction] 落地到本地库。
  ///
  /// - 远端已删除的书 → 本地软删（UI 立即隐藏、行暂留用于同步）；
  /// - 远端已删除的 Mod → 本地软删 + 清理书籍引用 + 删除共基行。
  Future<void> _applyRemotePlan(SyncAction action) async {
    if (action.deleteLocalBookUuids.isEmpty &&
        action.deleteLocalModUuids.isEmpty) {
      return;
    }
    final bookDao = BookDao();
    if (action.deleteLocalBookUuids.isNotEmpty) {
      final books = await bookDao.getAllBooks();
      for (final uuid in action.deleteLocalBookUuids) {
        for (final b in books) {
          if (b.id != null && _matchesRef(b.uuid, b.title, uuid)) {
            await bookDao.softDeleteBook(b.id!);
          }
        }
      }
    }
    if (action.deleteLocalModUuids.isNotEmpty) {
      final modDao = ModDao();
      final syncDao = SyncStateDao();
      final mods = await modDao.getAllMods();
      for (final uuid in action.deleteLocalModUuids) {
        for (final m in mods) {
          if (m.id != null && _matchesRef(m.uuid, m.name, uuid)) {
            await modDao.deleteMod(m.id!);
            if (m.uuid.isNotEmpty) {
              await syncDao.deleteModBase(m.uuid);
            }
          }
        }
      }
    }
  }

  /// uuid 精确匹配，或 legacy 键（`legacy:<名称>`）回退到名称匹配。
  static bool _matchesRef(String uuid, String name, String refUuid) {
    if (refUuid.startsWith('legacy:')) {
      return name == refUuid.substring('legacy:'.length);
    }
    return uuid == refUuid;
  }

  /// 收集当前库实际引用的图片路径（存活集；仅写入 manifest.images 展示项）。
  Future<List<String>> _referencedImages() async {
    final db = await DatabaseHelper.instance.database;
    final out = <String>{};
    for (final row in await db.query(
      'rounds',
      columns: ['user_images', 'ai_images'],
    )) {
      out.addAll(_decodeImgList(row['user_images']));
      out.addAll(_decodeImgList(row['ai_images']));
    }
    for (final row in await db.query('books', columns: ['failed_user_images'])) {
      out.addAll(_decodeImgList(row['failed_user_images']));
    }
    return out.toList();
  }

  static List<String> _decodeImgList(Object? raw) {
    if (raw is! String || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return decoded.map((e) => e.toString()).toList();
    } catch (_) {
      // 非法 JSON 忽略。
    }
    return const [];
  }

  // ---- 图片平面本地读写（仅 ImageSyncRunner 使用） ----

  Future<List<String>> _localImagePaths() async {
    final dir = await ImageStore.imgDirectory();
    if (!await dir.exists()) return const [];
    final out = <String>[];
    await for (final e in dir.list(followLinks: false)) {
      if (e is File) {
        out.add('${ImageStore.relativeDir}/${e.uri.pathSegments.last}');
      }
    }
    return out;
  }

  Future<Uint8List?> _readLocalImage(String relPath) async {
    try {
      return await ImageStore.readBytes(relPath);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeLocalImage(String relPath, Uint8List bytes) async {
    final abs = await ImageStore.resolveAbsolute(relPath);
    await File(abs).writeAsBytes(bytes, flush: true);
  }

  /// 删除本机 `img/` 下的图片文件（其它设备删除意图的本地传播）。
  Future<void> _deleteLocalImage(String relPath) async {
    final abs = await ImageStore.resolveAbsolute(relPath);
    final file = File(abs);
    if (await file.exists()) await file.delete();
  }

  // ---------------------------------------------------------------------------
  // 备份列表 / 数据恢复（与两平面任务共用执行道互斥由调用方 UI 门控）
  // ---------------------------------------------------------------------------

  /// 刷新云端备份列表。
  Future<void> refreshBackups() async {
    if (isBusy) return;
    _opsBusy = true;
    _error = null;
    notifyListeners();
    WebDavService? dav;
    try {
      dav = _buildDav();
      await _loadBackups(dav);
    } catch (e) {
      _error = e.toString();
    } finally {
      dav?.close();
      _opsBusy = false;
      notifyListeners();
    }
  }

  /// 测试 WebDAV 连接：用传入的表单值（无需先保存）创建/检查目录并列出条目。
  ///
  /// 成功返回 null，失败返回错误信息（同时写入 [error]）。
  Future<String?> testConnection({
    required String url,
    required String username,
    required String password,
    required String folder,
  }) async {
    if (isBusy) return '正在进行其他同步操作，请稍候';
    _opsBusy = true;
    _error = null;
    notifyListeners();
    try {
      final dir = folder.trim();
      if (dir.isEmpty) {
        throw StateError('存储文件夹不能为空');
      }
      final dav = WebDavService(
        baseUrl: url.trim(),
        username: username.trim(),
        password: password,
      );
      try {
        await dav.ensureCollection(dir);
        await dav.list(dir);
      } finally {
        dav.close();
      }
      return null;
    } catch (e) {
      _error = e.toString();
      return e.toString();
    } finally {
      _opsBusy = false;
      notifyListeners();
    }
  }

  Future<void> _loadBackups(WebDavService dav) async {
    final files = await dav.list(_folder.trim());
    _backups = files
        .where((f) => WebDavSyncStore.isSnapshot(f.name))
        .toList()
      ..sort(compareSnapshots);
    _backupsLoaded = true;
  }

  /// 快照排序：代际新 → 旧；同代按文件名倒序（文件名内嵌生成时间戳，
  /// 同代即时间序，比服务器修改时间更精确）。
  static int compareSnapshots(WebDavFile a, WebDavFile b) {
    final ag = WebDavSyncStore.generationOf(a.name) ?? -1;
    final bg = WebDavSyncStore.generationOf(b.name) ?? -1;
    if (ag != bg) return bg.compareTo(ag);
    return b.name.compareTo(a.name);
  }

  /// 下载指定快照到临时目录，返回临时文件路径；失败返回 null。
  Future<String?> downloadBackup(String name) async {
    if (isBusy) return null;
    _opsBusy = true;
    _error = null;
    notifyListeners();
    WebDavService? dav;
    try {
      dav = _buildDav();
      return await CloudSyncService.downloadBackup(
        dav: dav,
        folder: _folder.trim(),
        name: name,
      );
    } catch (e) {
      _error = e.toString();
      return null;
    } finally {
      dav?.close();
      _opsBusy = false;
      notifyListeners();
    }
  }

  /// 用已下载的快照替换本地数据（删除本地数据后整体恢复）。
  ///
  /// 恢复成功后把云端内容设为共基并触发一次自动同步：本地恢复结果
  /// 将以新版本推送回云端（云端回滚到恢复点）。
  Future<bool> applyReplace(String tempPath) async {
    final ok = await _apply(() async {
      await CloudSyncService.applyReplace(tempPath);
    });
    if (!ok) return false;
    await _rebaseAndQueuedSync();
    return true;
  }

  /// 按合并决策页的逐书 / 逐 Mod 选择落地进本地库，并在成功后刷新本地内存态数据。
  ///
  /// 供「合并决策页」在用户确认后作为 onApply 调用；按用户的决策整本替换 / Mod 合并。
  /// 合并落定后把云端内容设为共基并触发一次自动同步（推送合并结果）。
  Future<DatabaseMergeResult> applyMergePlan(
    DatabaseMergePlan plan,
    Map<String, BookPartDecisions> bookDecisions,
    Map<String, ModMergeDecision> modDecisions,
  ) async {
    final result = await DatabaseMergeService.applyPlanIntoLocal(
      plan,
      bookDecisions,
      modDecisions,
    );
    await onDataRestored?.call();
    await _rebaseAndQueuedSync();
    return result;
  }

  /// 执行数据落地操作并触发刷新回调。
  Future<bool> _apply(Future<void> Function() action) async {
    if (isBusy) return false;
    _opsBusy = true;
    _error = null;
    notifyListeners();
    try {
      await action();
      await onDataRestored?.call();
      return true;
    } catch (e) {
      _error = e.toString();
      return false;
    } finally {
      _opsBusy = false;
      notifyListeners();
    }
  }

  void _cleanupTemp(String path) {
    try {
      File(path).delete();
    } catch (_) {
      // 临时文件清理失败可忽略。
    }
  }
}

/// 首次连接预检结果（含「用云端覆盖本地」落地的代际）。
class _FirstConnectResult {
  final _FirstConnectOutcome outcome;
  final int? generation;

  const _FirstConnectResult(this.outcome, {this.generation});
}

/// 首次连接预检结局。
enum _FirstConnectOutcome {
  /// 无需处理（老用户 / 仅一端有数据），走常规同步。
  continueSync,

  /// 覆盖类选择已落地（如「用云端覆盖本地」），本次同步完成。
  completed,

  /// 用户取消（不执行同步）。
  aborted,
}

/// 冲突引导处理结果（ok=已进合并页；message=取消类提示；error=失败原因）。
class _ConflictResult {
  final bool ok;
  final String? message;
  final String? error;

  const _ConflictResult({required this.ok, this.message, this.error});
}
