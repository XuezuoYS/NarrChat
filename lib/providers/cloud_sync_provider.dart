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
import '../services/sync/sync_local_snapshot.dart';
import '../services/sync/sync_merge_planner.dart';
import '../services/sync/sync_models.dart';
import '../services/sync/remote_snapshot_applier.dart';
import '../services/sync/sync_remote_store.dart';
import '../services/sync/sync_service.dart';
import '../services/webdav_service.dart';
import '../screens/database_merge_screen.dart';
import '../widgets/sync_bootstrap_dialog.dart';
import '../widgets/sync_conflict_dialog.dart';

/// 云同步（WebDAV）设置与同步操作状态管理。
///
/// 存储策略（符合 AGENTS.md 数据结构规范）：
/// - **密码**：写入 `flutter_secure_storage`（系统密钥库），禁止明文落盘；
/// - 其余设置（服务器地址、用户名、文件夹、保留版本数、自动上传、
///   同步模式、设备标识）：写入本地明文 JSON 配置文件
///   `local_config/app_settings.json`（[LocalConfigService]），不进入云存储。
///
/// 云端文件约定（新版同步规则）：
/// - `manifest.json`：增量索引；
/// - `narrchat_snapshot_g<gen>_<yyyyMMdd_HHmmss>.db`：数据库快照（版本备份）；
/// - `img/<hash>.<ext>`：图片 blob（随同步自动多端复制）。
/// 旧版 `narrchat_<user>_*.db` 备份命名不再支持。
class CloudSyncProvider extends ChangeNotifier with WidgetsBindingObserver {
  CloudSyncProvider();

  /// 全局 ScaffoldMessenger key：用于每轮结束自动上传等后台操作的 SnackBar 提示
  ///（不依赖任何页面的 BuildContext）。main.dart 的 MaterialApp 引用同一 key。
  static final GlobalKey<ScaffoldMessengerState> messengerKey =
      GlobalKey<ScaffoldMessengerState>();

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

  /// 最近一次同步的状态（供 HUD / 同步状态章）。
  SyncState _syncState = SyncState.idle;

  /// 当前同步进度事件（供 HUD 展示阶段 / 进度 / 当前文件）。
  SyncProgressEvent? _progress;

  /// 用户是否请求取消当前同步（协作式，SyncService 在阶段间检查）。
  bool _cancelRequested = false;

  /// 同步进行中期间又有新的同步请求（自动触发节点）时置位，
  /// 当前同步结束后自动补跑一次（队列合并，避免并发同步互相覆盖）。
  bool _pendingSyncRequested = false;

  /// 待补跑同步是否为静默模式（轮询/回前台触发不弹成功提示）。
  bool _pendingSyncSilent = false;

  /// 静默轮询定时器（仅自动模式下存在；每分钟一次，无变更时不推进、不提示）。
  Timer? _pollTimer;

  /// 首次连接分支决策（首次连接弹窗的选择结果；否则为 null）。
  SyncBootstrapDecision? _bootstrapDecision;

  /// 首次连接「用云端覆盖本地」完成后落地的云端代际（结果提示用）。
  int? _firstConnectGeneration;

  bool _isBusy = false;
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

  /// 当前同步状态（供 HUD / 状态章）。
  SyncState get syncState => _syncState;

  /// 当前同步进度事件（无正在进行的同步时为 null）。
  SyncProgressEvent? get progress => _progress;

  /// 首次连接分支决策（首次连接弹窗的选择结果）。
  SyncBootstrapDecision? get bootstrapDecision => _bootstrapDecision;

  /// 应用级 Navigator key：供同步流程在无 UI Context 时弹出首连分支 / 冲突对话框。
  ///
  /// 默认持有独立 key；main.dart 会把它绑定到与应用相同的 navigator，
  /// 使同步流程能复用现有路由（通知跳转与同步对话框共用同一 Navigator）。
  static GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  /// 展示云同步结果提示（走应用级全局 messenger，跨页面可见）。
  ///
  /// - 内容为 [SelectableText]：可长按 / 拖动选择并复制（含报错详情）；
  /// - [persistent] 为 true（失败等需留意结果）时不自动消失，点击「关闭」手动关闭。
  static void showSyncSnack(String message, {bool persistent = false}) {
    final messenger = messengerKey.currentState;
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: SelectableText(
            message,
            style: const TextStyle(fontSize: 13, height: 1.3),
          ),
          duration: persistent
              ? const Duration(days: 1)
              : const Duration(seconds: 4),
          action: persistent
              ? SnackBarAction(
                  label: '关闭',
                  onPressed: messenger.hideCurrentSnackBar,
                )
              : null,
        ),
      );
  }

  /// 请求取消当前同步（HUD 取消按钮回调；同步完成 / 停止后自动复位）。
  ///
  /// 用户主动取消时同时清掉待跑队列（避免取消后又立刻被补同步）。
  void cancelSync() {
    if (_syncState != SyncState.syncing) return;
    _cancelRequested = true;
    _pendingSyncRequested = false;
    notifyListeners();
  }

  /// 接入应用生命周期：回前台触发一次静默同步；
  /// 并启动每分钟一次的静默轮询（自动模式下才实际执行），
  /// 保证"另一台设备改了数据、本机空闲在首页"时也能就近拉取。
  void attachLifecycle() {
    WidgetsBinding.instance.addObserver(this);
    _pollTimer ??= Timer.periodic(
      const Duration(minutes: 1),
      (_) => triggerAutoSync(silent: true),
    );
  }

  /// 解除生命周期监听与轮询（测试 / 应用退出时调用）。
  void detachLifecycle() {
    WidgetsBinding.instance.removeObserver(this);
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      triggerAutoSync(silent: true);
    }
  }

  /// 全自动同步触发入口（各数据变更节点调用）。
  ///
  /// - 未配置 WebDAV 或当前为手动模式：忽略；
  /// - 空闲：立即发起一次后台同步；
  /// - 已有同步在进行：置 [pendingSyncRequested]，当前同步结束后自动补跑一次
  ///   （多个触发点合并为一次补跑，同步本身幂等，见 docs/sync_auto_triggers.md）。
  /// - [silent] 为 true（轮询 / 回前台 / 打开书籍设置等被动触发）时，
  ///   成功类结果不弹提示（失败仍提示）。
  void triggerAutoSync({bool silent = false}) {
    if (!isConfigured || _syncMode != SyncMode.auto) return;
    if (_isBusy) {
      _pendingSyncRequested = true;
      _pendingSyncSilent = _pendingSyncSilent || silent;
      return;
    }
    unawaited(sync(auto: true, silent: silent));
  }

  /// 测试用：是否已有排队待跑的自动同步。
  @visibleForTesting
  bool get debugPendingSyncRequested => _pendingSyncRequested;

  /// 测试用：读取取消请求标记（HUD 取消按钮断言用）。
  @visibleForTesting
  bool get debugCancelRequested => _cancelRequested;

  /// 测试用：直接改写同步状态（避免依赖真实网络路径）。
  @visibleForTesting
  void debugSetSyncState(SyncState state) {
    _syncState = state;
    notifyListeners();
  }

  /// 测试用：直接改写同步进度事件。
  @visibleForTesting
  void debugSetProgress(SyncProgressEvent? event) {
    _progress = event;
    notifyListeners();
  }

  /// 测试用：直接设置忙碌标记（验证队列逻辑，避免触发真实网络）。
  @visibleForTesting
  void debugSetBusy(bool value) {
    _isBusy = value;
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

  /// 测试用：直接改写同步模式（避免触碰本地配置文件）。
  @visibleForTesting
  void debugSetSyncMode(SyncMode mode) {
    _syncMode = mode;
    _autoUpload = mode == SyncMode.auto;
    notifyListeners();
  }

  bool get isBusy => _isBusy;
  String? get error => _error;

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

  /// 统一的「同步」入口：拉取远端非冲突变更并推送本地变更。
  ///
  /// [auto] 为 true 时是后台自动同步（与手动「同步」按钮共用同一流程，
  /// 结果提示统一为 [showSyncSnack]——完成/取消显示原因，失败驻留可复制可关闭）。
  ///
  /// [silent] 为 true（轮询 / 回前台 / 被动触发）时**抑制成功类提示**（
  /// "已是最新版本" 等不再刷屏），失败仍驻留提示。
  ///
  /// 返回 true 表示本次同步完成（含「已是最近版本」与「冲突已引导处理」）；
  /// false 表示失败 / 用户取消 / 冲突待处理。同步进行期间再次调用会排队
  /// （[triggerAutoSync] 语义），当前同步结束后自动补跑一次。
  Future<bool> sync({bool auto = false, bool silent = false}) async {
    if (_isBusy) {
      _pendingSyncRequested = true;
      _pendingSyncSilent = _pendingSyncSilent || silent;
      return false;
    }
    _isBusy = true;
    _syncState = SyncState.syncing;
    _error = null;
    _progress = null;
    _cancelRequested = false;
    notifyListeners();
    bool ok = false;
    String? resultMessage;
    var resultPersistent = false;
    WebDavService? dav;
    try {
      dav = _buildDav();
      final davStore = WebDavSyncStore(dav: dav, folder: _folder.trim());
      await davStore.ensureFolder();
      final preflight = await _handleFirstConnect(davStore);
      if (preflight == _FirstConnectOutcome.aborted) {
        _syncState = SyncState.idle;
        resultMessage = '已取消同步';
      } else if (preflight == _FirstConnectOutcome.completed) {
        ok = true;
        _syncState = SyncState.success;
        final gen = _firstConnectGeneration;
        resultMessage = gen == null
            ? '已导入云端数据'
            : '已导入云端数据（第 $gen 代）';
        _firstConnectGeneration = null;
      } else {
        final service = _buildSyncService(davStore);
        final result = await service.sync();
        if (result.error != null) {
          // 「已取消」＝用户通过 HUD 主动取消，非失败。
          final cancelled = result.error == '已取消';
          _error = cancelled ? null : result.error;
          _syncState = cancelled ? SyncState.idle : SyncState.error;
          ok = false;
          resultMessage = cancelled
              ? '已取消同步'
              : '同步失败：${result.error}';
          resultPersistent = !cancelled;
        } else if (result.hasConflict) {
          ok = await _handleConflict(davStore);
          if (ok) {
            resultMessage = null; // 已进入冲突解决页，无需再提示
          } else if (_error != null) {
            resultMessage = '同步失败：$_error';
            resultPersistent = true;
          } else {
            resultMessage = '已取消同步，同步模式已切换为手动。需要时请点击「同步」按钮。';
          }
        } else {
          // 「无变更（已是最新）」「仅拉取落地」「有变更并已推送」都视为成功。
          _syncState = SyncState.success;
          ok = true;
          // 有落地变更（拉取 / 删除传播）时刷新内存态数据：
          // 否则另一台设备同步后 UI 仍显示缓存的旧轮次 / 旧书籍列表。
          if (result.applied && onDataRestored != null) {
            await onDataRestored!();
          }
          final gen = result.generation;
          if (result.pushed) {
            resultMessage =
                '已同步到云端${gen == null ? '' : '（第 $gen 代）'}';
          } else if (result.applied) {
            resultMessage =
                '已同步最新内容${gen == null ? '' : '（第 $gen 代）'}';
          } else {
            resultMessage =
                '已是最新版本${gen == null ? '' : '（第 $gen 代）'}';
          }
        }
      }
      // 刷新备份列表（展示最新一代快照）。
      await _loadBackups(dav);
    } catch (e) {
      _error = e.toString();
      _syncState = SyncState.error;
      ok = false;
      resultMessage = '同步失败：$e';
      resultPersistent = true;
    } finally {
      dav?.close();
      _isBusy = false;
      _cancelRequested = false;
      _progress = null;
      notifyListeners();
      // 排队补跑：同步幂等，多个触发点合并为一次（继承静默标记）。
      if (_pendingSyncRequested) {
        _pendingSyncRequested = false;
        final pendingSilent = _pendingSyncSilent;
        _pendingSyncSilent = false;
        unawaited(sync(auto: true, silent: pendingSilent));
      }
    }
    // 静默模式（轮询 / 回前台 / 打开书籍设置）只保留失败类提示，
    // 避免"已是最新版本"类消息每分钟刷屏。
    if (resultMessage != null && (!silent || resultPersistent)) {
      showSyncSnack(resultMessage, persistent: resultPersistent);
    }
    return ok;
  }

  // ---------------------------------------------------------------------------
  // 首次连接分支
  // ---------------------------------------------------------------------------

  /// 首次连接分支处理：
  /// - 无需弹窗（老用户 / 仅一端有数据）：直接走常规同步；
  /// - 弹窗后按用户选择落地：`pullCloud` 用云端覆盖本地并完成，
  ///   `initCloud` 把云端设为共基后走常规同步（推送本地），
  ///   `mergeBoth` 走常规同步（真冲突进入冲突处理）。
  Future<_FirstConnectOutcome> _handleFirstConnect(
    WebDavSyncStore davStore,
  ) async {
    final decision = await _computeFirstConnectDecision(davStore);
    if (decision == null) return _FirstConnectOutcome.continueSync;
    final summary = SyncBootstrapSummary(
      localBooks: await _localCount('books'),
      localMods: await _localCount('mods'),
      cloudBooks: decision == SyncBootstrapDecision.mergeBoth
          ? await _cloudBookCount(davStore)
          : 0,
      cloudMods: decision == SyncBootstrapDecision.mergeBoth
          ? await _cloudModCount(davStore)
          : 0,
    );
    final ctx = navigatorKey.currentState?.context;
    if (ctx == null) {
      // 无可渲染的 Navigator（如纯后台自动同步）时记录并跳过，走常规同步；
      // 常规同步检出冲突后走冲突处理（同样会因无 Navigator 而记录错误）。
      _bootstrapDecision = decision;
      return _FirstConnectOutcome.continueSync;
    }
    // ctx 取自应用级 Navigator（常驻），非会话内会失效的局部 context，忽略该告警。
    // ignore: use_build_context_synchronously
    final chosen = await showSyncBootstrapDialog(ctx, summary: summary);
    if (chosen == null) return _FirstConnectOutcome.aborted;
    _bootstrapDecision = chosen;
    if (chosen == SyncBootstrapDecision.pullCloud) {
      _firstConnectGeneration = await _applyCloudOverLocal(davStore);
      return _FirstConnectOutcome.completed;
    }
    if (chosen == SyncBootstrapDecision.initCloud) {
      // 本地覆盖云端：先让远端内容成为共基，常规同步即会以 localOnly 推送本地。
      await _adoptRemoteAsBase(davStore);
    }
    return _FirstConnectOutcome.continueSync;
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
  /// （替换后本地与云端一致，下次同步为「无变更」）。
  ///
  /// 返回落地的云端代际（无快照可下载时返回 null）。
  Future<int?> _applyCloudOverLocal(WebDavSyncStore davStore) async {
    final manifest = await davStore.readManifest();
    final name = await davStore.latestSnapshotName(
      generation: manifest?.generation,
    );
    if (name == null) return null;
    final bytes = await davStore.readSnapshot(name);
    if (bytes == null) return null;
    final tempPath = await CloudSyncService.saveSnapshotToTemp(name, bytes);
    try {
      await CloudSyncService.applyReplace(tempPath);
      // 用云端内容修正本地共基，避免下次同步把远端当作变化拉回。
      await _adoptRemoteAsBase(davStore);
      if (onDataRestored != null) {
        await onDataRestored!();
      }
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
  /// 失败（如离线）不阻塞恢复结果本身；自动同步由 [triggerAutoSync] 门控。
  Future<void> _rebaseAndQueuedSync() async {
    WebDavService? dav;
    try {
      dav = _buildDav();
      await _adoptRemoteAsBase(WebDavSyncStore(dav: dav, folder: _folder.trim()));
    } catch (e) {
      _error = e.toString();
    } finally {
      dav?.close();
    }
    triggerAutoSync();
  }

  // ---------------------------------------------------------------------------
  // 冲突处理
  // ---------------------------------------------------------------------------

  /// 同步检出冲突后的引导对话框：
  /// - 取消同步：中止本次同步并把同步模式改为手动；
  /// - 解决冲突：下载当前代快照，进入合并决策页逐本确认。
  Future<bool> _handleConflict(WebDavSyncStore davStore) async {
    final ctx = navigatorKey.currentState?.context;
    if (ctx == null) {
      _error = '检测到同步冲突，请打开「设置 → 云同步」处理。';
      _syncState = SyncState.error;
      return false;
    }
    // 更新 HUD/进度文案：检出冲突 → 等待用户选择，而不是停留在上一步描述。
    _setProgress(SyncPhase.merge, '检测到同步冲突，等待处理…');
    // ctx 取自应用级 Navigator（常驻），忽略该告警。
    // ignore: use_build_context_synchronously
    final action = await showSyncConflictDialog(ctx);
    if (action == SyncConflictAction.cancelSync) {
      await setSyncMode(SyncMode.manual);
      _error = null;
      _syncState = SyncState.idle;
      return false;
    }
    final resolved = await _openConflictResolver(davStore);
    if (!resolved) {
      _error = '冲突解决失败：无法下载/解析远端快照，请稍后重试或改用「云端备份」列表处理。';
      _syncState = SyncState.error;
      return false;
    }
    // 已引导进入合并决策页；合并落定后由 applyMergePlan 触发补同步推送结果。
    _syncState = SyncState.success;
    return true;
  }

  /// 打开冲突解决页：下载当前代快照 → 构建合并计划 → 进入 [DatabaseMergeScreen]。
  Future<bool> _openConflictResolver(WebDavSyncStore davStore) async {
    final ctx = navigatorKey.currentState?.context;
    if (ctx == null) return false;
    // 更新 HUD/进度文案：走下一步（下载快照），避免停留在上一步描述。
    _setProgress(SyncPhase.pullSnapshot, '下载远端快照…');
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
    _setProgress(SyncPhase.merge, '检测到冲突，请在合并页选择处理方式…');
    // 合并页弹在应用级 Navigator 上；onApply 由 applyMergePlan 落地并补同步。
    await DatabaseMergeScreen.open(
      // ignore: use_build_context_synchronously
      ctx,
      plan: plan,
      onApply: (p, bd, md) => applyMergePlan(p, bd, md),
    );
    return true;
  }

  /// 更新同步进度事件（供 HUD 展示当前步骤；冲突页交互阶段也随步骤更新）。
  void _setProgress(SyncPhase phase, String label) {
    _progress = SyncProgressEvent(phase: phase, label: label);
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // 同步服务构建
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

  /// 构建驱动真实云同步的 [SyncService]（用真实 WebDAV + 本地库 + 图片目录）。
  SyncService _buildSyncService(WebDavSyncStore store) {
    return SyncService(
      store: store,
      stateStore: SyncStateDao(),
      deviceId: _deviceId,
      buildLocalSnapshot: () async =>
          SyncLocalSnapshot.build(await DatabaseHelper.instance.database),
      buildSnapshotBytes: CloudSyncService.buildSnapshotBytes,
      referencedImages: _referencedImages,
      localImages: _localImagePaths,
      readLocalImage: _readLocalImage,
      writeLocalImage: _writeLocalImage,
      keepVersions: _keepVersions,
      onProgress: _onSyncProgress,
      isCancelled: () => _cancelRequested,
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
  ) =>
      const RemoteSnapshotApplier().apply(
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

  /// 记录同步进度事件（已接收主线程回调，无需跨线程）。
  void _onSyncProgress(SyncProgressEvent event) {
    _progress = event;
    notifyListeners();
  }

  /// 收集当前库实际引用的图片路径（存活集）。
  Future<List<String>> _referencedImages() async {
    final db = await DatabaseHelper.instance.database;
    final out = <String>{};
    for (final row in await db.query('rounds', columns: ['user_images', 'ai_images'])) {
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

  Future<List<String>> _localImagePaths() async {
    final dir = await ImageStore.imgDirectory();
    if (!await dir.exists()) return const [];
    final out = <String>[];
    await for (final e in dir.list(followLinks: false)) {
      if (e is File) out.add('${ImageStore.relativeDir}/${e.uri.pathSegments.last}');
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

  /// 刷新云端备份列表。
  Future<void> refreshBackups() async {
    if (_isBusy) return;
    _isBusy = true;
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
      _isBusy = false;
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
    if (_isBusy) return '正在进行其他同步操作，请稍候';
    _isBusy = true;
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
      _isBusy = false;
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
    if (_isBusy) return null;
    _isBusy = true;
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
      _isBusy = false;
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
    if (_isBusy) return false;
    _isBusy = true;
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
      _isBusy = false;
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

/// 首次连接预检结果。
enum _FirstConnectOutcome {
  /// 无需处理（老用户 / 仅一端有数据），走常规同步。
  continueSync,

  /// 覆盖类选择已落地（如「用云端覆盖本地」），本次同步完成。
  completed,

  /// 用户取消（不执行同步）。
  aborted,
}
