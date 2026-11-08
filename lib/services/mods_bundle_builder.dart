import '../models/mod.dart';
import '../models/round.dart';
import '../models/world_book_entry.dart';
import 'world_book_scanner.dart';

/// 把一组 Mod（已按置入顺序）拼成发送给 AI 的四段内容。
///
/// 这是 `ModProvider.resolveModsBundle` 与创建流程校验器共用的**单一实现**：
/// - 前置 / 后置 / 系统提示词：逐块归一化后以空行分隔；
/// - 世界书：关键词为空的条目恒定注入，关键词非空的条目按 [userInput] 与
///   历史轮次扫描命中后注入（与书籍世界书一致）。
class ModsBundleBuilder {
  const ModsBundleBuilder({this.scanner = const WorldBookScanner()});

  /// 世界书关键词扫描器（测试可注入替身）。
  final WorldBookScanner scanner;

  /// 按置入顺序拼出四段内容。
  ModsBundle build({
    required List<Mod> mods,
    required String userInput,
    List<Round> historyRounds = const [],
  }) {
    if (mods.isEmpty) return ModsBundle.empty;

    final pre = <String>[];
    final post = <String>[];
    final system = <String>[];
    final worldEntries = <ModWorldBookEntry>[];

    for (final mod in mods) {
      if (mod.prePrompt.trim().isNotEmpty) pre.add(mod.prePrompt);
      if (mod.postPrompt.trim().isNotEmpty) post.add(mod.postPrompt);
      if (mod.systemPrompt.trim().isNotEmpty) system.add(mod.systemPrompt);
      worldEntries.addAll(
        mod.worldBookEntries.where((entry) => entry.content.trim().isNotEmpty),
      );
    }

    return ModsBundle(
      prePrompts: joinBlocks(pre),
      postPrompts: joinBlocks(post),
      systemPrompts: joinBlocks(system),
      worldBooks: _scanWorldBook(
        entries: worldEntries,
        userInput: userInput,
        historyRounds: historyRounds,
      ),
    );
  }

  /// 拼接多个 Mod 的同类文案：逐块归一化后**以空行分隔**。
  ///
  /// 拼合端不信任 Mod 端传来的文本：每块各自 trim、去掉行尾空白、把 3 个以上
  /// 连续空行折叠为一个空行，块与块之间强制插入一个空行（否则前一个 Mod 的
  /// 末段会把后一个 Mod 的首行吞进同一段）。
  static String joinBlocks(List<String> blocks) => blocks
      .map(normalizeBlock)
      .where((block) => block.isNotEmpty)
      .join('\n\n');

  /// 单个 Mod 文案块归一化（见 [joinBlocks]）。
  static String normalizeBlock(String raw) => raw
      .replaceAll(RegExp(r'[ \t]+\n'), '\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();

  String _scanWorldBook({
    required List<ModWorldBookEntry> entries,
    required String userInput,
    required List<Round> historyRounds,
  }) {
    final constant = entries
        .where((entry) => entry.keywords.isEmpty)
        .map((entry) => entry.content.trim())
        .where((content) => content.isNotEmpty)
        .toList();
    final keywordEntries = entries
        .where((entry) => entry.keywords.isNotEmpty)
        .toList();
    final scanned = keywordEntries.isEmpty
        ? ''
        : scanner.scan(
            userInput: userInput,
            historyRounds: historyRounds,
            entries: [
              for (final entry in keywordEntries)
                WorldBookEntry(
                  bookUuid: '',
                  keyword: entry.keyword,
                  content: entry.content,
                ),
            ],
          );
    final parts = [
      ...constant,
      if (scanned.trim().isNotEmpty) scanned.trim(),
    ];
    return parts.join('\n\n');
  }
}
