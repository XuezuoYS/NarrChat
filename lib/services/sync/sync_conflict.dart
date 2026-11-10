import '../../utils/timestamp_format.dart';
import '../cloud_backup/backup_pk.dart';
import '../cloud_backup/backup_planner.dart';
import '../cloud_backup/backup_runner.dart';
import '../cloud_backup/backup_unit.dart';

/// 冲突项来自哪一侧（预览请求用）。
enum SyncPreviewSide { local, remote }

extension SyncPreviewSideLabel on SyncPreviewSide {
  /// 侧名：左本地、右云端（导入端）。
  String get label => switch (this) {
    SyncPreviewSide.local => '本地',
    SyncPreviewSide.remote => '云端（导入端）',
  };
}

/// 同步冲突的**不可变快照**。
///
/// 由 `CloudSyncProvider` 在数据面跑的过程中生成：`plan` 是备份决策（本地摘要 +
/// 云端清单 + 共基），`pk` 是三轴比较结果。UI 只读它，不碰 I/O。
class SyncConflict {
  const SyncConflict({
    required this.unit,
    required this.plan,
    required this.pk,
    required this.title,
    this.note = '',
  });

  final BackupUnit unit;
  final BackupPlan plan;
  final SyncPkResult pk;

  /// 展示名：`书籍《书名》` / `Mod 库` / `书架（Library 库）`。
  final String title;

  /// 额外说明（自动合并失败的原因等），空串表示没有。
  final String note;

  BackupUnitKind get kind => unit.kind;
  bool get isBook => unit.kind == BackupUnitKind.book;
  bool get isLibrary => unit.kind == BackupUnitKind.library;

  /// 单元类别短名（卡片角标）。
  String get kindLabel => switch (unit.kind) {
    BackupUnitKind.book => '书籍',
    BackupUnitKind.mods => 'Mod 库',
    BackupUnitKind.library => '书架',
  };

  /// 云端这一代的代数（清单里的 `generation`，0 = 未知）。
  int get remoteGeneration => plan.remote?.generation ?? 0;

  /// 云端这一代的写入时间。
  DateTime? get remoteSavedAt => parseTimestamp(plan.remote?.savedAt);

  /// 推送这一代的设备标识。
  String get remoteDeviceId => plan.remote?.deviceId ?? '';

  /// 设备标识短名（展示 8 位）。
  String get remoteDeviceShort {
    final id = remoteDeviceId;
    if (id.isEmpty) return '未知设备';
    return id.length <= 8 ? id : id.substring(0, 8);
  }

  /// 「云端第 N 代」文案。
  String get remoteGenerationLabel =>
      remoteGeneration > 0 ? '第 $remoteGeneration 代' : '代次未知';

  /// 冲突原因的简短说明（给页面副标题用）。
  String get reasonLabel {
    if (note.isNotEmpty) return note;
    return switch (unit.kind) {
      BackupUnitKind.book => '这本书本地与云端都改过，且 PK 无法判定哪边更新',
      BackupUnitKind.mods => 'Mod 库本地与云端都改过，且无法判断哪边更新',
      BackupUnitKind.library => '书架本地与云端都改过，无法自动合并',
    };
  }

  SyncConflict withPk(SyncPkResult value) =>
      SyncConflict(unit: unit, plan: plan, pk: value, title: title, note: note);

  SyncConflict withNote(String value) =>
      SyncConflict(unit: unit, plan: plan, pk: pk, title: title, note: value);
}

/// 用户在冲突页对某一项的选择（`skip` = 稍后处理）。
class SyncConflictDecision {
  const SyncConflictDecision({required this.conflict, required this.choice});

  final SyncConflict conflict;
  final BackupConflictChoice choice;

  bool get isSkip => choice == BackupConflictChoice.skip;
}

/// 批量应用冲突决策的结果。
class SyncConflictApplyReport {
  const SyncConflictApplyReport({
    this.localApplied = 0,
    this.remoteApplied = 0,
    this.skipped = 0,
    this.errors = const {},
    this.restored = false,
  });

  /// 保留本地（推成云端新一代）的项数。
  final int localApplied;

  /// 采用云端（整份替换本地）的项数。
  final int remoteApplied;

  /// 稍后处理（保持冲突）的项数。
  final int skipped;

  /// 失败明细：`unitKey → 原因`。
  final Map<String, String> errors;

  /// 是否因为采用云端而重载了本地数据。
  final bool restored;

  bool get hasErrors => errors.isNotEmpty;
  bool get isEmpty =>
      localApplied == 0 && remoteApplied == 0 && skipped == 0 && !hasErrors;

  /// 成功处理的总项数（不含稍后处理）。
  int get applied => localApplied + remoteApplied;

  /// 结果提示文案（页面 / 驻场岛共用）。
  String get summary {
    final parts = <String>[
      if (remoteApplied > 0) '采用云端 $remoteApplied 项',
      if (localApplied > 0) '保留本地 $localApplied 项',
      if (skipped > 0) '稍后处理 $skipped 项',
    ];
    if (parts.isEmpty) return '没有应用任何决策';
    return '${parts.join('，')}${hasErrors ? '，${errors.length} 项失败' : ''}';
  }
}

/// 同步过程中弹出的三选一对话框的结果。
enum SyncConflictPromptResult {
  /// 暂停本次同步，并把同步模式改成手动。
  pause,

  /// 本次冲突全部采用云端备份。
  adoptRemote,

  /// 进入冲突决策页逐项选择。
  decide,
}

// ---------------------------------------------------------------------------
// 预览数据（页面按需加载，不参与 PK）
// ---------------------------------------------------------------------------

/// 书籍单侧预览。
class BookSidePreview {
  const BookSidePreview({
    this.title = '',
    this.category = '',
    this.baseSetting = '',
    this.writingRequirements = '',
    this.writingStyle = '',
    this.globalPrePrompt = '',
    this.globalPostPrompt = '',
    this.historyRounds = 0,
    this.memorySummaryRounds = 0,
    this.roleHierarchy = '',
    this.worldBookCount = 0,
    this.worldBookKeywords = const [],
    this.modNames = const [],
    this.roundGenerationCount = 0,
    this.latestRoundIndex = 0,
    this.latestRoundAt,
    this.latestUserInput = '',
    this.latestNarrative = '',
  });

  final String title;
  final String category;
  final String baseSetting;
  final String writingRequirements;
  final String writingStyle;
  final String globalPrePrompt;
  final String globalPostPrompt;
  final int historyRounds;
  final int memorySummaryRounds;
  final String roleHierarchy;
  final int worldBookCount;
  final List<String> worldBookKeywords;
  final List<String> modNames;
  final int roundGenerationCount;
  final int latestRoundIndex;
  final DateTime? latestRoundAt;
  final String latestUserInput;
  final String latestNarrative;
}

/// Mod 单条预览。
class ModEntryPreview {
  const ModEntryPreview({
    this.uuid = '',
    this.name = '',
    this.description = '',
    this.prePrompt = '',
    this.postPrompt = '',
    this.systemPrompt = '',
    this.worldBookCount = 0,
    this.updatedAt,
    this.deleted = false,
  });

  final String uuid;
  final String name;
  final String description;
  final String prePrompt;
  final String postPrompt;
  final String systemPrompt;
  final int worldBookCount;
  final DateTime? updatedAt;
  final bool deleted;

  /// uuid 前 8 位（同名 Mod 靠它区分）。
  String get uuidShort => uuid.length <= 8 ? uuid : uuid.substring(0, 8);
}

/// Mod 库单侧预览。
class ModsSidePreview {
  const ModsSidePreview({this.mods = const []});

  final List<ModEntryPreview> mods;

  int get aliveCount => mods.where((mod) => !mod.deleted).length;
}

/// 书架上的一本书（预览用）。
class LibraryBookPreview {
  const LibraryBookPreview({
    required this.bookUuid,
    this.title = '',
    this.deletedAt,
    this.deletedRoundIndex,
  });

  final String bookUuid;
  final String title;
  final DateTime? deletedAt;
  final int? deletedRoundIndex;

  bool get isDeleted => deletedAt != null;

  /// uuid 前 8 位。
  String get uuidShort =>
      bookUuid.length <= 8 ? bookUuid : bookUuid.substring(0, 8);
}

/// 书架单侧预览。
class LibrarySidePreview {
  const LibrarySidePreview({this.alive = const [], this.deleted = const []});

  final List<LibraryBookPreview> alive;
  final List<LibraryBookPreview> deleted;
}

/// 一侧的预览数据（书 / Mod 库 / 书架三选一，其余为 null）。
class SyncSidePreview {
  const SyncSidePreview({
    required this.side,
    this.book,
    this.mods,
    this.library,
  });

  final SyncPreviewSide side;
  final BookSidePreview? book;
  final ModsSidePreview? mods;
  final LibrarySidePreview? library;
}
