import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../services/backup_image_service.dart';
import '../services/cloud_sync_service.dart';
import '../services/database_merge_service.dart';
import '../services/local_config_service.dart';
import '../services/webdav_service.dart';

/// 云同步（WebDAV）设置与同步操作状态管理。
///
/// 存储策略（符合 AGENTS.md 数据结构规范）：
/// - **密码**：写入 `flutter_secure_storage`（系统密钥库），禁止明文落盘；
/// - 其余设置（服务器地址、用户名、文件夹、保留版本数、自动上传、
///   备份用户名）：写入本地明文 JSON 配置文件 `local_config/app_settings.json`
///   （[LocalConfigService]），不进入云存储。
class CloudSyncProvider extends ChangeNotifier {
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
  static const String _keyUserName = 'webdavUserName';
  static const String _keyImageKeepVersions = 'imageKeepVersions';

  static const String defaultFolder = 'narrchat';
  static const int defaultKeepVersions = 5;
  static const int defaultImageKeepVersions = 1;
  static const String defaultUserName = 'user';

  String _webdavUrl = '';
  String _webdavUsername = '';
  String _webdavPassword = '';
  String _folder = defaultFolder;
  int _keepVersions = defaultKeepVersions;
  int _imageKeepVersions = defaultImageKeepVersions;
  bool _autoUpload = false;
  String _userName = defaultUserName;

  bool _isBusy = false;
  String? _error;
  List<WebDavFile> _backups = [];
  bool _backupsLoaded = false;

  // 图片备份（独立于数据库备份）。
  List<WebDavFile> _imageBackups = [];
  bool _imageBackupsLoaded = false;
  bool _imageBusy = false;

  String get webdavUrl => _webdavUrl;
  String get webdavUsername => _webdavUsername;
  String get webdavPassword => _webdavPassword;
  String get folder => _folder;
  int get keepVersions => _keepVersions;
  int get imageKeepVersions => _imageKeepVersions;
  bool get autoUpload => _autoUpload;
  String get userName => _userName;

  bool get isBusy => _isBusy;
  String? get error => _error;

  /// 云端备份列表（按修改时间新 → 旧）。
  List<WebDavFile> get backups => List.unmodifiable(_backups);
  bool get backupsLoaded => _backupsLoaded;

  /// 云端图片备份列表。
  List<WebDavFile> get imageBackups => List.unmodifiable(_imageBackups);
  bool get imageBackupsLoaded => _imageBackupsLoaded;
  bool get isImageBackupBusy => _imageBusy;

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
      _imageKeepVersions =
          (cfg[_keyImageKeepVersions] as num?)?.toInt() ?? defaultImageKeepVersions;
      _autoUpload = (cfg[_keyAutoUpload] as bool?) ?? false;
      _userName = (cfg[_keyUserName] as String?) ?? defaultUserName;
    } catch (e) {
      _error = e.toString();
    }
    notifyListeners();
  }

  /// 保存设置。密码写入安全存储，其余写入本地 JSON 配置文件。
  Future<bool> save({
    required String webdavUrl,
    required String webdavUsername,
    required String webdavPassword,
    required String folder,
    required int keepVersions,
    required bool autoUpload,
    required String userName,
  }) async {
    try {
      final trimmedUrl = webdavUrl.trim();
      final trimmedUsername = webdavUsername.trim();
      final trimmedFolder = folder.trim();
      final trimmedUserName = userName.trim();

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
      await LocalConfigService.update({
        _keyUrl: trimmedUrl,
        _keyUsername: trimmedUsername,
        _keyFolder: trimmedFolder,
        _keyKeepVersions: keepVersions,
        _keyAutoUpload: autoUpload,
        _keyUserName: trimmedUserName.isEmpty ? defaultUserName : trimmedUserName,
      });

      _webdavUrl = trimmedUrl;
      _webdavUsername = trimmedUsername;
      _webdavPassword = webdavPassword;
      _folder = trimmedFolder;
      _keepVersions = keepVersions;
      _autoUpload = autoUpload;
      _userName = trimmedUserName.isEmpty ? defaultUserName : trimmedUserName;
      _error = null;
      notifyListeners();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

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
        ..remove(_keyUserName);
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
    _userName = defaultUserName;
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

  /// 手动或自动（每轮结束后）上传本地数据库到云端。
  ///
  /// 上传成功后会刷新本地备份列表，并按「保留历史版本」修剪云端旧备份。
  /// 自动上传完成后通过全局 SnackBar 提示成功或失败。
  Future<bool> upload({bool auto = false}) async {
    if (_isBusy) return false;
    _isBusy = true;
    _error = null;
    notifyListeners();
    bool ok = false;
    WebDavService? dav;
    try {
      dav = _buildDav();
      await CloudSyncService.uploadBackup(
        dav: dav,
        folder: _folder.trim(),
        userName: _userName,
        keepVersions: _keepVersions,
      );
      await _loadBackups(dav);
      ok = true;
    } catch (e) {
      _error = e.toString();
      ok = false;
    } finally {
      dav?.close();
      _isBusy = false;
      notifyListeners();
    }
    if (auto) {
      messengerKey.currentState?.showSnackBar(
        SnackBar(
          content: Text(ok ? '已自动保存到云端' : '自动保存失败：${_error ?? '未知错误'}'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
    return ok;
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

  // ---------------------------------------------------------------------------
  // 图片备份（WebDAV，独立于数据库备份）
  // ---------------------------------------------------------------------------

  /// 设置图片备份保留版本数（1 ~ 99），并持久化。
  Future<bool> setImageKeepVersions(int value) async {
    final v = value.clamp(1, 99);
    _imageKeepVersions = v;
    notifyListeners();
    try {
      await LocalConfigService.update({_keyImageKeepVersions: v});
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  /// 上传本地 `img/` 目录为 zip 备份。[onProgress] 汇报进度（`progress` 为 null 表示不确定）。
  Future<bool> uploadImageBackup({
    void Function(double? progress, String message)? onProgress,
  }) async {
    if (_imageBusy) return false;
    _imageBusy = true;
    _error = null;
    notifyListeners();
    WebDavService? dav;
    try {
      dav = _buildDav();
      await BackupImageService.uploadImageBackup(
        dav: dav,
        folder: _folder.trim(),
        userName: _userName,
        keepVersions: _imageKeepVersions,
        onProgress: onProgress,
      );
      await _loadImageBackups(dav);
      return true;
    } catch (e) {
      _error = e.toString();
      return false;
    } finally {
      dav?.close();
      _imageBusy = false;
      notifyListeners();
    }
  }

  /// 刷新云端图片备份列表。
  Future<void> refreshImageBackups() async {
    if (_imageBusy) return;
    _imageBusy = true;
    _error = null;
    notifyListeners();
    WebDavService? dav;
    try {
      dav = _buildDav();
      await _loadImageBackups(dav);
    } catch (e) {
      _error = e.toString();
    } finally {
      dav?.close();
      _imageBusy = false;
      notifyListeners();
    }
  }

  /// 下载指定图片备份 zip 并解压到本地 `img/`。
  Future<bool> downloadImageBackup(
    String name, {
    void Function(double? progress, String message)? onProgress,
  }) async {
    if (_imageBusy) return false;
    _imageBusy = true;
    _error = null;
    notifyListeners();
    WebDavService? dav;
    try {
      dav = _buildDav();
      await BackupImageService.downloadImageBackup(
        dav: dav,
        folder: _folder.trim(),
        name: name,
        onProgress: onProgress,
      );
      return true;
    } catch (e) {
      _error = e.toString();
      return false;
    } finally {
      dav?.close();
      _imageBusy = false;
      notifyListeners();
    }
  }

  Future<void> _loadImageBackups(WebDavService dav) async {
    final files = await dav.list(_folder.trim());
    _imageBackups = BackupImageService.matchImageBackups(files)
      ..sort(BackupImageService.compareBackups);
    _imageBackupsLoaded = true;
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
    _backups = CloudSyncService.matchBackups(files)
      ..sort(CloudSyncService.compareBackups);
    _backupsLoaded = true;
  }

  /// 下载指定备份到临时目录，返回临时文件路径；失败返回 null。
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

  /// 用已下载的临时备份替换本地数据（删除本地数据后整体恢复）。
  Future<bool> applyReplace(String tempPath) async {
    return _apply(() async {
      await CloudSyncService.applyReplace(tempPath);
    });
  }

  /// 按合并决策页的逐书 / 逐 Mod 选择落地进本地库，并在成功后刷新本地内存态数据。
  ///
  /// 供「合并决策页」在用户确认后作为 onApply 调用；按用户的决策整本替换 / Mod 合并。
  Future<DatabaseMergeResult> applyMergePlan(
    DatabaseMergePlan plan,
    Map<String, MergeBookDecision> bookDecisions,
    Map<String, ModMergeDecision> modDecisions,
  ) async {
    final result = await DatabaseMergeService.applyPlanIntoLocal(
      plan,
      bookDecisions,
      modDecisions,
    );
    await onDataRestored?.call();
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
}
