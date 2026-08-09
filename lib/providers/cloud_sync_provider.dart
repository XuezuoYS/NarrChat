import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

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

  static const String defaultFolder = 'narrchat';
  static const int defaultKeepVersions = 5;
  static const String defaultUserName = 'user';

  String _webdavUrl = '';
  String _webdavUsername = '';
  String _webdavPassword = '';
  String _folder = defaultFolder;
  int _keepVersions = defaultKeepVersions;
  bool _autoUpload = false;
  String _userName = defaultUserName;

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
  String get userName => _userName;

  bool get isBusy => _isBusy;
  String? get error => _error;

  /// 云端备份列表（按修改时间新 → 旧）。
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

  /// 将已下载的临时备份合并进本地数据。
  Future<bool> applyMerge(String tempPath) async {
    return _apply(() async {
      _mergeResult = await CloudSyncService.applyMerge(tempPath);
    });
  }

  DatabaseMergeResult? _mergeResult;

  /// 最近一次合并的统计结果。
  DatabaseMergeResult? get lastMergeResult => _mergeResult;

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
