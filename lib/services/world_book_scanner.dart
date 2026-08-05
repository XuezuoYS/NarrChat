import '../models/round.dart';
import '../models/world_book_entry.dart';

/// 世界书（World Book）关键词扫描器。
///
/// 扫描本轮用户输入与最近历史轮次（user_input + ai_narrative）：
/// - 命中某条目任一关键词时，将该条目内容加入“精确匹配触发的世界书条目”；
/// - 多个命中条目以空行分隔返回；无命中返回空字符串。
///
/// 返回文本由 [PromptBuilder] 注入 System Prompt。
class WorldBookScanner {
  const WorldBookScanner();

  /// 扫描本轮输入与历史上下文，返回精确匹配触发的世界书条目文本。
  ///
  /// [entries] 为当前书籍的世界书条目（Provider 已加载）。
  /// 返回空字符串表示本轮无命中条目（System Prompt 将显示“（无）”）。
  String scan({
    required String userInput,
    required List<Round> historyRounds,
    List<WorldBookEntry> entries = const [],
  }) {
    final active = entries.where((e) => e.isActive && e.keywords.isNotEmpty).toList();
    if (active.isEmpty) return '';

    final corpus = StringBuffer(userInput);
    for (final r in historyRounds) {
      if (r.userInput.isNotEmpty) corpus.writeln(r.userInput);
      if (r.aiNarrative.isNotEmpty) corpus.writeln(r.aiNarrative);
    }
    final text = corpus.toString();

    final matched = <String>[];
    for (final entry in active) {
      if (entry.keywords.any(text.contains)) {
        matched.add('【关键词：${entry.keyword}】\n${entry.content}');
      }
    }
    return matched.join('\n\n');
  }
}
