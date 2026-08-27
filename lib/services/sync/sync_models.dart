import 'dart:convert';

/// 云同步模式。
///
/// - [auto]：登录 WebDAV 后默认全自动（启动/恢复时拉取远端非冲突变更、有变更时推送）；
/// - [manual]：半自动——仅通过「同步」按钮手动触发一遍 pull+push，不做后台主动同步。
enum SyncMode { auto, manual }

/// 同步总体状态（供 HUD 与同步状态章展示）。
enum SyncState { idle, syncing, success, error }

/// 同步阶段（用于前台 HUD 展示进度与步骤）。
enum SyncPhase {
  idle, // 未在同步
  acquireLock, // 获取云端软锁
  bootstrap, // 首次连接分支处理
  pullManifest, // 拉取 manifest
  pullSnapshot, // 下载快照
  merge, // 三向合并（计算/等待用户决策）
  applyLocal, // 应用合并到本地库
  pushSnapshot, // 上传新快照
  pushImages, // 上传缺失图片
  pullImages, // 下载缺失图片
  deleteImages, // 删除云端被墓碑/引用的图片
  pushManifest, // 提交 manifest
  updateCursor, // 更新本地同步游标
}

/// 同步进度事件（驱动前台 HUD）。
///
/// [currentItem]/[totalItems] 为当前阶段文件/条目数；[bytesDone]/[bytesTotal]
/// 为字节级进度（[bytesTotal] 可能为 null 表示未知，阶段为网络传输时才有）。
class SyncProgressEvent {
  final SyncPhase phase;
  final String label;

  /// 当前阶段内的条目序号（0 基）。
  final int currentItem;

  /// 当前阶段总条目数；0 表示未知。
  final int totalItems;
  final int bytesDone;
  final int? bytesTotal;

  const SyncProgressEvent({
    required this.phase,
    required this.label,
    this.currentItem = 0,
    this.totalItems = 0,
    this.bytesDone = 0,
    this.bytesTotal,
  });

  double? get fraction {
    if (totalItems > 0) return currentItem / totalItems;
    if (bytesTotal != null && bytesTotal! > 0) {
      return (bytesDone / bytesTotal!).clamp(0.0, 1.0);
    }
    return null;
  }
}

/// 云端 manifest 中一本书的部件级同步记录。
///
/// 部件：设置（单部件，含全部设置字段）、轮次（含失败条目）、世界书、书‑Mod。
/// 兼容：旧清单 `settingsFp` 单值直接使用；过渡期清单（子部件字段 infoFp 等）取
/// 首个非空子部件值（会触发一次重写后自愈）。
class SyncBookEntry {
  /// 跨设备同步身份（UUID）；format=1 旧清单缺省为空，由合并层按 title 回退。
  final String uuid;
  final String title;
  final bool deleted;

  /// 书籍设置（书名/分类/基础设定/文笔/前后置词/历史轮数/角色）。
  final String settingsFp;

  /// 轮次（含失败条目）。
  final String roundsFp;

  final int settingsUpdatedAt;
  final int roundsUpdatedAt;
  final String worldBookFp;
  final String bookModsFp;

  const SyncBookEntry({
    required this.title,
    this.uuid = '',
    required this.deleted,
    this.settingsFp = '',
    this.roundsFp = '',
    required this.settingsUpdatedAt,
    required this.roundsUpdatedAt,
    required this.worldBookFp,
    required this.bookModsFp,
  });

  Map<String, dynamic> toJson() => {
        'uuid': uuid,
        'title': title,
        'deleted': deleted,
        'settingsFp': settingsFp,
        'settingsUpdatedAt': settingsUpdatedAt,
        'roundsFp': roundsFp,
        'roundsUpdatedAt': roundsUpdatedAt,
        'worldBookFp': worldBookFp,
        'bookModsFp': bookModsFp,
      };

  factory SyncBookEntry.fromJson(Map<String, dynamic> j) {
    // 1) 单值 settingsFp；2) 过渡期子部件字段取首个非空（重写后自愈）。
    final single = j['settingsFp'] as String? ?? '';
    final legacy = single.isNotEmpty
        ? single
        : (j['infoFp'] as String? ?? '')
            .isNotEmpty
            ? j['infoFp'] as String
            : (j['rolesFp'] as String? ?? j['baseSettingFp'] as String? ??
                    j['promptsFp'] as String? ?? '');
    return SyncBookEntry(
      uuid: j['uuid'] as String? ?? '',
      title: j['title'] as String? ?? '',
      deleted: j['deleted'] as bool? ?? false,
      settingsFp: legacy,
      roundsFp: j['roundsFp'] as String? ?? '',
      settingsUpdatedAt: (j['settingsUpdatedAt'] as num?)?.toInt() ?? 0,
      roundsUpdatedAt: (j['roundsUpdatedAt'] as num?)?.toInt() ?? 0,
      worldBookFp: j['worldBookFp'] as String? ?? '',
      bookModsFp: j['bookModsFp'] as String? ?? '',
    );
  }
}

/// 云端 manifest 中一个 Mod 的同步记录。
class SyncModEntry {
  /// 跨设备同步身份（UUID）；format=1 旧清单缺省为空，由合并层按 name 回退。
  final String uuid;
  final String name;
  final bool deleted;
  final int updatedAt;
  final String fingerprint;

  const SyncModEntry({
    required this.name,
    this.uuid = '',
    required this.deleted,
    required this.updatedAt,
    required this.fingerprint,
  });

  Map<String, dynamic> toJson() => {
        'uuid': uuid,
        'name': name,
        'deleted': deleted,
        'updatedAt': updatedAt,
        'fingerprint': fingerprint,
      };

  factory SyncModEntry.fromJson(Map<String, dynamic> j) => SyncModEntry(
        uuid: j['uuid'] as String? ?? '',
        name: j['name'] as String? ?? '',
        deleted: j['deleted'] as bool? ?? false,
        updatedAt: (j['updatedAt'] as num?)?.toInt() ?? 0,
        fingerprint: j['fingerprint'] as String? ?? '',
      );
}

/// 云端索引（manifest）：增量计算与并发控制的唯一基准。
///
/// `format`：1 = 无 uuid（旧版/未发布格式）；2 = uuid 身份（现版本）。
///
/// 图片删除不再进 manifest：独立为 WebDAV 墓碑文件（`img_tombstones.json`），
/// 见 `img_tombstones.dart`——manifest 只承载书籍 / Mod / 图片引用集合。
class SyncManifest {
  final int format;
  final int generation;
  final String lastWriterDeviceId;
  final List<String> knownDevices;
  final List<SyncBookEntry> books;
  final List<SyncModEntry> mods;

  /// 云端当前应存在的图片（内容寻址路径集合）。
  final List<String> images;

  const SyncManifest({
    this.format = 2,
    this.generation = 0,
    this.lastWriterDeviceId = '',
    this.knownDevices = const [],
    this.books = const [],
    this.mods = const [],
    this.images = const [],
  });

  /// 通过 WebDAV 下载后解析；空/非法 JSON 返回 null 便于调用方判断"云端为空"。
  static SyncManifest? tryParse(String? json) {
    if (json == null || json.trim().isEmpty) return null;
    try {
      final j = jsonDecode(json);
      if (j is! Map<String, dynamic>) return null;
      return SyncManifest.fromJson(j);
    } catch (_) {
      return null;
    }
  }

  factory SyncManifest.fromJson(Map<String, dynamic> j) => SyncManifest(
        format: (j['format'] as num?)?.toInt() ?? 1,
        generation: (j['generation'] as num?)?.toInt() ?? 0,
        lastWriterDeviceId: j['lastWriterDeviceId'] as String? ?? '',
        knownDevices: ((j['knownDevices'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
        books: ((j['books'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(SyncBookEntry.fromJson)
            .toList(),
        mods: ((j['mods'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(SyncModEntry.fromJson)
            .toList(),
        images: ((j['images'] as List?) ?? const []).map((e) => e.toString()).toList(),
      );

  String toJsonString() => jsonEncode(toJson());

  Map<String, dynamic> toJson() => {
        'format': format,
        'generation': generation,
        'lastWriterDeviceId': lastWriterDeviceId,
        'knownDevices': knownDevices,
        'books': books.map((b) => b.toJson()).toList(),
        'mods': mods.map((m) => m.toJson()).toList(),
        'images': images,
      };
}
