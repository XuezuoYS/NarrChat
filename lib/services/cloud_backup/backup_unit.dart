import 'package:path/path.dart' as p;

import '../../services/app_paths.dart';

/// 一个备份单元 = 一个数据库文件 = 一个云端快照 = 一个独立代数。
enum BackupUnitKind { library, mods, book }

/// 云备份的最小单元。
///
/// 为什么按"库"而不是按"书的部件"：R3 里一本书就是一个文件，整文件替换是
/// 唯一不会写出半个状态的方案；代价是冲突只能整本二选一（已确认接受）。
class BackupUnit {
  const BackupUnit._(this.kind, this.refUuid);

  final BackupUnitKind kind;

  /// 书 uuid；library / mods 单元为空串。
  final String refUuid;

  static const BackupUnit library = BackupUnit._(BackupUnitKind.library, '');
  static const BackupUnit mods = BackupUnit._(BackupUnitKind.mods, '');

  static BackupUnit book(String bookUuid) {
    if (bookUuid.isEmpty) {
      throw ArgumentError.value(bookUuid, 'bookUuid', '书 uuid 不能为空');
    }
    return BackupUnit._(BackupUnitKind.book, bookUuid);
  }

  /// 单元的稳定键：`library` / `mods` / `book:<uuid>`。
  String get unitKey => switch (kind) {
        BackupUnitKind.library => 'library',
        BackupUnitKind.mods => 'mods',
        BackupUnitKind.book => 'book:$refUuid',
      };

  /// 本地文件名（与 `user_data` 里的真实文件同名）。
  String get fileName => switch (kind) {
        BackupUnitKind.library => AppPaths.libraryDbFileName,
        BackupUnitKind.mods => AppPaths.modsDbFileName,
        BackupUnitKind.book => AppPaths.bookDbFileName(refUuid),
      };

  /// 云端命名用的基名（数据库原名去掉 `.db`）。
  String get baseName {
    final name = fileName;
    return name.endsWith('.db') ? name.substring(0, name.length - 3) : name;
  }

  /// 云端清单文件名：`manifest_<基名>.json`。
  String get manifestName => 'manifest_$baseName.json';

  /// 第 [generation] 代的云端快照名：`<基名>_shot-g<N>.db`。
  String snapshotName(int generation) => '${baseName}_shot-g$generation.db';

  /// 解析 [unitKey]；不认识的键返回 `null`（云端可能残留别的文件）。
  static BackupUnit? parseUnitKey(String unitKey) {
    if (unitKey == 'library') return library;
    if (unitKey == 'mods') return mods;
    const prefix = 'book:';
    if (unitKey.startsWith(prefix)) {
      final uuid = unitKey.substring(prefix.length);
      if (uuid.isEmpty) return null;
      try {
        AppPaths.bookDbFileName(uuid);
      } on ArgumentError {
        return null;
      }
      return book(uuid);
    }
    return null;
  }

  /// 从清单文件名反推单元键不可靠（基名与 unitKey 不同），因此解析走清单内容。
  bool get isBook => kind == BackupUnitKind.book;

  @override
  String toString() => unitKey;

  @override
  bool operator ==(Object other) =>
      other is BackupUnit && other.kind == kind && other.refUuid == refUuid;

  @override
  int get hashCode => Object.hash(kind, refUuid);
}

/// 单元 → 本地绝对路径。
///
/// 单独抽出来是为了让备份模块可以在临时目录里整跑（测试不碰真实用户目录）。
class BackupLocator {
  const BackupLocator({required this.userDataDir});

  final String userDataDir;

  /// 生产环境路径。
  static Future<BackupLocator> resolve() async {
    final root = await AppPaths.root();
    return BackupLocator(
      userDataDir: p.join(root.path, AppPaths.userDataDirName),
    );
  }

  String localPathOf(BackupUnit unit) => switch (unit.kind) {
        BackupUnitKind.library =>
          p.join(userDataDir, AppPaths.libraryDbFileName),
        BackupUnitKind.mods => p.join(userDataDir, AppPaths.modsDbFileName),
        BackupUnitKind.book => p.join(
            userDataDir,
            AppPaths.booksDirName,
            AppPaths.bookDbFileName(unit.refUuid),
          ),
      };

  /// 图片目录 `user_data/img`。
  String get imagesDir => p.join(userDataDir, AppPaths.imagesDirName);
}
