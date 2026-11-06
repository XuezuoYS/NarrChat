import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:narrchat/config/ai_platforms.dart';
import 'package:narrchat/database/migration/migration_paths.dart';
import 'package:narrchat/models/agent_mode_level.dart';
import 'package:narrchat/models/ai_platform.dart';
import 'package:narrchat/models/api_type.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/mod.dart';
import 'package:narrchat/models/round_generation.dart';
import 'package:narrchat/models/world_book_entry.dart';
import 'package:narrchat/providers/ai_settings_provider.dart';
import 'package:narrchat/providers/cloud_sync_provider.dart';
import 'package:narrchat/providers/experimental_settings_provider.dart';
import 'package:narrchat/repositories/book_repository.dart';
import 'package:narrchat/repositories/mod_repository.dart';
import 'package:narrchat/repositories/round_repository.dart';
import 'package:narrchat/repositories/world_book_repository.dart';
import 'package:narrchat/services/ai_service.dart';
import 'package:narrchat/services/app_repositories.dart';
import 'package:narrchat/services/app_stores.dart';
import 'package:narrchat/services/clipboard_paste_service.dart';
import 'package:narrchat/services/debug_database_service.dart';
import 'package:narrchat/services/image_import_service.dart';
import 'package:narrchat/services/notification_service.dart';
import 'package:narrchat/services/storage_service.dart';
import 'package:narrchat/services/sync/image_deletion.dart';
import 'package:narrchat/services/sync/image_revival.dart';
import 'package:narrchat/services/sync/img_tombstones.dart';
import 'package:narrchat/services/sync/sync_models.dart';
import 'package:narrchat/services/taskbar_attention_backend.dart';
import 'package:narrchat/services/update_check_service.dart';
import 'package:narrchat/utils/uuid_utils.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 一套**隔离的真实存储**：临时目录 + 五个 R3 库 + 仓储集合。
///
/// 为什么不再用假 DAO：
/// - schema / 事务 / 唯一键 / 外键这些只有真库才测得出来；
/// - R3 里一本书就是一个文件，假 DAO 根本无法模拟"跨库一致性"。
///
/// 用法（每个用例独立一套，**禁止**跨用例共享）：
/// ```dart
/// late TestStack stack;
/// setUp(() async => stack = await TestStack.create());
/// tearDown(() async => stack.dispose());
/// final bookUuid = await stack.seedBook();
/// await stack.seedRound(bookUuid, roundIndex: 1, aiNarrative: '正文');
/// ```
///
/// 注意：本类**不会**初始化 `AppRepositories.instance`，provider 必须显式注入
/// `stack.repos`；这样测试永远不会碰到真实用户目录。
class TestStack {
  TestStack._({
    required this.stores,
    required this.repos,
    required this.rootDir,
  });

  /// 五个库与连接池。
  final AppStores stores;

  /// 整册仓储（books / rounds / worldBook / mod）。
  final AppRepositories repos;

  /// 本次用例的临时根目录（dispose 时整个删掉）。
  final Directory rootDir;

  /// 建一套隔离存储（内部会 `sqfliteFfiInit` 并把全局 factory 切到 FFI）。
  ///
  /// **用 no-isolate 版工厂**：`testWidgets` 的测试体跑在 fake-async 区域，
  /// 真实事件循环不会自己转起来；带 isolate 的工厂要靠真实事件循环回消息，
  /// 于是在 widget 用例里 `await` 一句查库就永远不返回（现象：did not complete）。
  /// no-isolate 版把 sqlite 调用同步执行、结果用微任务回，`pump()` 一次就能推进完。
  static Future<TestStack> create({String prefix = 'narrchat_test_'}) async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;

    final root = Directory.systemTemp.createTempSync(prefix);
    final paths = MigrationPaths(
      userDataDir: p.join(root.path, 'user_data'),
      localConfigDir: p.join(root.path, 'local_config'),
    );
    // 临时目录里没有旧库，迁移只会写"已完成"标记，不会碰任何真实数据。
    final stores = await AppStores.openAt(paths);
    final repos = AppRepositories(
      stores: stores,
      books: BookRepositorySqlite(
        library: stores.library,
        cache: stores.cache,
        books: stores.books,
      ),
      rounds: RoundRepository(books: stores.books),
      worldBook: WorldBookRepository(books: stores.books),
      mod: ModRepository(mods: stores.mods, books: stores.books),
    );
    return TestStack._(stores: stores, repos: repos, rootDir: root);
  }

  /// 本次用例使用的路径（调试 / 需要直接开库的用例用）。
  MigrationPaths get paths => stores.paths;

  /// 关掉所有连接并删临时目录。放 `tearDown` 里，失败也要执行。
  Future<void> dispose() async {
    try {
      await stores.dispose();
    } catch (_) {
      // 关库失败不阻塞清理。
    }
    try {
      await rootDir.delete(recursive: true);
    } catch (_) {
      // Windows 上偶发占用，留个临时目录不影响结论。
    }
  }

  /// 建一本书，返回 uuid。[uuid] 传空则自动生成。
  Future<String> seedBook({
    String? uuid = '',
    String title = '测试书',
    String category = '',
    String baseSetting = '',
    String globalPrePrompt = '',
    String globalPostPrompt = '',
    int historyRounds = 1,
    int memorySummaryRounds = 0,
  }) {
    return repos.books.createBook(Book(
      uuid: uuid ?? '',
      title: title,
      category: category,
      baseSetting: baseSetting,
      globalPrePrompt: globalPrePrompt,
      globalPostPrompt: globalPostPrompt,
      historyRounds: historyRounds,
      memorySummaryRounds: memorySummaryRounds,
    ));
  }

  /// 直接改某本书的"最近对话时间"（首页时间排序用例用）。
  ///
  /// 缓存行是"列表读的副本"，改它等价于"这本书最近一次对话发生在 [time]"。
  Future<void> setLastRoundAt(String bookUuid, DateTime time) async {
    final existing = await stores.cache.indexOf(bookUuid);
    if (existing == null) return;
    await stores.cache.putIndex(existing.copyWith(lastRoundAt: time));
  }

  /// 「上一个轮号」在该分支上的当前选中代 uuid；第 1 轮返回 null（链首）。
  ///
  /// 用它而不是「活动链末尾」，见 [seedRound] 的说明。
  static String? _fatherOf(
    RoundChain chain,
    int roundIndex,
    String branchUuid,
  ) {
    if (roundIndex <= 1) return null;
    for (final round in chain.rounds) {
      if (round.roundIndex != roundIndex - 1) continue;
      if (round.branchUuid != branchUuid) continue;
      return round.uuid.isEmpty ? null : round.uuid;
    }
    return null;
  }

  /// 播一代（一轮的一个版本）。
  ///
  /// - [fatherUuid] 不传时自动接「**上一个轮号**的当前选中代」（第 1 轮为链首）；
  ///   注意不是「活动链末尾」——给同一轮播两个版本时（比如造一组可切换的代），
  ///   两代必须挂同一个父代才算同组；接链尾会让它们落进不同组，
  ///   版本步进控件根本不出现（这个坑真实踩过）。
  /// - 组内序号不传时自动取「同组最大 +1」；
  /// - [isUsing] 为 true 时同组其它代会被清掉选中（与真实写入路径一致）。
  Future<RoundGeneration> seedRound(
    String bookUuid, {
    int roundIndex = 1,
    String? uuid,
    String? fatherUuid,
    String branchUuid = '',
    int? serialNum,
    bool isUsing = true,
    String userInput = '',
    String aiNarrative = '',
    String messageStatus = '',
    String message = '',
    String modelName = '',
    int? tokensIn,
    int? tokensOut,
    int? tokensCachedIn,
    DateTime? operatedAt,
    List<String> userImages = const [],
    List<String> aiImages = const [],
  }) async {
    final chain = await repos.rounds.loadChain(bookUuid);
    final resolvedFather = fatherUuid ?? _fatherOf(chain, roundIndex, branchUuid);

    var maxSerial = 0;
    for (final meta in chain.allMeta) {
      final sameGroup = meta.branchUuid == branchUuid &&
          meta.roundIndex == roundIndex &&
          (meta.fatherUuid ?? '') == (resolvedFather ?? '');
      if (sameGroup && meta.roundSerialNum > maxSerial) {
        maxSerial = meta.roundSerialNum;
      }
    }

    final generation = RoundGeneration(
      meta: RoundMeta(
        uuid: uuid ?? UuidUtils.generateUuidV4(),
        fatherUuid: resolvedFather,
        branchUuid: branchUuid,
        roundIndex: roundIndex,
        roundSerialNum: serialNum ?? maxSerial + 1,
        isUsing: isUsing,
        operatedAt: operatedAt ?? DateTime.now().toUtc(),
        messageStatus: messageStatus,
        message: message,
      ),
      modelName: modelName,
      tokensIn: tokensIn,
      tokensOut: tokensOut,
      tokensCachedIn: tokensCachedIn,
      userInput: userInput,
      aiNarrative: aiNarrative,
      userImages: userImages,
      aiImages: aiImages,
    );
    await repos.rounds.appendGeneration(
      bookUuid: bookUuid,
      generation: generation,
    );
    return generation;
  }

  /// 连续播 [count] 轮（第 1..count 轮），返回全部代。
  Future<List<RoundGeneration>> seedRounds(
    String bookUuid, {
    int count = 0,
    int bodyRepeats = 40,
  }) async {
    final seeded = <RoundGeneration>[];
    for (var i = 1; i <= count; i++) {
      seeded.add(await seedRound(
        bookUuid,
        roundIndex: i,
        userInput: '第 $i 轮的用户输入',
        aiNarrative: '第 $i 轮的剧情正文。' * bodyRepeats,
      ));
    }
    return seeded;
  }

  /// 建一条世界书条目，返回 uuid。
  Future<String> seedWorldBookEntry(
    String bookUuid, {
    required String keyword,
    String content = '',
    bool isUsing = true,
  }) async {
    final saved = await repos.worldBook.upsert(
      bookUuid,
      WorldBookEntry(
        bookUuid: bookUuid,
        keyword: keyword,
        content: content,
        isActive: isUsing,
      ),
    );
    return saved.uuid;
  }

  /// 建一个用户 Mod，返回 uuid。
  Future<String> seedMod({
    String name = '测试 Mod',
    String description = '',
    String prePrompt = '',
    String postPrompt = '',
    String systemPrompt = '',
  }) {
    return repos.mod.createMod(Mod(
      name: name,
      description: description,
      prePrompt: prePrompt,
      postPrompt: postPrompt,
      systemPrompt: systemPrompt,
    ));
  }
}

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

/// Chat 协议（OpenAI Chat API 兼容）的 AI 设置替身。
///
/// 默认平台协议为 Response API（/responses 线路）；需要走 Chat 线路
/// （直发 / 搜索 / AGENT 在 Chat 通道运行）的用例继承本类，
/// 避免触碰响应式（responses）路径。
class ChatCompatibleSettings extends AiSettingsProvider {
  @override
  AiPlatform get selectedPlatform => AiPlatforms.defaultPlatform.copyWith(
        apiType: ApiType.openAiCompatible,
        baseUrl: 'https://api.deepseek.com',
      );
}

/// 开启 Agent 模式的实验性设置替身（构造注入档位，不触碰真实配置文件）。
///
/// 默认 [AgentModeLevel.lv2]（完整 Agent：六个状态工具 + 正文三小节）；
/// 需要 Lv.1（仅历史工具 + 正文 5 区块）时显式传 `level:`。
/// Agent 档位与平台协议**正交**：与 [ChatCompatibleSettings] /
/// 默认 Response 平台组合分别覆盖「Agent × Chat 线路」与
/// 「Agent × Responses 线路」两条路径。
class AgentModeSettings extends ExperimentalSettingsProvider {
  AgentModeSettings({AgentModeLevel level = AgentModeLevel.lv2})
      : super(initialLevel: level);
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

/// 记录每次实发请求体的 AI 替身（「预览请求体 ≡ 实发首帧」对拍用例专用）。
///
/// 同时覆写 chat / responses 两条线路：请求体原样存入 [bodies]，并按 [content]
/// 返回一个可直接落库的完整正文（`failWith` 非空时抛出，用于断言失败路径）。
class RecordingAiService extends AiService {
  RecordingAiService({this.content = kRecordingFullContent, this.failWith});

  /// 一次实发调用捕获到的请求体（顺序 = 调用顺序）。
  final List<Map<String, dynamic>> bodies = [];

  /// 返回给上层的完整正文（默认六区块齐全，可直接落库）。
  String content;

  /// 非 null：每次调用抛出该异常（模拟请求失败）。
  Object? failWith;

  int get calls => bodies.length;

  AiCallResult _record(Map<String, dynamic> requestBody) {
    bodies.add(requestBody);
    final err = failWith;
    if (err != null) throw err;
    return AiCallResult(
      content: content,
      promptTokens: 1,
      completionTokens: 1,
    );
  }

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
    final result = _record(requestBody);
    if (stream) onChunk?.call(const AiStreamChunk(done: true));
    return result;
  }

  @override
  Future<AiCallResult> responses({
    required String apiBaseUrl,
    required String apiKey,
    required Map<String, dynamic> requestBody,
    bool stream = false,
    void Function(AiStreamChunk chunk)? onChunk,
    void Function(String requestBody)? onRequestBody,
    bool Function()? isCancelled,
  }) async {
    final result = _record(requestBody);
    if (stream) onChunk?.call(const AiStreamChunk(done: true));
    return result;
  }
}

/// [RecordingAiService] 的默认正文（六区块齐全，`AiResponseParser` 可解析落库）。
const String kRecordingFullContent = '## 剧情演绎\n测试正文\n'
    '## 推荐行动\n\n'
    '## 当前时间\n第一天 午时\n'
    '## 世界状态\n\n'
    '## 角色状态\n\n'
    '## 记忆总结\n';

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
  FakeNotificationBackend({
    this.notificationsEnabled,
    this.launchPayload,
    this.channelState = const GenerationDoneChannelState(
      headsUp: true,
      sound: true,
    ),
  });

  final List<({int id, String title, String body, String payload})> shown = [];
  final List<int> cancelled = [];
  final List<int> startedForeground = [];
  int stopForegroundCount = 0;
  int openSettingsCount = 0;
  void Function(String bookUuid)? onTap;

  /// 是否允许通知（null = 非 Android / 未知）。
  bool? notificationsEnabled;

  /// 冷启动点通知的书籍 uuid（null = 非冷启动）。
  String? launchPayload;

  /// 生成完成渠道的系统侧状态（默认全开；置 null 模拟渠道尚未创建）。
  GenerationDoneChannelState? channelState;

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
  Future<GenerationDoneChannelState?> generationDoneChannelState() async =>
      channelState;

  @override
  Future<void> openNotificationSettings() async {
    openSettingsCount++;
  }

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

/// 可控存储管理替身（R3：多库概览 + 整包导出导入 + 旧备份删除）。
class FakeStorageService implements StorageService {
  FakeStorageService({
    this.overviewValue = const StorageOverview(
      databases: [],
      imageCount: 0,
      imageBytes: 0,
      bookCount: 0,
    ),
    this.images = const [],
  });

  StorageOverview overviewValue;
  List<StorageImageInfo> images;
  int deleteCalls = 0;
  int deleteLegacyCalls = 0;
  String? exportedTo;
  String? exportedName;
  List<String>? exportedImages;
  String? exportedImagesTo;
  String? importedArchive;
  bool? exportedWithLocalConfig;
  StorageImportResult importResult = const StorageImportResult(
    ok: true,
    message: '导入成功',
  );

  @override
  Future<StorageOverview> overview() async => overviewValue;

  @override
  Future<List<StorageImageInfo>> listImages() async => List.of(images);

  @override
  Future<int> exportImages({
    required List<String> relPaths,
    required String targetDirPath,
  }) async {
    exportedImages = List.of(relPaths);
    exportedImagesTo = targetDirPath;
    return relPaths.length;
  }

  @override
  Future<String> exportArchive({
    required String targetDirPath,
    required String fileName,
    bool includeLocalConfig = false,
  }) async {
    exportedTo = targetDirPath;
    exportedName = fileName;
    exportedWithLocalConfig = includeLocalConfig;
    return p.join(targetDirPath, fileName);
  }

  @override
  Future<StorageImportResult> importArchive({required String archivePath}) async {
    importedArchive = archivePath;
    return importResult;
  }

  @override
  Future<void> deleteLegacyBackup() async {
    deleteLegacyCalls++;
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

/// 内存版 [DebugDatabaseService]（R3：多库选择器 + 按库列表 / 读表）。
///
/// 按 [pageBuilder] 生成每页数据，记录最近一次调用的库、表与页参数，
/// 供「数据库结构」页测试校验切换库与翻页。
class FakeDebugDatabaseService implements DebugDatabaseService {
  FakeDebugDatabaseService({
    this.databases = const [],
    this.tables = const [],
    this.pageBuilder,
  });

  /// listDatabases 的返回值（含"文件不存在"的项）。
  List<DebugDbInfo> databases;

  final List<DebugTableSummary> tables;

  /// 按 `(dbId, name, page, pageSize)` 生成一页数据；为 null 时返回空页。
  final DebugTablePage Function(String dbId, String name, int page, int pageSize)?
      pageBuilder;

  int listDatabasesCount = 0;
  int loadCount = 0;
  String? lastDbId;
  String? lastName;
  int? lastPage;
  int? lastPageSize;

  @override
  Future<List<DebugDbInfo>> listDatabases() async {
    listDatabasesCount++;
    return List.of(databases);
  }

  @override
  Future<List<DebugTableSummary>> listTables(String dbId) async {
    lastDbId = dbId;
    return tables;
  }

  @override
  Future<DebugTablePage> loadTable(
    String dbId,
    String tableName, {
    int page = 0,
    int pageSize = 20,
  }) async {
    loadCount++;
    lastDbId = dbId;
    lastName = tableName;
    lastPage = page;
    lastPageSize = pageSize;
    final builder = pageBuilder;
    if (builder != null) return builder(dbId, tableName, page, pageSize);
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

/// 更新检查服务替身：不发网络请求，按预置结果序列回放，并记录调用参数。
///
/// 供「启动更新检查流程」（`update_check_flow_test`）与「调试菜单强制触发
/// 更新提示框」（`debug_screen_test`）两类用例共用。
class FakeUpdateCheckService extends UpdateCheckService {
  FakeUpdateCheckService([List<UpdateCheckResult> results = const []])
      : _results = List.of(results),
        super(client: MockClient((_) async => http.Response('', 404)));

  final List<UpdateCheckResult> _results;

  /// 每次调用传入的本地版本号（依序）。
  final List<String> checkedVersions = [];

  /// 每次调用传入的 forceShow（依序；默认 `false`）。
  final List<bool> forceShowValues = [];

  /// 调用次数。
  int calls = 0;

  @override
  Future<UpdateCheckResult> check({
    required String currentVersion,
    bool forceShow = false,
  }) async {
    calls++;
    checkedVersions.add(currentVersion);
    forceShowValues.add(forceShow);
    return _results.removeAt(0);
  }
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

/// [CloudSyncProvider] 替身：只记录 `triggerSync` 调用（不打网络、不碰本地配置）。
///
/// 供「哪些写路径该触发自动同步」的用例复用（生成 / 采纳 / 删除触发，
/// 版本切换不触发），比每个用例各写一份记录器更不易漂移。
class FakeCloudSyncProvider extends CloudSyncProvider {
  /// 自动同步触发次数。
  int triggers = 0;

  /// 最近一次触发的种类（未触发时为 null）。
  SyncKind? lastKind;

  /// 最近一次触发是否静默。
  bool? lastSilent;

  @override
  void triggerSync({SyncKind kind = SyncKind.both, bool silent = false}) {
    triggers++;
    lastKind = kind;
    lastSilent = silent;
  }
}

/// [CloudSyncProvider] 替身：覆写「保留历史版本」云端读写，
/// 切断真实 WebDAV（供弹窗 / 面板 widget 测试复用）。
class StubCloudSyncProvider extends CloudSyncProvider {  StubCloudSyncProvider({
    this.cloudKeepVersions = SyncConfig.defaultKeepVersions,
    this.refreshError,
    this.saveError,
  });

  /// 模拟的云端真值（refreshKeepVersions 会注入展示缓存）。
  int cloudKeepVersions;

  /// 非 null：refreshKeepVersions 返回该错误文本（不更新缓存）。
  String? refreshError;

  /// 非 null：saveKeepVersions 返回该错误文本（不更新缓存）。
  String? saveError;

  int refreshCalls = 0;
  int saveCalls = 0;
  int? lastSavedValue;

  @override
  Future<String?> refreshKeepVersions() async {
    refreshCalls++;
    final err = refreshError;
    if (err != null) return err;
    debugSetKeepVersions(cloudKeepVersions);
    return null;
  }

  @override
  Future<String?> saveKeepVersions(int value) async {
    saveCalls++;
    lastSavedValue = value;
    final err = saveError;
    if (err != null) return err;
    cloudKeepVersions = value;
    debugSetKeepVersions(value);
    return null;
  }
}

