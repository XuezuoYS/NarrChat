# Agent 工具说明

本文档描述 NarrChat 的 Agent 工具（`lib/services/agent/`）：

## 工具接口与循环机制

- 接口：`NarrAgentTool`（`narr_agent_tool.dart`）——`name`（模型调用名）/ `description`（指导模型何时调用）/ `parameters`（JSON Schema）/ `run(arguments)`（执行并返回 `AgentToolResult`）/ `activityType`（UI 活动类型：`searching` / `fetching` / `tooling`）。
- `AgentToolResult` 两面输出：`content`（**回传模型**的全文，状态工具含该栏目当前全文）与 `summary`（**UI 一行**摘要，缺省时回退 `content` 首行）。
- 循环器有两种：
  - `AgentRunner`（`agent_runner.dart`）：Chat 模式「联网搜索」循环（首轮带工具 → 搜索/抓取 → 回传 → 再生成），`maxIterations = 30`；
  - `AgentRoundRunner`（`agent_round_runner.dart`）：AGENT 模式单轮**两阶段**执行器——阶段 A 正文轮（`tool_choice=auto`，≤8 帧；正文 = 剧情 / 行动 / 当前时间三小节，时间不属于工具）→ 应用侧缺口判定 → 阶段 B 状态轮（`tool_choice=required`，1 主帧 + 3 修复帧，文本通道关闭；指令优先级：记忆 → 角色 → 世界，空手帧不提前止损）。**正文采纳制**：本轮正文 = 最后一个含标题帧的原始内容，开场白与状态轮文本一律不上屏（`_FrameGate` + `narrativeReset`）。协议类 4xx（`tool_choice` / `previous_response_id` / 中途调整思考强度）**就地降级重发同一帧**，不消耗帧预算；只有内容校验失败才走修复帧。输出触顶（`response.incomplete`）**不算失败**：保留截断前的部分结果，状态帧收到「拆短调用」指令（程序**不改写**用户设置的 `max_output_tokens`），末帧仍截断时黄框提示用户调高「最大 token」。详见 `docs/agent_mode.md`。
- 失败语义：
  - `success: false`：普通工具故障（网络/超时/校验失败/无结果），错误信息回传模型**继续执行**（状态工具失败即校验失败 → 列入状态轮待修项）；
  - `refused: true`：页面拒绝访问（HTTP 4xx/5xx），**不计入**工具连续失败次数（UI 黄色 ✕）；
  - 连续失败 3 次：该工具停用，回传模型"请勿再使用"，避免死循环。
- UI 活动映射：`AgentActivityType`（`turn` / `searching` / `fetching` / `tooling`）驱动聊天页的搜索框 / 打开页事件；`AgentEvent`（thinking / search / fetch / tool / hop）驱动时间线展示。状态工具框在「调用间隙」可见（如正文轮完成 → 状态轮进行中）。

## 工具清单（当前）

### `narrchat_webSearch`（`WebSearchTool`）

联网搜索工具：通过自研 `HtmlSearchService.search` 抓取搜索引擎结果。

- 参数：`query`（string，必填，关键词尽量简洁具体）
- 行为：返回最多 20 条结果的标题、链接与摘要；结果为空或失败时返回 `success: false` 并回传错误信息。
- 约束：`description` 与工具结果中明确要求——调用后必须紧接着用 `narrchat_webFetchPage` 打开最相关的 1~3 个结果页面阅读正文，禁止只依赖摘要。
- 注入时机：Chat 模式仅当用户开启「联网搜索」时注入；AGENT 模式同（状态工具恒定注入）。

### `narrchat_webFetchPage`（`FetchPageTool`）

打开网页工具：通过 `HtmlSearchService.fetchPageText` 抓取可读正文（截取前 30000 字符）。

- 参数：`url`（string，必填，完整的 http(s) 链接，一般取自搜索结果）
- 行为：返回页面正文文本供模型深入阅读；重定向跳转通过 `onHop` 回调流式展示（跳转链 UI）。
- 拒绝语义：HTTP 4xx/5xx 返回 `refused: true`（黄色 ✕，不计入连续失败），错误信息提示换用其它结果页面；网络/超时等其它失败走 `success: false`。
- 定位：它是 `narrchat_webSearch` 的**配套下游**——"搜索 → 打开页面 → 提炼细节 → 创作"是既定流程，模型不允许跳过打开页面环节。

### 状态工具（`state/state_tools.dart`，仅 AGENT 模式注入）

三个 `narrchat_*` 状态工具全部作用于本轮「工作副本」（`AgentStateWorkingCopy`）：
`narrchat_readState` 纯只读（模型自取快照），另外两个以**锚定式编辑**
（编辑文件式）方式维护：模型只提供**变更的行**，未触及的行字节级保留；
工具调用在流式响应中**即时预览**（卡片随 `output_item.added` / 参数增量
出现），执行完成后展示成功 / 错误结果。

| 工具 | 参数 | 语义 / 校验 |
|---|---|---|
| `narrchat_readState` | `round`（可选，核对用） | **读取工作副本当前渲染**（`<<<NARRCHAT_STATE round=N>>>` 包裹四段）。幂等只读、无副作用：正文轮调用 = 上一轮库内状态；状态轮调用 = 上一轮 + 本轮正文之后的状态；应用侧不区分调用时机。**真实注册**（模型必须先调它才能看到状态）；结果只保留**最新一份**（旧份自动剔除，修复帧不重复读取） |
| `narrchat_editSection` | `section`（worldState / characterState / memorySummary）+ `edits[]` | **锚定式**行编辑：`op=append`（newLine 追加到栏目末尾，记忆条目固定用）/ `set`（`before` 整行/连续多行逐字锚定 → `newLine` 替换）/ `insertAfter`（`before` 锚定 → 其后插入）/ `delete`（`before` 锚定删除）/ `noChange`（**必须带非空 `reason`**，登记进 `declaredUnchanged`；**最后手段**：正文里角色/局势只要有任何新动向——一句反应、一段心理、一次移动——就该写 `op=set`，一次调用可带多条 `edits`（每条对应一行改动），提示词点名「无需大改」类空泛理由按懒修改处理）/ `reset`（整栏目替换，仅限空栏目或明确重排）。`before` 锚点三级匹配：逐字行 → 归一化行（折叠空白与全/半角标点）→ 归一化行内子串；未命中 → 报错并回传**该栏目当前全文**（≤400 行）供重锚；不唯一 → 报错（列出命中行号）；同调用内按顺序应用（先插入的内容可被后续编辑引用）；事务化（任一失败整体不提交）；记忆总结变更后必须恰含一条本轮（`第 N 轮`）条目且不许 `noChange`；旧的 `line` 行号参数已被移除，携带时明确报错引导改用 `before` / `append` |

**当前时间不设工具**：属于正文 `## 当前时间` 小节（正文第三块），
应用从正文解析写入工作副本（缺失则沿用上一轮时间），不参与缺口判定。

### 状态快照的获取方式（模型自取，不做预置）

状态不再由 app 预置进上下文，而是模型**主动调用** `narrchat_readState`
获取（结果以 `function_call_output` 形态进入上下文）：
`<<<NARRCHAT_STATE round=N>>> … <<<END_NARRCHAT_STATE>>>` 包裹
`<time>` / `<worldState>` / `<characterState>` / `<memorySummary>` 四段。

- 为什么这么做：预置注入时模型把快照里的 md 块当成**可模仿的输出格式**，
  要么照格式堆进正文（Chat 式预期表现），要么写完正文再调工具，困惑
  「我不是都写了吗」；改为自取后，快照只是「模型问来的工具结果」，
  格式模仿的动机消失；
- 为什么不做 `previous_response_id` 判定：无状态 API 不支持，且应用侧
  **无需**从调用序列区分「正文次 / 状态维护次」——读取器幂等，返回值
  语义统一为工作副本当前渲染，阶段划分由执行器结构（正文轮 → 状态轮）
  决定；
- 上下文里**只保留最新一份**读取结果：新读取生效时旧条目自动剔除
  （`_pruneStaleReadState`），每轮输入不随修复帧数膨胀；修复帧指令
  明示「不再读取，复用已有快照与失败回传全文」。

## 缺口判定（`state/state_coverage.dart`）

`inspectState` 只看应用侧事实（`touchedSections` / `declaredUnchanged` /
`sectionText` 与 `sectionBaseText` 比对 / 出场角色块是否逐字节未变），产出
`StateGap` 列表：每个缺口同时给出面向模型的 `modelText`（EN + 【中】）与
面向用户的 `uiText`。模型说「已更新」不算更新。当前时间属于正文，不参与判定。

## 命名规范

自定义函数工具统一使用 `narrchat_` 前缀 + 小驼峰（如 `narrchat_webSearch`），原因：

- 与厂商内置工具（`web_search` 等服务端工具、`custom` 类型保留名 `apply_patch` 等）**零命名重叠**；
- 遵循 OpenAI 兼容 function 命名规范（`^[a-zA-Z0-9_-]{1,64}$`，建议控制在 50 字符以内）；
- 一眼可辨"这是 NarrChat 应用侧工具"。

注意：文件 / 类名（`web_search_tool.dart` / `WebSearchTool`）为**公共代码面**，与线上工具名无关，保持稳定不动。

## 扩展指引（新增工具）

1. 实现 `NarrAgentTool`（参考 `state/state_tools.dart` / `web_search_tool.dart`，工具名按上述规范，并声明 `activityType`）；
2. 注册：Chat 搜索工具在 `RoundProvider._makeAgentTools`；AGENT 状态工具在
   `buildStateTools`（`state/state_tools.dart`），AGENT 模式工具集 = 状态工具 + 可选搜索工具
   （两阶段共用同一份 `tools`，保证前缀逐字节一致）；
3. 新增 / 更新测试：`test/agent_runner_test.dart`（Chat 循环与失败语义）、
   `test/agent_round_runner_test.dart`（两阶段 / `tool_choice` / 降级 / 链式 /
   正文采纳制）、`test/agent_state_working_copy_test.dart`（锚点唯一匹配 /
   字节级保留 / `noChange`+`reason`）、`test/state_tools_test.dart`（工具契约）、
   `test/agent_round_test.dart`（provider 集成：请求体、快照落库、警告）、
   `test/raw_dialog_test.dart`（Agent 路径与 RAW 捕获），使用
   `test/helpers/fakes.dart` 公共替身；
4. 更新本文档与 `docs/agent_mode.md`。
