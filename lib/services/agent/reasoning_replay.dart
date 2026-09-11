/// 思考（reasoning / 思维链）**回传精简**模块（纯函数）。
///
/// ## 为什么需要
///
/// 服务商对带 `tools` 的请求逐块校验：**每个 `function_call` 前都必须紧邻一块
/// 非空思考**，缺失即整次 400（「The `reasoning_text` in the thinking mode must
/// be passed back to the API」）。而 Agent 每帧全量重发会话，思考块会随帧数线性
/// 累积进输入——实测（`deepseek-v4-flash`，约 800 字思考）：输入按 **+273
/// token/帧** 增长，占位块只 +117 token/帧，即**回传真实思考让每帧多花约 150
/// token**，且随帧数线性拉大。
///
/// ## 精简规则（本模块的唯一职责）
///
/// 按**段落**切分，丢弃纯空白行（`\n\n` 这类格式占位不算段）：
///
/// - 只有 1 段 → 原样返回（不做任何改动）；
/// - 2 段及以上 → 取**首段 + 末段**（中间过程多是「先读A再看B然后C」这类流水
///   叙述，首末两段保留了意图与结论）。
///
/// ## 为什么不是"占位块"
///
/// 占位文本（如 `…`）能被服务端接受，但 `dsh-llm-deepseek` 的实测结论是：
/// 指向**转发网关**时，网关没有上游思考签名的线路槽位，只能对回传的思维链做
/// 哈希来还原签名——回传占位块会让签名查不到、重建会话与记录不一致，且**不报
/// 错**（静默失败）。首段 + 末段是**真实思考的子串语义**，不引入这种悬空引用。
///
/// 服务端不校验块内容与数量的对应关系（实测：一帧两块内容相同亦可），故精简后
/// 按调用数复制同一份文本是安全的。
library;

/// 按段落切分并丢弃纯空白行（保留段落原文本，不含首尾空白）。
List<String> splitReasoningSegments(String text) => [
      for (final line in text.split('\n'))
        if (line.trim().isNotEmpty) line.trim(),
    ];

/// 精简一段思考文本：单段原样返回；多段取首段 + 末段。
///
/// 首末段相同时（多段但内容重复）只返回一段。
String reduceReasoningText(String text) {
  final segments = splitReasoningSegments(text);
  if (segments.length <= 1) return segments.isEmpty ? '' : segments.first;
  if (segments.first == segments.last) return segments.first;
  return '${segments.first}\n\n${segments.last}';
}

/// 按当前策略给出**回传用**的思考文本。
///
/// [reduce] 为 false（用户关掉「精简思考回传」）时**逐字节**回传原文——与
/// `dsh-llm-deepseek` 的保守策略一致：原文回传才能让转发网关按思维链做的签名
/// 哈希对得上。空文本一律返回空串（调用方据此判断"没有思考可回传"）。
String reasoningTextForReplay(String text, {required bool reduce}) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return '';
  return reduce ? reduceReasoningText(trimmed) : trimmed;
}
