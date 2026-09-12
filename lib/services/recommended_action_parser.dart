/// 「推荐下一步」正文切分：把 AI 输出的 `## 推荐行动` 文本切成
/// **可双击的列表项**与**其余 Markdown 文本**两类片段（单一真源）。
///
/// 设计约定：
/// - **Markdown 仍是基础解析**：不匹配列表标记的行原样保留为 Markdown 片段，
///   由调用点继续交给 `MarkdownPreview` 渲染；列表项也只把列表标记剥离出来，
///   条目内容同样按 Markdown 渲染（行内加粗 / 链接 / 代码照常生效）；
/// - **标记范围 = 行首的 `- ` / `* ` / `数字. `**（如 `1. `）：提示词契约要求
///   「每条独占一行、序号从 1 开始」，故不做 `+` / `1)` / 缩进嵌套等扩展，
///   规则可预测；缩进行（嵌套列表、续行）与空条目不作为选项，仍走 Markdown；
/// - **显示序号按 Markdown 语义派生**（不照抄源数字）：同段有序列表的序号 =
///   首条源序号 + 段内位次——`1.` 连写四次的源文本仍显示 1/2/3/4，与
///   `flutter_markdown` 的 `nextListIndex` 行为一致；被非列表行打断后重新计数；
/// - **末条「自定义行动」标记为 [RecommendedActionOption.isCustomAction]**：
///   提示词契约（【推荐行动格式】）固定它为末条，语义是「由用户自行输入」，
///   调用点据此只聚焦输入框、不写入文本。
library;

/// 「自定义行动」条目的判字面量（提示词契约固定的末条文案）。
const String kCustomActionLabel = '自定义行动';

/// 条目内容末尾允许出现的标点（判定「自定义行动」时忽略，如 `自定义行动：`）。
final RegExp _trailingPunctuation = RegExp(r'[。．.!！?？:：,，、;；\s]+$');

/// 列表项标记：行首的 `- ` / `* ` / `数字. `；捕获组 1 = 标记，组 2 = 条目内容。
final RegExp _listMarker = RegExp(r'^([-*]|\d+\.)\s+(.*)$');

/// 推荐行动正文的一个片段（按原文顺序排列）。
sealed class RecommendedActionSegment {
  const RecommendedActionSegment();
}

/// 非列表项的 Markdown 文本片段（原文保留，交给 `MarkdownPreview` 渲染）。
final class RecommendedActionMarkdown extends RecommendedActionSegment {
  const RecommendedActionMarkdown(this.text);

  /// 片段原文（已去掉首尾空行；内部换行与空行保留，Markdown 块结构不变）。
  final String text;
}

/// 列表项片段：Markdown 列表外观下可双击的选项。
final class RecommendedActionOption extends RecommendedActionSegment {
  const RecommendedActionOption({
    required this.content,
    required this.ordered,
    required this.number,
    required this.isCustomAction,
  });

  /// 条目内容（已剥掉 `- ` / `* ` / `1. ` 标记）——双击时写入输入框的文本。
  final String content;

  /// 是否为有序列表项（`1. `）；无序项（`- ` / `* `）为 false。
  final bool ordered;

  /// 有序列表项的**显示序号**（1 起，按 Markdown 语义派生）；无序项固定 1。
  final int number;

  /// 是否为末条「自定义行动」（内容去掉首尾空白与句末标点后等于
  /// [kCustomActionLabel]）：双击它只聚焦输入框，不写入文本。
  final bool isCustomAction;
}

/// 把 [raw]（`## 推荐行动` 正文）切分为片段列表。
///
/// - 无列表项时返回单个 [RecommendedActionMarkdown]；
/// - 空文本 / 全空白返回空列表；
/// - 片段顺序与原文一致，选项之间的非列表文本各自成块。
List<RecommendedActionSegment> splitRecommendedAction(String raw) {
  final segments = <RecommendedActionSegment>[];
  // 待成块的 Markdown 文本行（遇到选项或结尾时收口）。
  final pending = <String>[];
  // 当前有序列表的显示序号（`ordered` 表示「上一条也是同段有序项」）。
  var ordered = false;
  var number = 1;

  void flushMarkdown() {
    var start = 0;
    var end = pending.length;
    while (start < end && pending[start].trim().isEmpty) {
      start++;
    }
    while (end > start && pending[end - 1].trim().isEmpty) {
      end--;
    }
    if (start < end) {
      segments.add(RecommendedActionMarkdown(
        pending.sublist(start, end).join('\n'),
      ));
    }
    pending.clear();
  }

  for (final line in raw.split('\n')) {
    final match = _listMarker.firstMatch(line);
    final content = match?.group(2)?.trim() ?? '';
    if (match == null || content.isEmpty) {
      // 非列表行（含空条目）：属于 Markdown 片段；列表被它打断后重新计数。
      ordered = false;
      pending.add(line);
      continue;
    }
    flushMarkdown();

    final marker = match.group(1)!;
    final isOrdered = marker.endsWith('.');
    if (isOrdered) {
      number = ordered
          ? number + 1
          : int.parse(marker.substring(0, marker.length - 1));
    } else {
      number = 1;
    }
    ordered = isOrdered;

    segments.add(RecommendedActionOption(
      content: content,
      ordered: isOrdered,
      number: number,
      isCustomAction: _isCustomAction(content),
    ));
  }

  flushMarkdown();
  return segments;
}

/// 条目内容是否为「自定义行动」（忽略首尾空白与句末标点）。
bool _isCustomAction(String content) =>
    content.replaceAll(_trailingPunctuation, '') == kCustomActionLabel;
