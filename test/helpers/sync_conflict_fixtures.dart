import 'package:narrchat/services/cloud_backup/backup_manifest.dart';
import 'package:narrchat/services/cloud_backup/backup_metrics.dart';
import 'package:narrchat/services/cloud_backup/backup_pk.dart';
import 'package:narrchat/services/cloud_backup/backup_planner.dart';
import 'package:narrchat/services/cloud_backup/backup_unit.dart';
import 'package:narrchat/services/sync/sync_conflict.dart';
import 'package:narrchat/utils/timestamp_format.dart';

/// 冲突相关 widget 测试共用的「纯内存」构造器（不连库、不联网）。
///
/// 只在本测试目录使用；生产代码一律由 `CloudSyncProvider` 现场构造。
SyncConflict buildBookConflict({
  String uuid = 'b1',
  String title = '测试书',
  int localLatestRound = 3,
  int localGenerationCount = 4,
  DateTime? localUpdatedAt,
  int remoteLatestRound = 2,
  int remoteGenerationCount = 6,
  DateTime? remoteUpdatedAt,
  int remoteGeneration = 4,
  String remoteDeviceId = 'device-abcdef12',
}) {
  final unit = BackupUnit.book(uuid);
  final manifest = BackupManifest(
    unitKey: unit.unitKey,
    kind: unit.kind,
    refUuid: uuid,
    generation: remoteGeneration,
    digest: 'remote-digest',
    snapshotName: unit.snapshotName(remoteGeneration),
    savedAt: '2026-01-02T00:00:00.000Z',
    deviceId: remoteDeviceId,
    contentUpdatedAt: formatTimestamp(
      remoteUpdatedAt ?? DateTime.utc(2026, 1, 1),
    ),
    latestRoundIndex: remoteLatestRound,
    roundGenerationCount: remoteGenerationCount,
  );
  final plan = BackupPlanner.plan(
    unit: unit,
    localDigest: 'local-digest',
    base: const BackupBase(generation: 3, baseDigest: 'base-digest'),
    remote: manifest,
  );
  final metrics = BackupUnitMetrics(
    latestRoundIndex: localLatestRound,
    roundGenerationCount: localGenerationCount,
    updatedAt: localUpdatedAt ?? DateTime.utc(2026, 3, 1),
  );
  return SyncConflict(
    unit: unit,
    plan: plan,
    pk: BackupPk.decideBook(local: metrics, remote: manifest),
    title: '书籍《$title》',
  );
}

SyncConflict buildModsConflict({String remoteDeviceId = 'device-abcdef12'}) {
  final unit = BackupUnit.mods;
  final manifest = BackupManifest(
    unitKey: unit.unitKey,
    kind: unit.kind,
    refUuid: '',
    generation: 2,
    digest: 'remote-mods',
    snapshotName: unit.snapshotName(2),
    savedAt: '2026-01-02T00:00:00.000Z',
    deviceId: remoteDeviceId,
  );
  final plan = BackupPlanner.plan(
    unit: unit,
    localDigest: 'local-mods',
    base: const BackupBase(generation: 1, baseDigest: 'base-mods'),
    remote: manifest,
  );
  return SyncConflict(
    unit: unit,
    plan: plan,
    pk: BackupPk.decideMods(
      local: BackupUnitMetrics(updatedAt: DateTime.utc(2026, 3, 1)),
      remote: manifest,
    ),
    title: 'Mod 库',
  );
}

SyncConflict buildLibraryConflict() {
  const unit = BackupUnit.library;
  final manifest = BackupManifest(
    unitKey: unit.unitKey,
    kind: unit.kind,
    refUuid: '',
    generation: 4,
    digest: 'remote-library',
    snapshotName: unit.snapshotName(4),
    savedAt: '2026-01-02T00:00:00.000Z',
    deviceId: 'device-abcdef12',
  );
  final plan = BackupPlanner.plan(
    unit: unit,
    localDigest: 'local-library',
    base: const BackupBase(generation: 3, baseDigest: 'base-library'),
    remote: manifest,
  );
  return SyncConflict(
    unit: unit,
    plan: plan,
    pk: const SyncPkResult.unavailable('书架无法自动合并，请选择保留哪一侧。'),
    title: '书架（Library 库）',
    note: '两侧书架的全局身份不一致，不能自动合并',
  );
}

/// 模拟页面侧的预览返回数据。
SyncSidePreview buildPreview(SyncPreviewSide side) {
  final isLocal = side == SyncPreviewSide.local;
  return SyncSidePreview(
    side: side,
    book: BookSidePreview(
      title: isLocal ? '本地书名' : '云端书名',
      category: '奇幻',
      baseSetting: isLocal ? '本地基础设定' : '云端基础设定',
      writingRequirements: '文笔要求',
      historyRounds: isLocal ? 3 : 5,
      worldBookCount: isLocal ? 2 : 3,
      roundGenerationCount: isLocal ? 4 : 6,
      latestRoundIndex: isLocal ? 3 : 2,
      latestUserInput: isLocal ? '本地用户输入' : '云端用户输入',
      latestNarrative: isLocal ? '本地正文' : '云端正文',
      modNames: const ['预设 Mod', '自定义 Mod'],
    ),
  );
}
