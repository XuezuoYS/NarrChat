import 'dart:async';
import 'dart:typed_data';

import 'package:narrchat/database/book_dao.dart';
import 'package:narrchat/database/mod_dao.dart';
import 'package:narrchat/database/round_dao.dart';
import 'package:narrchat/database/world_book_dao.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/failed_attempt.dart';
import 'package:narrchat/models/mod.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/models/world_book_entry.dart';
import 'package:narrchat/services/ai_service.dart';
import 'package:narrchat/services/clipboard_paste_service.dart';
import 'package:narrchat/services/debug_database_service.dart';
import 'package:narrchat/services/image_import_service.dart';
import 'package:narrchat/services/notification_service.dart';
import 'package:narrchat/services/storage_service.dart';
import 'package:narrchat/services/sync/image_deletion.dart';
import 'package:narrchat/services/sync/image_revival.dart';
import 'package:narrchat/services/sync/img_tombstones.dart';
import 'package:narrchat/services/sync/sync_models.dart';
import 'package:narrchat/services/sync/sync_remote_store.dart';
import 'package:narrchat/services/taskbar_attention_backend.dart';
import 'package:narrchat/database/sync_dao.dart';
import 'package:path/path.dart' as p;

/// 公共测试替身（Fakes）。
///
/// 用途：多个测试文件此前各自复制一份 `_MockBookDao` / `_MockRoundDao` 等
/// 替身类（累计约 1000 行），且实现细节互相漂移。统一收口到本文件后：
/// - 所有 `getAllBooks` 均已覆写，彻底切断真实 DatabaseHelper / path_provider
///   初始化链（此前部分文件漏覆写，会“碰巧通过”）；
/// - 新增测试直接复用，不再复制。
///
/// 约定：本文件不包含任何 widget 脚手架（见 chat_harness.dart），
/// 仅包含“数据/服务层”替身。

/// 可控图片复活替身：记录调用与路径，默认不复活（返回 false）。
class FakeImageRevivalService implements ImageRevivalService {
  final List<String> revived = [];
  int calls = 0;
  bool result = false;

  @override
  Future<bool> revive(String path) async {
    calls++;
    revived.add(path);
    return result;
  }
}

/// 内存版 [BookDao]：可注入书籍列表与最近对话时间，记录失败条目。
///
/// 身份一律为 uuid（书籍主键）；`insertBook` 对空 uuid 补发身份并回写列表，
/// 与真实实现同语义，测试不触碰真实数据库。
class FakeBookDao extends BookDao {
  FakeBookDao({List<Book> books = const [], this.times = const {}})
      : books = List.of(books);

  final List<Book> books;

  /// 「最近对话时间」映射（键 = 书籍 uuid）。
  final Map<String, DateTime> times;
  FailedAttempt failed = const FailedAttempt();

  /// 每次 insertBook 分配的 uuid（可预置队列；耗尽则按序号自动生成）。
  final List<String> uuidQueue = [];
  int _insertSeq = 0;

  @override
  Future<List<Book>> getAllBooks({bool includeDeleted = false}) async =>
      List.of(books);

  @override
  Future<Book?> getBookByUuid(
    String uuid, {
    bool includeDeleted = false,
  }) async {
    if (uuid.isEmpty) return null;
    for (final b in books) {
      if (b.uuid == uuid) return b;
    }
    return null;
  }

  /// 软删：从内存列表移除（等价于真实实现中 `deleted_at` 墓碑被过滤）。
  @override
  Future<void> softDeleteBook(String uuid) async {
    books.removeWhere((b) => b.uuid == uuid);
  }

  @override
  Future<Map<String, DateTime>> getLastRoundTimes() async => times;

  @override
  Future<String> insertBook(Book book) async {
    final uuid = uuidQueue.isNotEmpty
        ? uuidQueue.removeAt(0)
        : ((book.uuid.isNotEmpty) ? book.uuid : 'book-${++_insertSeq}');
    final stored = book.uuid.isEmpty && uuid != book.uuid
        ? book.copyWith(uuid: uuid)
        : book;
    if (!books.any((b) => b.uuid == stored.uuid)) books.add(stored);
    return stored.uuid;
  }

  @override
  Future<int> updateBook(Book book) async {
    final index = books.indexWhere((b) => b.uuid == book.uuid);
    if (index < 0) return 0;
    books[index] = book;
    return 1;
  }

  @override
  Future<FailedAttempt> getFailedAttempt(String bookUuid) async => failed;

  @override
  Future<void> setFailedAttempt(String bookUuid, FailedAttempt attempt) async {
    failed = attempt;
  }
}

/// 内存版 [RoundDao]：轮次按 bookUuid 过滤、insert 分配递增 id（轮次自身主键）、
/// delete 支持“仅本轮 / 后续全部”两种语义（与真实实现一致）。
class FakeRoundDao extends RoundDao {
  final List<Round> rounds = [];
  int _nextId = 1;

  @override
  Future<List<Round>> getRoundsByBook(String bookUuid) async =>
      List.of(rounds.where((r) => r.bookUuid == bookUuid));

  @override
  Future<int> insertRound(Round round) async {
    final created = Round(
      id: _nextId++,
      bookUuid: round.bookUuid,
      roundIndex: round.roundIndex,
      userInput: round.userInput,
      aiNarrative: round.aiNarrative,
      worldState: round.worldState,
      characterState: round.characterState,
      memorySummary: round.memorySummary,
      currentTime: round.currentTime,
      recommendedAction: round.recommendedAction,
      tokensIn: round.tokensIn,
      tokensOut: round.tokensOut,
      modelName: round.modelName,
      createdAt: round.createdAt,
      userImages: List.of(round.userImages),
      aiImages: List.of(round.aiImages),
    );
    rounds.add(created);
    return created.id!;
  }

  @override
  Future<int> updateRoundFields(
    int roundId,
    Map<String, Object?> fields,
  ) async {
    final index = rounds.indexWhere((r) => r.id == roundId);
    if (index < 0) return 0;
    final updated = Round(
      id: roundId,
      bookUuid: rounds[index].bookUuid,
      roundIndex: rounds[index].roundIndex,
      userInput: (fields['user_input'] as String?) ?? rounds[index].userInput,
      aiNarrative: (fields['ai_narrative'] as String?) ??
          rounds[index].aiNarrative,
      worldState: (fields['world_state'] as String?) ??
          rounds[index].worldState,
      characterState: (fields['character_state'] as String?) ??
          rounds[index].characterState,
      memorySummary: (fields['memory_summary'] as String?) ??
          rounds[index].memorySummary,
      currentTime: (fields['current_time'] as String?) ??
          rounds[index].currentTime,
      recommendedAction: rounds[index].recommendedAction,
      tokensIn: rounds[index].tokensIn,
      tokensOut: rounds[index].tokensOut,
      modelName: rounds[index].modelName,
      createdAt: rounds[index].createdAt,
      userImages: rounds[index].userImages,
      aiImages: rounds[index].aiImages,
    );
    rounds[index] = updated;
    return 1;
  }

  @override
  Future<void> deleteRound(int roundId, {bool deleteFollowing = false}) async {
    Round? target;
    for (final r in rounds) {
      if (r.id == roundId) {
        target = r;
        break;
      }
    }
    if (target == null) return;
    if (deleteFollowing) {
      rounds.removeWhere(
        (r) =>
            r.bookUuid == target!.bookUuid &&
            r.roundIndex >= target.roundIndex,
      );
    } else {
      rounds.removeWhere((r) => r.id == roundId);
    }
  }
}

/// 内存版 [WorldBookDao]：默认返回空条目。
class FakeWorldBookDao extends WorldBookDao {
  @override
  Future<List<WorldBookEntry>> getEntriesByBook(String bookUuid) async => [];
}

/// 内存版 [ModDao]：Mod 主键即 uuid（无 int id），书-Mod 配置按 bookUuid 分桶。
class FakeModDao extends ModDao {
  FakeModDao({List<Mod> mods = const []}) : mods = List.of(mods);

  final List<Mod> mods;

  /// 书籍挂载：键 = 书籍 uuid。
  final Map<String, List<BookModConfig>> bookMods = {};

  int _insertSeq = 0;

  @override
  Future<List<Mod>> getAllMods() async => List.of(mods);

  @override
  Future<Mod?> getModByUuid(String uuid) async {
    if (uuid.isEmpty) return null;
    for (final m in mods) {
      if (m.uuid == uuid) return m;
    }
    return null;
  }

  @override
  Future<String> insertMod(Mod mod) async {
    final uuid = mod.uuid.isNotEmpty ? mod.uuid : 'mod-${++_insertSeq}';
    final stored = mod.uuid == uuid ? mod : mod.copyWith(uuid: uuid);
    if (!mods.any((m) => m.uuid == stored.uuid)) mods.add(stored);
    return stored.uuid;
  }

  @override
  Future<int> updateMod(Mod mod) async {
    final index = mods.indexWhere((m) => m.uuid == mod.uuid);
    if (index < 0) return 0;
    mods[index] = mod;
    return 1;
  }

  @override
  Future<void> deleteMod(String uuid) async {
    mods.removeWhere((m) => m.uuid == uuid);
    bookMods.updateAll(
      (key, list) => list.where((c) => c.modUuid != uuid).toList(),
    );
  }

  @override
  Future<List<BookModConfig>> getBookMods(String bookUuid) async =>
      List.of(bookMods[bookUuid] ?? const []);

  @override
  Future<void> replaceBookMods(
    String bookUuid,
    List<BookModConfig> configs,
  ) async {
    bookMods[bookUuid] = List.of(configs);
  }
}

/// 可控流式 AI：测试驱动 [emit] / [emitReasoning] / [complete]，
/// 模拟逐 chunk 输出与生成结束；complete 后若已取消则抛
/// [AiCancelledException]（对应真实流式路径）。
class FakeStreamingAiService extends AiService {
  final Completer<void> _done = Completer<void>();
  void Function(AiStreamChunk chunk)? _onChunk;

  /// 向流式回调推送一个正文增量。
  void emit(String delta) => _onChunk?.call(AiStreamChunk(contentDelta: delta));

  /// 向流式回调推送一个思考增量。
  void emitReasoning(String delta) =>
      _onChunk?.call(AiStreamChunk(reasoningDelta: delta));

  /// 结束流式并返回完整结果。
  void complete() => _done.complete();

  @override
  Future<AiCallResult> chat({
    required String apiBaseUrl,
    required String apiKey,
    required Map<String, dynamic> requestBody,
    bool stream = false,
    void Function(AiStreamChunk chunk)? onChunk,
    void Function(String requestBody)? onRequestBody,
    bool Function()? isCancelled,
  }) async {
    _onChunk = onChunk;
    onRequestBody?.call('{"model":"test","messages":[]}');
    await _done.future;
    if (isCancelled?.call() ?? false) {
      throw const AiCancelledException();
    }
    _onChunk?.call(const AiStreamChunk(done: true));
    return const AiCallResult(
      content: '## 剧情演绎\n流式生成的最终正文\n'
          '## 推荐行动\n\n'
          '## 当前时间\n第一天 午时\n'
          '## 世界状态\n\n'
          '## 角色状态\n\n'
          '## 记忆总结\n',
      promptTokens: 10,
      completionTokens: 20,
    );
  }
}

/// 可立即返回的 AI（成功 / 可切换失败），用于不依赖流式时序的用例。
class ToggleAiService extends AiService {
  bool fail = false;

  @override
  Future<AiCallResult> chat({
    required String apiBaseUrl,
    required String apiKey,
    required Map<String, dynamic> requestBody,
    bool stream = false,
    void Function(AiStreamChunk chunk)? onChunk,
    void Function(String requestBody)? onRequestBody,
    bool Function()? isCancelled,
  }) async {
    onRequestBody?.call('{"model":"test","messages":[]}');
    if (fail) throw const AiException('模拟失败');
    return const AiCallResult(
      content: '## 剧情演绎\n成功正文\n'
          '## 推荐行动\n\n'
          '## 当前时间\n第一天 午时\n'
          '## 世界状态\n\n'
          '## 角色状态\n\n'
          '## 记忆总结\n',
      promptTokens: 1,
      completionTokens: 1,
    );
  }
}

/// 记录调用并可由测试手动触发点击的假通知后端。
class FakeNotificationBackend implements NotificationBackend {
  FakeNotificationBackend({this.notificationsEnabled, this.launchPayload});

  final List<({int id, String title, String body, String payload})> shown = [];
  final List<int> cancelled = [];
  final List<int> startedForeground = [];
  int stopForegroundCount = 0;
  void Function(String bookUuid)? onTap;

  /// 是否允许通知（null = 非 Android / 未知）。
  bool? notificationsEnabled;

  /// 冷启动点通知的书籍 uuid（null = 非冷启动）。
  String? launchPayload;

  @override
  Future<void> init({required void Function(String bookUuid) onTap}) async {
    this.onTap = onTap;
  }

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    required String payload,
  }) async {
    shown.add((id: id, title: title, body: body, payload: payload));
  }

  @override
  Future<void> cancel(int id) async => cancelled.add(id);

  @override
  Future<String?> launchNotificationPayload() async => launchPayload;

  @override
  Future<bool?> areNotificationsEnabled() async => notificationsEnabled;

  @override
  Future<void> openNotificationSettings() async {}

  @override
  Future<void> startForeground({
    required int id,
    required String title,
    required String body,
  }) async {
    startedForeground.add(id);
  }

  @override
  Future<void> stopForeground() async {
    stopForegroundCount++;
  }

  /// 模拟用户点击通知（参数 = 通知 payload 里的书籍 uuid）。
  void tap(String bookUuid) => onTap?.call(bookUuid);
}

/// 记录闪烁调用次数的假任务栏闪烁后端。
class FakeTaskbarAttentionBackend implements TaskbarAttentionBackend {
  int startCount = 0;
  int stopCount = 0;

  @override
  Future<void> start() async {
    startCount++;
  }

  @override
  Future<void> stop() async {
    stopCount++;
  }
}

/// 可控图片导入替身：按 [results] 顺序返回结果，并记录调用次数与参数。
class FakeImageImportService implements ImageImportService {
  FakeImageImportService({this.results = const []});

  /// 每次调用返回的结果（按序读取；耗尽后返回空结果）。不做突变，兼容只读列表。
  List<ImageImportResult> results;
  int calls = 0;
  int? lastSizeLimitMb;
  bool? lastConvertJpgToJpeg;
  int _next = 0;

  @override
  Future<ImageImportResult> importImages({
    required int sizeLimitMb,
    bool convertJpgToJpeg = false,
    void Function(int done, int total)? onProgress,
  }) async {
    calls++;
    lastSizeLimitMb = sizeLimitMb;
    lastConvertJpgToJpeg = convertJpgToJpeg;
    if (_next >= results.length) return const ImageImportResult();
    return results[_next++];
  }
}

/// 可控剪贴板替身：按 [text] / [imagePng] 返回文本与图片（PNG 字节）。
///
/// - [imagePng] 非空：表示剪贴板含图片，[readImagePng] 返回固定的
///   `img/pasted.png`（无需真实落盘，避免触碰真实文件系统）；
/// - [imageWarning] 非空：优先返回超限/失败提示（模拟「读图成功但被拒」）。
class FakeClipboardPasteService implements ClipboardPasteService {
  FakeClipboardPasteService({this.text, this.imagePng, this.imageWarning});

  String? text;
  Uint8List? imagePng;
  String? imageWarning;

  @override
  Future<String?> readText() async => text;

  @override
  Future<bool> hasImage() async => imagePng != null || imageWarning != null;

  @override
  Future<ClipboardImageResult> readImagePng({
    required int sizeLimitMb,
    required bool convertJpgToJpeg,
  }) async {
    if (imageWarning != null) {
      return ClipboardImageResult(warning: imageWarning);
    }
    if (imagePng == null) return const ClipboardImageResult();
    return const ClipboardImageResult(relPath: 'img/pasted.png');
  }
}

/// 可控存储管理替身：返回预设数据并记录导出调用。
class FakeStorageService implements StorageService {
  FakeStorageService({this.db, this.images = const []});

  StorageDbInfo? db;
  List<StorageImageInfo> images;
  int deleteCalls = 0;
  List<String> deleted = [];
  String? exportedTo;
  String? exportedName;
  List<String>? exportedImages;
  String? exportedImagesTo;

  @override
  Future<StorageDbInfo?> dbInfo() async => db;

  @override
  Future<List<StorageImageInfo>> listImages() async => List.of(images);

  @override
  Future<String> exportDatabase({
    required String targetDirPath,
    required String fileName,
  }) async {
    exportedTo = targetDirPath;
    exportedName = fileName;
    return p.join(targetDirPath, fileName);
  }

  @override
  Future<int> exportImages({
    required List<String> relPaths,
    required String targetDirPath,
  }) async {
    exportedImages = List.of(relPaths);
    exportedImagesTo = targetDirPath;
    return relPaths.length;
  }
}

/// 可控图片删除服务：记录删除路径，可注入 [onDelete] 模拟删除后的副作用。
class FakeImageDeletionService implements ImageDeletionService {
  FakeImageDeletionService({this.onDelete});

  /// 删除后的回调（如从图片列表移除，供列表刷新断言）。
  Future<void> Function(String relPath)? onDelete;

  final List<String> deleted = [];
  int calls = 0;

  @override
  Future<void> delete(String relPath) async {
    calls++;
    deleted.add(relPath);
    await onDelete?.call(relPath);
  }
}

/// 内存版 [DebugDatabaseService]：按 [pageBuilder] 生成每页数据，
/// 记录最近一次调用的页参数，供「数据库结构」页测试校验翻页。
class FakeDebugDatabaseService implements DebugDatabaseService {
  FakeDebugDatabaseService({this.tables = const [], this.pageBuilder});

  final List<DebugTableSummary> tables;

  /// 按 `(name, page, pageSize)` 生成一页数据；为 null 时返回空页。
  final DebugTablePage Function(String name, int page, int pageSize)? pageBuilder;

  int loadCount = 0;
  String? lastName;
  int? lastPage;
  int? lastPageSize;

  @override
  Future<List<DebugTableSummary>> listTables() async => tables;

  @override
  Future<DebugTablePage> loadTable(
    String tableName, {
    int page = 0,
    int pageSize = 20,
  }) async {
    loadCount++;
    lastName = tableName;
    lastPage = page;
    lastPageSize = pageSize;
    final builder = pageBuilder;
    if (builder != null) return builder(tableName, page, pageSize);
    return DebugTablePage(
      name: tableName,
      columns: const [],
      indexes: const [],
      rows: const [],
      totalCount: 0,
      page: page,
      pageSize: pageSize,
    );
  }
}

/// 内存版云端同步存储（manifest / 快照 / 图片 / 墓碑文件 / 软锁），供同步测试复用。
///
/// 锁默认"可获取"（可注入持锁设备 id 模拟并发占用）；`close()` 无操作。
class MemorySyncStore extends SyncRemoteStore {
  MemorySyncStore({this.manifest, this.lockedBy = ''});

  SyncManifest? manifest;
  final Map<String, Uint8List> snapshots = {};
  final Map<String, Uint8List> images = {};

  /// 云端图片删除墓碑文件（null = 文件不存在，首次同步按空处理）。
  ImgTombstones? tombstones;

  /// 当前持锁设备（非空表示锁被占用；`{deviceId, expiresAt}` 模拟）。
  String lockedBy = '';

  /// 可选：拦截读 manifest（模拟"同步期间其它设备已更新"等并发场景）。
  Future<SyncManifest?> Function()? onReadManifest;

  @override
  Future<SyncManifest?> readManifest() async =>
      onReadManifest?.call() ?? manifest;

  @override
  Future<void> writeManifest(SyncManifest m) async => manifest = m;

  @override
  Future<List<String>> listSnapshotNames() async => snapshots.keys.toList();

  @override
  Future<Uint8List?> readSnapshot(String name) async => snapshots[name];

  @override
  Future<void> writeSnapshot(String name, Uint8List b) async =>
      snapshots[name] = b;

  @override
  Future<void> deleteSnapshot(String name) async => snapshots.remove(name);

  @override
  Future<List<String>> listImages() async => images.keys.toList();

  @override
  Future<Uint8List?> readImage(String path) async => images[path];

  @override
  Future<void> writeImage(String path, Uint8List b) async => images[path] = b;

  @override
  Future<void> deleteImage(String path) async => images.remove(path);

  @override
  Future<ImgTombstones?> readImageTombstones() async => tombstones;

  @override
  Future<void> writeImageTombstones(ImgTombstones t) async => tombstones = t;

  @override
  Future<bool> acquireLock({String deviceId = '', int ttlSeconds = 300}) async {
    // 被其它设备持有 → 拒绝（注入的持锁状态视为未过期）。
    if (lockedBy.isNotEmpty && lockedBy != deviceId) return false;
    lockedBy = deviceId;
    return true;
  }

  @override
  Future<void> releaseLock({String deviceId = ''}) async {
    if (lockedBy == deviceId) lockedBy = '';
  }

  @override
  void close() {}
}

/// 内存版图片删除墓碑工作副本（`local_config/img_tombstones.json` 的替身）。
class MemoryTombstoneStore implements SyncTombstoneStore {
  MemoryTombstoneStore([this.state = ImgTombstones.empty]);

  ImgTombstones state;

  @override
  Future<ImgTombstones> load() async => state;

  @override
  Future<void> save(ImgTombstones tombstones) async => state = tombstones;
}

/// 内存版同步状态/共基存储（`sync_state` / 基表；图片墓碑见 [MemoryTombstoneStore]）。
class MemorySyncStateStore implements SyncStateStore {
  SyncStateRecord state = const SyncStateRecord();
  final Map<String, SyncBookBase> bookBases = {};
  final Map<String, SyncModBase> modBases = {};

  @override
  Future<SyncStateRecord> getState() async => state;

  @override
  Future<void> saveState(SyncStateRecord s) async => state = s;

  @override
  Future<Map<String, SyncBookBase>> getAllBookBases() async => bookBases;

  @override
  Future<void> putBookBase(SyncBookBase b) async => bookBases[b.uuid] = b;

  @override
  Future<void> deleteBookBase(String uuid) async => bookBases.remove(uuid);

  @override
  Future<Map<String, SyncModBase>> getAllModBases() async => modBases;

  @override
  Future<void> putModBase(SyncModBase b) async => modBases[b.uuid] = b;

  @override
  Future<void> deleteModBase(String uuid) async => modBases.remove(uuid);
}
