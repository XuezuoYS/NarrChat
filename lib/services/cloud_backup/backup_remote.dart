import 'dart:typed_data';

import '../webdav_service.dart';

/// 云备份对"远端"的最小需求。
///
/// 抽成接口是为了两件事：
/// - 测试用内存实现整跑一遍备份/还原，不碰网络；
/// - 将来换存储（S3 / 本地目录）只换实现。
abstract class BackupRemote {
  /// 准备远端（建目录等），每次同步入口调一次。
  Future<void> ensureReady();

  /// 列出本远端根目录下全部文件名（不含目录）。
  Future<Set<String>> list();

  /// 读文件；不存在时抛 [BackupRemoteException]。
  Future<Uint8List> read(String name);

  /// 写文件（覆盖）。
  Future<void> write(String name, List<int> bytes);

  /// 删文件；不存在视为成功。
  Future<void> delete(String name);

  void close();
}

/// 远端读写失败。
class BackupRemoteException implements Exception {
  const BackupRemoteException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() =>
      statusCode == null ? message : '$message（HTTP $statusCode）';
}

/// WebDAV 实现：包装 [WebDavService]，统一错误类型。
///
/// [folder] 是这个远端在 WebDAV 上的目录（相对基础地址、不带首尾斜杠）：
/// 数据面用用户设定的文件夹（默认 `narrchat`），图片面用它的 `img` 子目录
/// （默认 `narrchat/img`）。所有读写都只发生在该目录里，绝不碰到根目录。
class WebDavBackupRemote implements BackupRemote {
  WebDavBackupRemote(this._client, {required this.folder});

  final WebDavService _client;
  final String folder;

  @override
  Future<void> ensureReady() async {
    try {
      await _client.ensurePath(folder);
    } on WebDavException catch (error) {
      throw BackupRemoteException(
        '准备云端目录失败：${error.message}',
        statusCode: error.statusCode,
      );
    }
  }

  @override
  Future<Set<String>> list() async {
    try {
      final files = await _client.list(folder);
      return {for (final file in files) file.name};
    } on WebDavException catch (error) {
      throw BackupRemoteException(
        '列出云端文件失败：${error.message}',
        statusCode: error.statusCode,
      );
    }
  }

  @override
  Future<Uint8List> read(String name) async {
    try {
      return await _client.get(folder, name);
    } on WebDavException catch (error) {
      throw BackupRemoteException(
        '读取云端文件失败：${error.message}',
        statusCode: error.statusCode,
      );
    }
  }

  @override
  Future<void> write(String name, List<int> bytes) async {
    try {
      await _client.put(folder, name, Uint8List.fromList(bytes));
    } on WebDavException catch (error) {
      throw BackupRemoteException(
        '上传云端文件失败：${error.message}',
        statusCode: error.statusCode,
      );
    }
  }

  @override
  Future<void> delete(String name) async {
    try {
      await _client.delete(folder, name);
    } on WebDavException catch (error) {
      throw BackupRemoteException(
        '删除云端文件失败：${error.message}',
        statusCode: error.statusCode,
      );
    }
  }

  @override
  void close() => _client.close();
}
