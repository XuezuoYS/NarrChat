/// 记忆条目（历史 / 记忆总结）格式的**单一真源**：模型面向的模板、格式优先级
/// 提示行，以及 UI 与校验共用的兼容解析。
///
/// 【新格式（模型产出）】`- {轮次} | {时间} | {记忆内容}`
///
/// 例：`- 34 | 2026年10月1日03:32:31 | 发生了……`
///
/// - `{轮次}` = 本轮轮号的**裸数字**（不写「第34轮」）；
/// - `{时间}` = 该轮结束时的**剧情内时间**（即该轮 `## 当前时间`），
///   写法沿用历史条目——公历或本书自定历法（如「丙戊年三月二十日」）皆可；
/// - `{记忆内容}` = 一句话概括该轮核心事件。
///
/// 【格式优先级】[kMemoryEntryFormatPrecedence]：与历史旧条目 / 既有文案里的
/// 写法冲突时以本格式为准；旧条目本身原样继承、不要改写（避免模型借「统一格式」
/// 之名重写整段历史）。
///
/// 【兼容格式（旧数据，继续渲染）】`- 第N轮｜日期：xxx｜概括内容`
///
/// 解析容忍：`-` / `*` / `+` 三种列表符（漏写列表符亦兼容）、可选的 `第` / `轮`、
/// 全/半角分隔符 `｜`/`|` 与冒号 `：`/`:`、可省略的 `日期：` / `时间：` 标签，
/// 以及内容中再次出现 `|`（末尾分组贪婪）。
library;

/// 模型面向的记忆条目模板（提示词、工具描述、UI 提示、测试共用）。
const String kMemoryEntryFormat = '- {轮次} | {时间} | {记忆内容}';

/// 记忆条目格式的**优先级声明**：与旧写法冲突时以 [kMemoryEntryFormat] 为准，
/// 但历史旧条目本身保持原样继承。
const String kMemoryEntryFormatPrecedence =
    '- 【格式优先】记忆条目一律以本格式为准：'
    '若历史旧条目或既有文案中的写法与本格式冲突，忽略旧写法；'
    '旧条目本身保持原样继承、不要改写，本轮新条目必须用本格式。';

/// 一条记忆条目：轮次 + 时间 + 内容（三者绑定在一条内）。
class MemoryEntry {
  /// 轮次（新格式 = 行首裸数字；旧格式 = `第N轮` 中的 N）。
  final int round;

  /// 该轮剧情内时间（新格式第 2 段；旧格式 `日期：` / `时间：` 后的取值）。
  final String time;

  /// 该轮核心事件概括（最后一段，允许内部再出现 `|`）。
  final String content;

  const MemoryEntry({
    required this.round,
    required this.time,
    required this.content,
  });
}

/// 记忆条目行的正则：新格式 `- 34 | {时间} | {内容}` 与旧格式
/// `- 第N轮｜日期：xxx｜概括内容` 一并对齐为「轮次 / 时间 / 内容」三段。
///
/// 容忍：
/// - 列表符 `-` / `*` / `+`（漏写列表符亦兼容，避免「校验过、卡片渲染不出」）；
/// - 旧格式的 `第` / `轮`（可省略，故新格式的裸数字同一条正则即可命中）；
/// - 分隔符全角 `｜` 或半角 `|`；
/// - 冒号全角 `：` 或半角 `:`；
/// - 时间段的标签：`日期：` / `时间：`（冒号全半角均可），或**省略标签**
///   （兼容模型未输出标签的历史数据）；
/// - 记忆内容中再次出现 `｜`/`|`（末尾 `.*` 贪婪匹配）。
final RegExp memoryEntryLineRegex = RegExp(
  r'^\s*(?:[-*+]\s*)?(?:第\s*)?(\d+)\s*(?:轮)?\s*[｜|]\s*'
  r'(?:(?:日期|时间)\s*[:：]\s*)?([^｜|]*?)\s*[｜|]\s*(.*)$',
);

/// 解析记忆总结文本为条目列表（新格式与旧格式兼容）。
///
/// 按行解析：能匹配 [memoryEntryLineRegex] 的行转换为 [MemoryEntry]，
/// 无法匹配的行直接忽略（需要兜底展示原始文本时，请由调用方自行保留原文本）。
List<MemoryEntry> parseMemoryEntries(String text) {
  final result = <MemoryEntry>[];
  for (final line in text.split('\n')) {
    final m = memoryEntryLineRegex.firstMatch(line.trim());
    if (m == null) continue;
    result.add(
      MemoryEntry(
        round: int.tryParse(m.group(1) ?? '') ?? 0,
        time: (m.group(2) ?? '').trim(),
        content: (m.group(3) ?? '').trim(),
      ),
    );
  }
  return result;
}

/// 记忆总结中第 [roundIndex] 轮条目的数量（「每轮恰好一条」校验的依据）。
///
/// 只统计**解析成条目**的行：某条目的内容里恰好提到「第N轮」不会被误计。
int memoryEntryCount(String text, int roundIndex) =>
    parseMemoryEntries(text).where((e) => e.round == roundIndex).length;
