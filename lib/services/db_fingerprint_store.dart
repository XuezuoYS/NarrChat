import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'app_paths.dart';
import 'round_stack_service.dart';

/// 用户库文件的「变更基线」（本地数据：不入库、不云同步）。
///
/// 只记 `size + mtimeMs`——**不做 sha256 整库哈希**（Android 启动期几十 MB 哈希
/// 是白给的延迟）。基线在「迁移完成后的启动」与「App 进入后台 / 正常退出」时写入；
/// 启动时若发现不一致（外部替换库文件 / 整库恢复 / 上次异常退出），触发一次
/// **全量采纳**：采纳幂等，内容一致时不会产生新代，误报代价仅为一次扫描。
class DbFingerprintStore {
  DbFingerprintStore({File? file, File? databaseFile})
      : _fileOverride = file,
        _databaseOverride = databaseFile;

  /// 基线文件名（位于 `<local_config>/`）。
  static const String fileName = 'db_fingerprint.json';

  final File? _fileOverride;

  /// 被测库文件覆盖（测试用临时库；生产为 `user_data/narrchat.db`）。
  final File? _databaseOverride;

  Future<File> _file() async =>
      _fileOverride ??
      File(p.join((await AppPaths.localConfig()).path, fileName));

  /// 当前用户库文件。
  Future<File> _databaseFile() async =>
      _databaseOverride ?? File(await AppPaths.userDatabasePath());

  /// 记录当前库文件基线（无法访问时静默跳过：基线属于优化项，不得影响启动）。
  Future<void> saveBaseline() async {
    try {
      final dbFile = await _databaseFile();
      final stat = await dbFile.stat();
      final data = <String, Object?>{
        'path': dbFile.path,
        'size': stat.size,
        'mtimeMs': stat.modified.millisecondsSinceEpoch,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      };
      await (await _file()).writeAsString(jsonEncode(data), flush: true);
    } catch (e) {
      debugPrint('[db_fingerprint] 写入基线失败：$e');
    }
  }

  /// 自基线以来库文件是否变过。
  ///
  /// 无基线 / 无法访问 / 解析失败一律 `false`（宁可不采纳，也不误触发全量扫描）。
  Future<bool> changedSinceBaseline() async {
    try {
      final dbFile = await _databaseFile();
      // 库文件不存在（尚未建库 / 已被删除）：没有可收敛的目标，判定为未变化。
      if (!await dbFile.exists()) return false;
      final file = await _file();
      if (!await file.exists()) return false;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return false;
      if ((decoded['path'] as String? ?? '') != dbFile.path) return true; // 换了库文件
      final stat = await dbFile.stat();
      if (stat.size != (decoded['size'] as int? ?? -1)) return true;
      return stat.modified.millisecondsSinceEpoch !=
          (decoded['mtimeMs'] as int? ?? -1);
    } catch (e) {
      debugPrint('[db_fingerprint] 读取基线失败：$e');
      return false;
    }
  }

  /// 启动期入口：指纹变化 → 全量采纳 → 写入新基线。返回是否触发过采纳。
  Future<bool> runStartupAdoption(RoundStackService service) async {
    if (!await changedSinceBaseline()) return false;
    await service.adoptAllBooks(force: true);
    await saveBaseline();
    return true;
  }
}
