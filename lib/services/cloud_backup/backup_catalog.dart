import '../webdav_service.dart';
import 'backup_unit.dart';

/// 「一个库」在云端备份列表里的条目：库 + 该库的历代快照。
///
/// 顶层列表只显示它（Library 库 / Mod 库 / 书籍《书名》库），代次列表留在
/// 二级页，避免几十个快照平铺成一长串。
class BackupUnitEntry {
  const BackupUnitEntry({
    required this.unit,
    required this.snapshots,
    this.title = '',
  });

  final BackupUnit unit;

  /// 该库在云端的全部快照，**新 → 旧**。
  final List<WebDavFile> snapshots;

  /// 书名（library / mods 为空串；书可能因为本机没有这本书而为空）。
  final String title;

  /// 最新一代。
  WebDavFile get latest => snapshots.first;

  /// 最新一代的代数（快照名解析失败时为 -1）。
  int get latestGeneration => BackupUnit.generationOfSnapshotName(latest.name);

  /// 云端共有几代。
  int get totalCount => snapshots.length;

  /// 该库最后一次备份的时间（书籍排序键；可能为 null）。
  DateTime? get backedUpAt => latest.lastModified;

  /// 顶层列表与二级页共用的展示名。
  String get displayName => switch (unit.kind) {
        BackupUnitKind.library => 'Library 库',
        BackupUnitKind.mods => 'Mod 库',
        BackupUnitKind.book => '书籍《${_bookTitle()}》库',
      };

  /// 书名缺失时用 uuid 前 8 位兜底：至少能让用户区分"这是哪一本"。
  String _bookTitle() {
    if (title.isNotEmpty) return title;
    final uuid = unit.refUuid;
    if (uuid.isEmpty) return '未知书名';
    return uuid.length <= 8 ? uuid : uuid.substring(0, 8);
  }

  @override
  String toString() =>
      'BackupUnitEntry(${unit.unitKey}, ${snapshots.length} 代)';
}

/// 云端备份列表的目录：按库分组，纯排序，不做 I/O（单测友好）。
class BackupCatalog {
  BackupCatalog._();

  /// 从云端文件列表生成按库分组的目录。
  ///
  /// - 认不出的文件（清单 / 图片 / R2 旧快照）直接忽略；
  /// - 顺序固定：Library → Mod → 书籍；
  /// - 书籍按「最后备份时间」新的在前，时间缺失的垫底，同时间按 uuid 升序
  ///   （跨设备稳定，不依赖行序）。
  static List<BackupUnitEntry> build({
    required Iterable<WebDavFile> files,
    Map<String, String> bookTitles = const {},
  }) {
    final byUnit = <BackupUnit, List<WebDavFile>>{};
    for (final file in files) {
      final unit = BackupUnit.fromSnapshotName(file.name);
      if (unit == null) continue;
      byUnit.putIfAbsent(unit, () => <WebDavFile>[]).add(file);
    }
    final entries = <BackupUnitEntry>[
      for (final item in byUnit.entries)
        BackupUnitEntry(
          unit: item.key,
          snapshots: List<WebDavFile>.of(item.value)..sort(compareSnapshots),
          title: item.key.isBook ? (bookTitles[item.key.refUuid] ?? '') : '',
        ),
    ]..sort(_compareEntries);
    return entries;
  }

  /// 快照从新到旧：先按代数降序，再按名字倒序。
  static int compareSnapshots(WebDavFile a, WebDavFile b) {
    final ga = BackupUnit.generationOfSnapshotName(a.name);
    final gb = BackupUnit.generationOfSnapshotName(b.name);
    if (ga != gb) return gb.compareTo(ga);
    return b.name.compareTo(a.name);
  }

  static int _compareEntries(BackupUnitEntry a, BackupUnitEntry b) {
    final rankA = _rankOf(a.unit.kind);
    final rankB = _rankOf(b.unit.kind);
    if (rankA != rankB) return rankA.compareTo(rankB);
    if (a.unit.kind != BackupUnitKind.book) {
      return a.unit.unitKey.compareTo(b.unit.unitKey);
    }
    final ta = a.backedUpAt;
    final tb = b.backedUpAt;
    if (ta == null && tb == null) {
      return a.unit.refUuid.compareTo(b.unit.refUuid);
    }
    if (ta == null) return 1;
    if (tb == null) return -1;
    final byTime = tb.compareTo(ta);
    if (byTime != 0) return byTime;
    return a.unit.refUuid.compareTo(b.unit.refUuid);
  }

  static int _rankOf(BackupUnitKind kind) => switch (kind) {
        BackupUnitKind.library => 0,
        BackupUnitKind.mods => 1,
        BackupUnitKind.book => 2,
      };

  /// 云端时间展示：`2026-11-06 22:08`；没有时间给「时间未知」。
  static String formatTime(DateTime? time) {
    if (time == null) return '时间未知';
    final local = time.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  /// 文件大小展示：小于 1 MB 用 KB、其余用 MB；0 字节返回空串（大小未知不占位）。
  static String formatSize(int bytes) {
    if (bytes <= 0) return '';
    const kb = 1024;
    const mb = kb * 1024;
    if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
    return '${(bytes / kb).toStringAsFixed(1)} KB';
  }
}
