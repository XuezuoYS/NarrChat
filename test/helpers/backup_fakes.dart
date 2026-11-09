import 'dart:typed_data';

import 'package:narrchat/services/cloud_backup/backup_remote.dart';
import 'package:narrchat/services/sync/img_tombstones.dart';
import 'package:narrchat/services/webdav_service.dart';

/// 内存版云端：整跑备份 / 还原而不碰网络。
class FakeBackupRemote implements BackupRemote {
  FakeBackupRemote({Map<String, List<int>>? initial}) {
    if (initial != null) {
      initial.forEach((name, bytes) => files[name] = Uint8List.fromList(bytes));
    }
  }

  final Map<String, Uint8List> files = {};

  bool ready = false;
  bool closed = false;

  /// 各方法的调用次数（断言"没有再传一遍"用）。
  int writeCount = 0;
  int deleteCount = 0;
  int listCount = 0;

  /// 置为非空时，所有读操作抛这个异常（模拟网络故障）。
  String? failReads;

  /// 置为非空时，所有删除操作抛这个异常（模拟删除失败）。
  String? failDeletes;

  /// 只对这几个文件名的读取抛异常（模拟 `sync_config.json` 单独读不到）。
  final Set<String> failReadsFor = {};

  @override
  Future<void> ensureReady() async {
    ready = true;
  }

  @override
  Future<Set<String>> list() async {
    listCount++;
    return files.keys.toSet();
  }

  @override
  Future<Uint8List> read(String name) async {
    final failure = failReads;
    if (failure != null) throw BackupRemoteException(failure);
    if (failReadsFor.contains(name)) {
      throw BackupRemoteException('模拟读取失败：$name');
    }
    final bytes = files[name];
    if (bytes == null) {
      throw BackupRemoteException('云端文件不存在：$name');
    }
    return Uint8List.fromList(bytes);
  }

  @override
  Future<void> write(String name, List<int> bytes) async {
    writeCount++;
    files[name] = Uint8List.fromList(bytes);
  }

  @override
  Future<void> delete(String name) async {
    final failure = failDeletes;
    if (failure != null) throw BackupRemoteException(failure);
    deleteCount++;
    files.remove(name);
  }

  @override
  void close() {
    closed = true;
  }

  /// 便利方法：直接塞一份文件（模拟另一台设备上传）。
  void put(String name, List<int> bytes) {
    files[name] = Uint8List.fromList(bytes);
  }

  /// 便利方法：取文本内容。
  String? text(String name) {
    final bytes = files[name];
    return bytes == null ? null : String.fromCharCodes(bytes);
  }
}

/// 内存版墓碑工作副本。
class MemoryTombstoneStore implements SyncTombstoneStore {
  ImgTombstones value = ImgTombstones.empty;

  int saveCount = 0;

  @override
  Future<ImgTombstones> load() async => value;

  @override
  Future<void> save(ImgTombstones tombstones) async {
    value = tombstones;
    saveCount++;
  }
}

/// 内存版 WebDAV 客户端：备份列表 / `sync_config.json` 的读写，不碰网络。
///
/// 数据面（快照 / 清单）走 [FakeBackupRemote]；这里服务「云端备份」面板的
/// `refreshBackups` / `refreshKeepVersions`（真实 provider，注入 `webDavFactory`），
/// 以及需要断言「文件到底落在哪个目录」的同步用例。
///
/// 所有操作都记录目录参数：`ensureCalls` / `listPaths` / `reads` / `writes` /
/// `deletes`。用来验证数据进 `<folder>/`、图片进 `<folder>/img/`、根目录不落文件。
class FakeWebDavService extends WebDavService {
  FakeWebDavService({
    Map<String, List<int>> files = const {},
    Map<String, DateTime?> modified = const {},
    this.listError,
    this.listErrorStatus,
    this.getError,
    this.pathScoped = false,
  }) : files = {...files},
       _modifiedTimes = modified,
       super(
         baseUrl: 'https://dav.example.invalid/',
         username: 'user',
         password: 'secret',
       );

  /// 云端文件（名字 → 字节）。
  ///
  /// [pathScoped] 为 true 时键是「目录/文件名」（如 `narrchat/a.db`）；
  /// 默认 false，仍是裸文件名（旧用例不关心目录，保持简单）。
  final Map<String, List<int>> files;

  /// 是否按目录分开存。
  ///
  /// true：`put('a/b', 'x.db')` 存成 `a/b/x.db`，`list('a')` 只返回 `a` 的直属
  /// 文件——用它才能真实验证「数据与图片各进各的目录」。
  final bool pathScoped;

  /// MKCOL 过的路径（按调用顺序；服务器根记成 `''`）。
  final List<String> ensureCalls = [];

  /// 每次 `list` 的目录参数。
  final List<String> listPaths = [];

  final List<({String path, String name})> reads = [];
  final List<({String path, String name})> writes = [];
  final List<({String path, String name})> deletes = [];

  /// 文件的上传时间（列表展示 / 排序用）。
  final Map<String, DateTime?> _modifiedTimes;

  /// 非 null：`list` 抛这条异常文本（模拟列目录失败）。
  String? listError;

  /// [listError] 的状态码（例如 404 = 云端文件夹还没建）。
  int? listErrorStatus;

  /// 非 null：`get` 抛这条异常文本（模拟读取失败）。
  String? getError;

  int listCalls = 0;
  int getCalls = 0;
  bool closed = false;

  String _key(String path, String name) =>
      pathScoped && path.isNotEmpty ? '$path/$name' : name;

  @override
  Future<void> ensureCollection(String path) async => ensureCalls.add(path);

  @override
  Future<List<WebDavFile>> list(String path) async {
    listCalls++;
    listPaths.add(path);
    if (listError != null) {
      throw WebDavException(listError!, statusCode: listErrorStatus);
    }
    if (!pathScoped) {
      return [
        for (final entry in files.entries)
          WebDavFile(
            name: entry.key,
            lastModified: _modifiedTimes[entry.key],
            size: entry.value.length,
          ),
      ];
    }
    final prefix = path.isEmpty ? '' : '$path/';
    return [
      for (final entry in files.entries)
        if (entry.key.startsWith(prefix) &&
            !entry.key.substring(prefix.length).contains('/'))
          WebDavFile(
            name: entry.key.substring(prefix.length),
            lastModified: _modifiedTimes[entry.key.substring(prefix.length)],
            size: entry.value.length,
          ),
    ];
  }

  @override
  Future<Uint8List> get(String path, String name) async {
    getCalls++;
    reads.add((path: path, name: name));
    if (getError != null) throw WebDavException(getError!);
    final bytes = files[_key(path, name)];
    if (bytes == null) throw const WebDavException('下载失败', statusCode: 404);
    return Uint8List.fromList(bytes);
  }

  @override
  Future<void> put(String path, String name, Uint8List bytes) async {
    writes.add((path: path, name: name));
    files[_key(path, name)] = Uint8List.fromList(bytes);
  }

  @override
  Future<void> delete(String path, String name) async {
    deletes.add((path: path, name: name));
    files.remove(_key(path, name));
  }

  @override
  void close() {
    closed = true;
    super.close();
  }
}
