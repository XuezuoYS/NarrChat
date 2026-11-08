import 'package:flutter/foundation.dart';

import '../models/mod.dart';
import '../models/preset_mods.dart';
import '../models/round.dart';
import '../models/world_book_entry.dart';
import '../repositories/mod_repository.dart';
import '../services/app_repositories.dart';
import '../services/world_book_scanner.dart';
import 'cloud_sync_provider.dart';

/// Mod 状态管理：用户自定义 Mod 的增删改查、书籍启用与顺序配置，
/// 以及将书籍启用的 Mod 解析为可直接注入提示词的 [ModsBundle]。
class ModProvider extends ChangeNotifier {
  ModProvider({ModRepository? repository, CloudSyncProvider? cloudSyncProvider})
      : _repo = repository ?? AppRepositories.instance.mod,
        // ignore: prefer_initializing_formals
        _cloudSyncProvider = cloudSyncProvider;

  final ModRepository _repo;

  /// 云同步 Provider：Mod 修改保存后触发全自动同步（null = 未接入，如测试）。
  final CloudSyncProvider? _cloudSyncProvider;

  final WorldBookScanner _scanner = const WorldBookScanner();

  List<Mod> _userMods = [];
  String? _error;

  /// 用户自定义 Mod（按创建顺序）。
  List<Mod> get userMods => List.unmodifiable(_userMods);

  /// 预置 Mod（内置只读）。
  List<Mod> get presetMods => PresetMods.all;

  /// 全部 Mod：预置在前、用户自定义在后。
  List<Mod> get allMods => [...PresetMods.all, ..._userMods];

  String? get error => _error;

  Future<void> loadUserMods() async {
    try {
      _userMods = await _repo.listMods();
    } catch (e) {
      _error = e.toString();
    }
    notifyListeners();
  }

  Future<bool> addMod({
    required String name,
    String description = '',
    String prePrompt = '',
    String postPrompt = '',
    String systemPrompt = '',
    List<ModWorldBookEntry> worldBookEntries = const [],
  }) async {
    try {
      await _repo.createMod(
        Mod(
          name: name.trim(),
          description: description,
          prePrompt: prePrompt,
          postPrompt: postPrompt,
          systemPrompt: systemPrompt,
          worldBookEntries: worldBookEntries,
        ),
      );
      await loadUserMods();
      _cloudSyncProvider?.triggerSync();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  Future<bool> updateMod(Mod mod) async {
    try {
      await _repo.updateMod(mod);
      await loadUserMods();
      _cloudSyncProvider?.triggerSync();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  Future<bool> deleteMod(String uuid) async {
    try {
      await _repo.deleteMod(uuid);
      await loadUserMods();
      _cloudSyncProvider?.triggerSync();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  // ---------- 书籍 Mod 关联 ----------

  /// `UseModRow.modUuid` 的存储引用 → [BookModConfig]。
  ///
  /// 预置 Mod 不落 `mods` 表，书库里用 `preset::<key>` 前缀区分（见
  /// [Mod.presetRefPrefix]）；其余一律当用户 Mod 的 uuid。
  static BookModConfig? _configOfRef(String ref, String bookUuid, int order) {
    if (ref.startsWith(Mod.presetRefPrefix)) {
      final key = ref.substring(Mod.presetRefPrefix.length);
      if (key.isEmpty) return null;
      return BookModConfig(
        bookUuid: bookUuid,
        presetKey: key,
        isEnabled: true,
        sortOrder: order,
      );
    }
    if (ref.isEmpty) return null;
    return BookModConfig(
      bookUuid: bookUuid,
      modUuid: ref,
      isEnabled: true,
      sortOrder: order,
    );
  }

  /// [BookModConfig] → `UseModRow.modUuid`（null = 该配置没有可用引用，丢弃）。
  static String? _refOfConfig(BookModConfig config) {
    final presetKey = config.presetKey;
    if (presetKey != null && presetKey.isNotEmpty) {
      return Mod.presetRef(presetKey);
    }
    final modUuid = config.modUuid;
    if (modUuid != null && modUuid.isNotEmpty) return modUuid;
    return null;
  }

  /// 获取某本书**已启用**的 Mod 配置（按置入顺序）；读取失败返回 null。
  ///
  /// 只回启用项：`use_mods` 里根本不存在"配置了但禁用"的行，未启用项由界面
  /// 用「全部 Mod 减去已启用」补齐（见 `book_mod_panel.dart`）。
  /// 返回 null 让调用方（书籍设置页）能区分“这本书没启用 Mod”与“库读不出来”，
  /// 后者不会拿空配置去覆盖库。
  Future<List<BookModConfig>?> getBookModConfigs(String bookUuid) async {
    try {
      final refs = await _repo.useModUuids(bookUuid);
      final result = <BookModConfig>[];
      for (var i = 0; i < refs.length; i++) {
        final config = _configOfRef(refs[i], bookUuid, i);
        if (config != null) result.add(config);
      }
      return result;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return null;
    }
  }

  /// 保存某本书的完整 Mod 配置：只把**已启用**的按顺序落成启用清单。
  ///
  /// [triggerSync] 为 false 时由调用方在全部设置写完后统一触发一次同步。
  Future<bool> saveBookModConfigs(
    String bookUuid,
    List<BookModConfig> configs, {
    bool triggerSync = true,
  }) async {
    try {
      final enabled = [
        for (final config in configs)
          if (config.isEnabled) config,
      ]..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
      final refs = <String>[];
      for (final config in enabled) {
        final ref = _refOfConfig(config);
        if (ref != null) refs.add(ref);
      }
      await _repo.setUseModUuids(bookUuid, refs);
      if (triggerSync) _cloudSyncProvider?.triggerSync();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  // ---------- Prompt 解析 ----------

  /// 解析某本书当前启用的 Mod，按置入顺序（自上而下）拼接四段内容。
  ///
  /// 世界书条目与书籍世界书行为一致：关键词非空时扫描本轮输入与最近历史轮次、
  /// 命中才注入；关键词为空时恒定生效。每次发送请求时调用，从数据库实时读取。
  Future<ModsBundle> resolveModsBundle({
    required String bookUuid,
    required String userInput,
    required List<Round> historyRounds,
  }) async {
    final refs = await _repo.useModUuids(bookUuid);
    if (refs.isEmpty) return ModsBundle.empty;

    final userMods = await _repo.listMods();
    final userByUuid = {for (final m in userMods) m.uuid: m};

    final pre = <String>[];
    final post = <String>[];
    final system = <String>[];
    final worldEntries = <ModWorldBookEntry>[];

    for (final ref in refs) {
      final mod = ref.startsWith(Mod.presetRefPrefix)
          ? PresetMods.byKey(ref.substring(Mod.presetRefPrefix.length))
          : userByUuid[ref];
      if (mod == null) continue;
      if (mod.prePrompt.trim().isNotEmpty) {
        pre.add(mod.prePrompt);
      }
      if (mod.postPrompt.trim().isNotEmpty) {
        post.add(mod.postPrompt);
      }
      if (mod.systemPrompt.trim().isNotEmpty) {
        system.add(mod.systemPrompt);
      }
      worldEntries.addAll(
        mod.worldBookEntries.where((e) => e.content.trim().isNotEmpty),
      );
    }

    return ModsBundle(
      prePrompts: _joinBlocks(pre),
      postPrompts: _joinBlocks(post),
      systemPrompts: _joinBlocks(system),
      worldBooks: _scanWorldBook(
        entries: worldEntries,
        userInput: userInput,
        historyRounds: historyRounds,
      ),
    );
  }

  /// 拼接多个 Mod 的同类文案：逐块归一化后**以空行分隔**。
  ///
  /// 拼合端**不信任 Mod 端传来的文本**：每块各自 trim、去掉行尾空白、把 3 个以上
  /// 连续空行折叠为一个空行，块与块之间强制插入一个空行。若直接逐行拼接，
  /// 前一个 Mod 的末段会把后一个 Mod 的首行吞进同一段（Markdown 下块边界消失）。
  /// 空块在这里被丢弃（Mod 文案为空时不留空行）。
  static String _joinBlocks(List<String> blocks) => blocks
      .map(_normalizeBlock)
      .where((block) => block.isNotEmpty)
      .join('\n\n');

  /// 单个 Mod 文案块归一化（见 [_joinBlocks]）。
  static String _normalizeBlock(String raw) => raw
      .replaceAll(RegExp(r'[ \t]+\n'), '\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();

  /// 扫描 Mod 世界书条目：
  /// - 关键词为空的条目恒定注入；
  /// - 关键词非空的条目复用 [WorldBookScanner] 命中才注入。
  String _scanWorldBook({
    required List<ModWorldBookEntry> entries,
    required String userInput,
    required List<Round> historyRounds,
  }) {
    final constant = entries
        .where((e) => e.keywords.isEmpty)
        .map((e) => e.content.trim())
        .where((c) => c.isNotEmpty)
        .toList();
    final keywordEntries = entries.where((e) => e.keywords.isNotEmpty).toList();
    final scanned = keywordEntries.isEmpty
        ? ''
        : _scanner.scan(
            userInput: userInput,
            historyRounds: historyRounds,
            entries: [
              for (final e in keywordEntries)
                WorldBookEntry(
                  bookUuid: '',
                  keyword: e.keyword,
                  content: e.content,
                ),
            ],
          );
    final parts = [...constant, if (scanned.trim().isNotEmpty) scanned.trim()];
    return parts.join('\n\n');
  }
}
