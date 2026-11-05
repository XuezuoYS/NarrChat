import 'dart:typed_data';

import 'package:narrchat/services/cloud_backup/backup_remote.dart';
import 'package:narrchat/services/sync/img_tombstones.dart';

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
