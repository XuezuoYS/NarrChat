import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../utils/timestamp_format.dart';
import 'backup_unit.dart';

/// 一个同步单元的内容指标。
///
/// 两个用途，**同一份口径**：
/// - 推送时写进云端清单（`latestRoundIndex` / `roundGenerationCount` /
///   `contentUpdatedAt`），供其它设备做冲突 PK；
/// - 冲突 PK 时作为本地一侧的取值，与云端清单里的同名字段对比。
///
/// 「代数」的口径固定为 `round_stack` 的行数（一行就是一代），与对话页的
/// 代次控件同源；书架没有代次与内容时间，这两项保持 0 / null。
class BackupUnitMetrics {
  const BackupUnitMetrics({
    this.roundGenerationCount = 0,
    this.latestRoundIndex = 0,
    this.updatedAt,
    this.itemCount = 0,
  });

  static const BackupUnitMetrics none = BackupUnitMetrics();

  /// 全书代数：`round_stack` 的行数（空书为 0）。
  final int roundGenerationCount;

  /// 最新轮号（空书为 0）。
  final int latestRoundIndex;

  /// 内容时间：书 = `book_meta.updated_at`；Mod 库 = 最近一次 Mod 修改时间；
  /// 书架没有这个概念，为 null（清单里回落到写入时间）。
  final DateTime? updatedAt;

  /// 条目数（Mod 数 / 书架活书数），只用于展示。
  final int itemCount;

  /// 是否有可用于 PK 的内容指标（书架恒为 false）。
  bool get hasRoundMetrics => roundGenerationCount > 0 || latestRoundIndex > 0;

  @override
  bool operator ==(Object other) =>
      other is BackupUnitMetrics &&
      other.roundGenerationCount == roundGenerationCount &&
      other.latestRoundIndex == latestRoundIndex &&
      other.updatedAt == updatedAt &&
      other.itemCount == itemCount;

  @override
  int get hashCode =>
      Object.hash(roundGenerationCount, latestRoundIndex, updatedAt, itemCount);

  @override
  String toString() =>
      'BackupUnitMetrics(代数 $roundGenerationCount, 轮次 $latestRoundIndex, '
      '时间 $updatedAt, 条目 $itemCount)';
}

/// 从一个**已打开**的库连接读内容指标（推送前的清单、冲突 PK、云端快照预览共用）。
///
/// 读的是只读聚合，不改任何数据；调用方负责连接生命周期（云备份执行器在算摘要
/// 时已经开过连接，这里复用同一条，不额外开库）。
class BackupMetricsReader {
  BackupMetricsReader._();

  static Future<BackupUnitMetrics> read(BackupUnit unit, DatabaseExecutor db) =>
      switch (unit.kind) {
        BackupUnitKind.library => _readLibrary(db),
        BackupUnitKind.mods => _readMods(db),
        BackupUnitKind.book => _readBook(db),
      };

  /// 书：`round_stack` 行数 + 最大轮号 + `book_meta.updated_at`。
  static Future<BackupUnitMetrics> _readBook(DatabaseExecutor db) async {
    final rounds = await db.rawQuery(
      'SELECT MAX("round_index") AS "latest", COUNT(*) AS "total" '
      'FROM "round_stack"',
    );
    final latest = _intOf(rounds, 'latest');
    final total = _intOf(rounds, 'total');
    final meta = await db.query(
      'book_meta',
      columns: const ['updated_at'],
      limit: 1,
    );
    return BackupUnitMetrics(
      roundGenerationCount: total,
      latestRoundIndex: latest,
      updatedAt: meta.isEmpty ? null : parseTimestamp(meta.first['updated_at']),
      itemCount: total,
    );
  }

  /// Mod 库：最近一次修改时间 + Mod 数。
  static Future<BackupUnitMetrics> _readMods(DatabaseExecutor db) async {
    final rows = await db.rawQuery(
      'SELECT MAX("updated_at") AS "latest", COUNT(*) AS "total" FROM "mods"',
    );
    final total = _intOf(rows, 'total');
    return BackupUnitMetrics(
      updatedAt: rows.isEmpty ? null : parseTimestamp(rows.first['latest']),
      itemCount: total,
    );
  }

  /// 书架：只有活书 / 墓碑数量，没有代次与内容时间。
  static Future<BackupUnitMetrics> _readLibrary(DatabaseExecutor db) async {
    final alive = await db.rawQuery(
      'SELECT COUNT(*) AS "total" FROM "books" WHERE "deleted_at" IS NULL',
    );
    return BackupUnitMetrics(itemCount: _intOf(alive, 'total'));
  }

  static int _intOf(List<Map<String, Object?>> rows, String column) {
    if (rows.isEmpty) return 0;
    return (rows.first[column] as num?)?.toInt() ?? 0;
  }
}
