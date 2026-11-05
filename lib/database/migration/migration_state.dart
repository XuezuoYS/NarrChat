import 'dart:convert';
import 'dart:io';

/// 3.0 迁移进度（`local_config/migration_state.json`）。
///
/// 迁移必须**幂等、可中断、可续跑**：
/// - `masterUuid` 一旦写入就固定，重跑时不重新生成；
/// - `migratedBooks` 里已成功的书直接跳过（书库文件会被复用）；
/// - `failedBooks` 记录单本失败原因，其余书继续；
/// - `done` 为 true 时整个迁移不再执行。
class MigrationState {
  const MigrationState({
    this.formatVersion = 3,
    this.masterUuid = '',
    this.done = false,
    this.migratedBooks = const {},
    this.failedBooks = const {},
    this.updatedAt = '',
  });

  /// 状态文件格式版本（与本项目的"软件大版本"对齐，3 = 3.0 拆库）。
  final int formatVersion;

  /// 本套 user_data 的全局 UUID。
  final String masterUuid;

  /// 迁移是否已全部完成。
  final bool done;

  /// 已完成的书 uuid。
  final Set<String> migratedBooks;

  /// 失败的书 uuid → 原因。
  final Map<String, String> failedBooks;

  final String updatedAt;

  bool get isEmpty => masterUuid.isEmpty && migratedBooks.isEmpty && !done;

  MigrationState copyWith({
    String? masterUuid,
    bool? done,
    Set<String>? migratedBooks,
    Map<String, String>? failedBooks,
    String? updatedAt,
  }) {
    return MigrationState(
      formatVersion: formatVersion,
      masterUuid: masterUuid ?? this.masterUuid,
      done: done ?? this.done,
      migratedBooks: migratedBooks ?? this.migratedBooks,
      failedBooks: failedBooks ?? this.failedBooks,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  factory MigrationState.fromJson(Map<String, Object?> json) {
    final migrated = json['migratedBooks'];
    final failed = json['failedBooks'];
    return MigrationState(
      formatVersion: (json['formatVersion'] as num?)?.toInt() ?? 3,
      masterUuid: (json['masterUuid'] as String?) ?? '',
      done: json['done'] == true,
      migratedBooks: migrated is List
          ? migrated.map((e) => e.toString()).toSet()
          : const {},
      failedBooks: failed is Map
          ? {
              for (final entry in failed.entries)
                entry.key.toString(): entry.value.toString(),
            }
          : const {},
      updatedAt: (json['updatedAt'] as String?) ?? '',
    );
  }

  Map<String, Object?> toJson() {
    return {
      'formatVersion': formatVersion,
      'masterUuid': masterUuid,
      'done': done,
      'migratedBooks': migratedBooks.toList()..sort(),
      'failedBooks': failedBooks,
      'updatedAt': updatedAt,
    };
  }

  /// 读取进度文件；不存在或损坏都返回 `null`（视为没开始过）。
  static Future<MigrationState?> read(File file) async {
    if (!await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      return MigrationState.fromJson(
        decoded.map((key, value) => MapEntry(key.toString(), value)),
      );
    } catch (_) {
      // 损坏的进度文件不阻塞启动：从头再跑一遍迁移是安全的（逐本幂等）。
      return null;
    }
  }

  /// 原子写入：先写 `.tmp` 再改名，避免中途断电留下半个 JSON。
  static Future<void> write(File file, MigrationState state) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(state.toJson()), flush: true);
    if (await file.exists()) {
      await file.delete();
    }
    await tmp.rename(file.path);
  }
}
