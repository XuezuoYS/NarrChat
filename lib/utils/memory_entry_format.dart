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
///
/// 【合并区间（兼容渲染与计数）】轮次写成「数字 + `-` / `~` + 数字」（半角 `-`/`~`
/// 与全角 `－`/`～` 均可，如 `11~15` / `第11－15轮`）时，视为**一条覆盖区间内
/// 各轮**的合并条目：轮次取小端（`round` = 11、`roundEnd` = 15，降序写法同样
/// 归一化），[MemoryEntry.roundSeparator] 保留原文分隔符用于展示，
/// [memoryEntryCount] 对区间内**每一轮**都计 1（即「11、12、…、15 轮条目都存在」）。
/// 三段及以上（`11~13~15`）不识别，交由调用方按未命中行兜底展示。
///
/// 【合并条目的**模型面向**形态】[kMemoryMergedEntryFormat]（一条覆盖多轮，
/// 时间写成区间），由「记忆总结轮次合并」档位驱动（见
/// `lib/services/memory_merge_planner.dart`）：
/// `- 15 - 20 | 仙历十四年五月二十日 ~ 仙历十四年七月八日 | 这期间的事。`
///
/// 【转义容错】全局提示词要求模型在每个波浪线前加 `\` 转义（防 Markdown 删除线），
/// 因此库内会出现 `\~` 这类写法。解析产物（UI 渲染与校验比较）一律先经
/// [unescapeMemoryEntryText] 还原成字面量，**存储与锚点仍保留原始字节**
/// （见 `AgentStateWorkingCopy` 的锚定式编辑）；区间分隔符前置的 `\` 同样容忍。
library;

/// 模型面向的记忆条目模板（提示词、工具描述、UI 提示、测试共用）。
const String kMemoryEntryFormat = '- {轮次} | {时间} | {记忆内容}';

/// 模型面向的**合并条目**模板：一条覆盖连续多轮，时间写成区间。
///
/// 例：`- 15 - 20 | 仙历十四年五月二十日 ~ 仙历十四年七月八日 | 这期间的事。`
/// （轮次区间用 ` - `、时间区间用 ` ~ `；`{记忆内容}` 由模型概括该区间。）
const String kMemoryMergedEntryFormat =
    '- {开头轮} - {结尾轮} | {开头轮时间} ~ {结尾轮时间} | {记忆内容}';

/// 渲染一条合并条目的**骨架行**：区间与首末时间由应用按待合并条目填好，
/// `{记忆内容}` 留给模型概括（提示词与测试共用同一形状）。
String memoryMergedEntryTemplate({
  required int startRound,
  required int endRound,
  required String startTime,
  required String endTime,
}) =>
    '- $startRound - $endRound | $startTime ~ $endTime | {记忆内容}';

/// Markdown 转义可还原的 ASCII 标点（`\` 后的这些字符视为被转义的字面量）。
const String _kEscapableAscii = r'\~*_`[]()#!+-.<>|{}';

/// 还原 Markdown 转义：`\~` → `~`、`\*` → `*`、`\\` → `\`。
///
/// 只处理 `\` + 可转义 ASCII 标点；`\` 后是其它字符（如路径 `C:\tmp`）时原样保留。
/// **仅用于解析产物**（UI 渲染、比较、校验）：落库文本与锚点字节不变。
String unescapeMemoryEntryText(String raw) {
  if (!raw.contains('\\')) return raw;
  final buf = StringBuffer();
  for (var i = 0; i < raw.length; i++) {
    final ch = raw[i];
    if (ch == '\\' &&
        i + 1 < raw.length &&
        _kEscapableAscii.contains(raw[i + 1])) {
      continue; // 丢掉反斜杠，下一轮把该字符原样写入。
    }
    buf.write(ch);
  }
  return buf.toString();
}

/// 记忆条目格式的**优先级声明**：与旧写法冲突时以 [kMemoryEntryFormat] 为准，
/// 但历史旧条目本身保持原样继承。
const String kMemoryEntryFormatPrecedence =
    '- 【格式优先】记忆条目一律以本格式为准：'
    '若历史旧条目或既有文案中的写法与本格式冲突，忽略旧写法；'
    '旧条目本身保持原样继承、不要改写，本轮新条目必须用本格式。';

/// 一条记忆条目：轮次 + 时间 + 内容（三者绑定在一条内）。
///
/// 轮次支持**合并区间**（`11~15`）：此时 [round] 为区间小端、[roundEnd] 为非空
/// 的区间大端，[covers] 对区间内每一轮都返回 true。
class MemoryEntry {
  /// 轮次（新格式 = 行首裸数字；旧格式 = `第N轮` 中的 N；
  /// 合并区间 = 区间**小端**，如 `11~15` / `15~11` 都是 11）。
  final int round;

  /// 合并区间的结束轮（`11~15` → 15）；`null` 表示单轮条目。
  ///
  /// `11~11` 这类两端相同的写法按单轮处理（[roundEnd] 为 null），不显示区间。
  final int? roundEnd;

  /// 合并区间原文使用的分隔符（半角 `-` / `~` 或全角 `－` / `～`）；
  /// 单轮条目为空串。仅用于忠实展示（见 [roundLabel]）。
  final String roundSeparator;

  /// 该轮剧情内时间（新格式第 2 段；旧格式 `日期：` / `时间：` 后的取值）。
  final String time;

  /// 该轮核心事件概括（最后一段，允许内部再出现 `|`）。
  final String content;

  const MemoryEntry({
    required this.round,
    required this.time,
    required this.content,
    this.roundEnd,
    this.roundSeparator = '',
  });

  /// 是否为合并条目（覆盖多轮）。
  bool get isMerged => roundEnd != null;

  /// 覆盖的最后一轮（单轮条目 = [round]）。
  int get roundMax => roundEnd ?? round;

  /// [roundIndex] 是否被本条目覆盖：单轮 = 轮次相等；合并 = 落在闭区间内
  /// （即区间内每一轮都算「已有条目」）。
  bool covers(int roundIndex) => roundIndex >= round && roundIndex <= roundMax;

  /// 徽标文案（不含「第」「轮」）：单轮 `34`；合并 `11~15`（保留原文分隔符）。
  String get roundLabel =>
      isMerged ? '$round$roundSeparator$roundEnd' : '$round';
}

/// 记忆条目行的正则：新格式 `- 34 | {时间} | {内容}` 与旧格式
/// `- 第N轮｜日期：xxx｜概括内容` 一并对齐为「轮次 / 时间 / 内容」三段；
/// 轮次额外容忍**合并区间**（`11~15` / `第11～15轮`，见 [roundEnd]）。
///
/// 容忍：
/// - 列表符 `-` / `*` / `+`（漏写列表符亦兼容，避免「校验过、卡片渲染不出」）；
/// - 旧格式的 `第` / `轮`（可省略，故新格式的裸数字同一条正则即可命中）；
/// - 轮次区间：`11~15`、`11-15`、`11～15`、`11－15`（半角/全角 `-` / `~`，
///   两侧允许空格；分隔符前可有 `\` 转义，如 `11\~15`）；仅「数字 + 分隔符 +
///   数字」两段，三段及以上不命中；
/// - 分隔符全角 `｜` 或半角 `|`；
/// - 冒号全角 `：` 或半角 `:`；
/// - 时间段的标签：`日期：` / `时间：`（冒号全半角均可），或**省略标签**
///   （兼容模型未输出标签的历史数据）；
/// - 记忆内容中再次出现 `｜`/`|`（末尾 `.*` 贪婪匹配）。
///
/// 分组使用**命名组**（`start` / `sep` / `end` / `time` / `content`），
/// 避免新增区间分组后数字下标漂移。
final RegExp memoryEntryLineRegex = RegExp(
  r'^\s*(?:[-*+]\s*)?(?:第\s*)?(?<start>\d+)\s*'
  r'(?:(?<sep>\\?[－～~-])\s*(?<end>\d+)\s*)?'
  r'(?:轮)?\s*[｜|]\s*'
  r'(?:(?:日期|时间)\s*[:：]\s*)?(?<time>[^｜|]*?)\s*[｜|]\s*(?<content>.*)$',
);

/// 解析**一行**记忆条目；未命中条目格式（含无法解析、或三段及以上区间写法）返回
/// `null`，由调用方决定兜底展示（见 [unmatchedMemoryLines]）。
///
/// 区间归一口径：`round` = 两端的较小值、`roundEnd` = 较大值（降序写法同样
/// 归一化，保持 [MemoryEntry.roundLabel] 可用）；两端相同 → 按单轮处理。
/// 时间 / 内容与区间分隔符统一经 [unescapeMemoryEntryText] 还原转义。
MemoryEntry? parseMemoryEntryLine(String line) {
  final m = memoryEntryLineRegex.firstMatch(line.trim());
  if (m == null) return null;
  final start = int.tryParse(m.namedGroup('start') ?? '');
  if (start == null) return null;
  final end = int.tryParse(m.namedGroup('end') ?? '');
  // 区间小端 / 大端（降序写法如 `15~11` 归一化为 11 → 15）。
  final low = (end == null || end >= start) ? start : end;
  final high = end == null ? start : (end >= start ? end : start);
  final merged = high > low;
  // 分隔符可能被模型转义成 `\~`；展示用去转义后的形状。
  final sep = unescapeMemoryEntryText(m.namedGroup('sep') ?? '');
  return MemoryEntry(
    round: low,
    roundEnd: merged ? high : null,
    roundSeparator: merged ? sep : '',
    time: unescapeMemoryEntryText((m.namedGroup('time') ?? '').trim()),
    content: unescapeMemoryEntryText((m.namedGroup('content') ?? '').trim()),
  );
}

/// 解析记忆总结文本为条目列表（新格式与旧格式兼容）。
///
/// 按行解析：能匹配 [memoryEntryLineRegex] 的行转换为 [MemoryEntry]（含合并区间），
/// 无法匹配的行直接忽略（需要兜底展示原始文本时用 [unmatchedMemoryLines]）。
List<MemoryEntry> parseMemoryEntries(String text) {
  final result = <MemoryEntry>[];
  for (final line in text.split('\n')) {
    final entry = parseMemoryEntryLine(line);
    if (entry != null) result.add(entry);
  }
  return result;
}

/// 未命中条目格式的**非空行**（保持原文，含前后空白），按出现顺序返回。
///
/// 与 [parseMemoryEntries] 共用 [parseMemoryEntryLine]，保证「渲染为卡片」与
/// 「兜底为原文」的口径完全一致（合并区间行不会再落进兜底文本）。
List<String> unmatchedMemoryLines(String text) => [
      for (final line in text.split('\n'))
        if (line.trim().isNotEmpty && parseMemoryEntryLine(line) == null) line,
    ];

/// 记忆总结中第 [roundIndex] 轮条目的数量（「每轮恰好一条」校验的依据）。
///
/// 合并区间条目按**覆盖**计：`11~15` 让 11 ~ 15 每一轮各计 1。
/// 只统计**解析成条目**的行：某条目的内容里恰好提到「第N轮」不会被误计。
int memoryEntryCount(String text, int roundIndex) =>
    parseMemoryEntries(text).where((e) => e.covers(roundIndex)).length;
