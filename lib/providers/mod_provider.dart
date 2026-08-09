import 'package:flutter/foundation.dart';

import '../database/mod_dao.dart';
import '../models/mod.dart';
import '../models/preset_mods.dart';
import '../models/round.dart';
import '../services/world_book_scanner.dart';
import '../models/world_book_entry.dart';

/// Mod 状态管理：用户自定义 Mod 的增删改查、书籍启用与顺序配置，
/// 以及将书籍启用的 Mod 解析为可直接注入提示词的 [ModsBundle]。
class ModProvider extends ChangeNotifier {
  ModProvider({ModDao? dao}) : _dao = dao ?? ModDao();

  final ModDao _dao;
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
      _userMods = await _dao.getAllMods();
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
      await _dao.insertMod(
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
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  Future<bool> updateMod(Mod mod) async {
    try {
      await _dao.updateMod(mod);
      await loadUserMods();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  Future<bool> deleteMod(int id) async {
    try {
      await _dao.deleteMod(id);
      await loadUserMods();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  // ---------- 书籍 Mod 关联 ----------

  /// 获取某本书已保存的 Mod 配置（不含未保存的 Mod，由 UI 自行补齐）。
  Future<List<BookModConfig>> getBookModConfigs(int bookId) async {
    try {
      return await _dao.getBookMods(bookId);
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return [];
    }
  }

  /// 保存某本书的完整 Mod 配置（整体替换）。
  Future<bool> saveBookModConfigs(int bookId, List<BookModConfig> configs) async {
    try {
      await _dao.replaceBookMods(bookId, configs);
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
    required int bookId,
    required String userInput,
    required List<Round> historyRounds,
  }) async {
    final configs = await _dao.getBookMods(bookId);
    if (configs.isEmpty) return ModsBundle.empty;

    final userMods = await _dao.getAllMods();
    final userById = {for (final m in userMods) m.id: m};

    final pre = StringBuffer();
    final post = StringBuffer();
    final system = StringBuffer();
    final worldEntries = <ModWorldBookEntry>[];

    for (final config in configs) {
      if (!config.isEnabled) continue;
      final mod = config.presetKey != null
          ? PresetMods.byKey(config.presetKey)
          : userById[config.modId];
      if (mod == null) continue;
      if (mod.prePrompt.trim().isNotEmpty) {
        pre.writeln(mod.prePrompt.trim());
      }
      if (mod.postPrompt.trim().isNotEmpty) {
        post.writeln(mod.postPrompt.trim());
      }
      if (mod.systemPrompt.trim().isNotEmpty) {
        system.writeln(mod.systemPrompt.trim());
      }
      worldEntries.addAll(
        mod.worldBookEntries.where((e) => e.content.trim().isNotEmpty),
      );
    }

    return ModsBundle(
      prePrompts: pre.toString().trim(),
      postPrompts: post.toString().trim(),
      systemPrompts: system.toString().trim(),
      worldBooks: _scanWorldBook(
        entries: worldEntries,
        userInput: userInput,
        historyRounds: historyRounds,
      ),
    );
  }

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
                  bookId: 0,
                  keyword: e.keyword,
                  content: e.content,
                ),
            ],
          );
    final parts = [...constant, if (scanned.trim().isNotEmpty) scanned.trim()];
    return parts.join('\n\n');
  }
}
