# Agent 工具说明

本文档描述 NarrChat 的 Agent 工具（`lib/services/agent/`）：

## 工具接口与循环机制

- 接口：`NarrAgentTool`（`narr_agent_tool.dart`）——`name`（模型调用名）/ `description`（指导模型何时调用）/ `parameters`（JSON Schema）/ `run(arguments)`（执行并返回 `AgentToolResult`）/ `activityType`（UI 活动类型：`searching` / `fetching` / `tooling`）/ `isReadOnly`（**只读读取器**为 true；搜索 / 打开页面 / 状态编辑器为 false，执行器据此区分「查阅」与「编辑」）。
- `AgentToolResult` 两面输出：`content`（**回传模型**的全文，状态编辑器含该栏目当前全文）与 `summary`（**UI 一行**摘要，缺省时回退 `content` 首行）。
- 循环器有两种：
  - `AgentRunner`（`agent_runner.dart`）：Chat 模式「联网搜索」循环（首轮带工具 → 搜索/抓取 → 回传 → 再生成），`maxIterations = 30`；
  - `AgentRoundRunner`（`agent_round_runner.dart`）：Agent 档位单轮**两步**执行器（`AgentStage{prepare, story, state}`）。**第一步**：调研回合（`stage=prepare`，≤6 回合；读一次 `narrchat_readHistory` → 需要时联网搜索 / 打开页，**不写记忆 / 正文、文本零输出**；**本回合只调读取器即结束**）→ 正文回合（`stage=story`，≤8 回合，**唯一正文上屏回合**，5 区块，禁止 `## 记忆总结`；第一步的状态编辑器一律拒绝执行）。**第二步**：维护回合（`stage=state`，≤4 回合；正文完成后**单独新请求**，只维护记忆总结，文本只进 UI 维护流式框）。**所有步结束后才由 `RoundProvider` 统一写入一条 `Round`**，token 记所有回合总和。**正文采纳制**：本轮正文 = 最后一个含标题回合的原始内容，开场白与维护回合文本一律不上屏（`_FrameGate` + `narrativeReset`）。**档位**（`AgentModeProfile`）决定正文契约与工具集：当前只有 Lv.1——五区块正文 + 仅历史工具 + 记忆在第二步维护。**读取只做一次**：调研回合读到的那一份就是后续唯一锚点来源（写正文不改变状态），维护回合对「已提供过全文的栏目」的重复读取被**拒绝执行**（未提供过的栏目照常放行，非合规流程不失明）。协议类 4xx（`previous_response_id`，即服务商不接受有状态续接）**就地降级重发同一回合**（同一轮内生效、跨轮重新探测）：不计回合、不计失败轮、不计 token，失败回合在 RAW 显示服务商报错原文（含 HTTP 码）；**思考强度不参与降级**——它全程沿用户设置；只有内容校验失败才走修复回合。输出触顶（`response.incomplete`）**不算失败**：保留截断前的部分结果，维护回合收到「拆短调用」指令（程序**不改写**用户设置的 `max_output_tokens` / `reasoning_effort`），末回合仍截断时黄框提示用户调高「最大 token」。详见 `docs/agent_mode.md`。
- 失败语义：
  - `success: false`：普通工具故障（网络/超时/校验失败/无结果），错误信息回传模型**继续执行**（状态编辑器失败即校验失败 → 列入维护回合待修项）；
  - `refused: true`：页面拒绝访问（HTTP 4xx/5xx），**不计入**工具连续失败次数（UI 黄色 ✕）；
  - 连续失败 3 次：该工具停用，回传模型"请勿再使用"，避免死循环。
- UI 活动映射：`AgentActivityType`（`turn` / `searching` / `fetching` / `tooling`）驱动聊天页的搜索框 / 打开页事件；`AgentEvent`（thinking / search / fetch / tool / hop）驱动时间线展示。维护回合的维护框由 `RoundProvider.agentMaintenanceActive` / `agentMaintenanceContent` 驱动，工具框仍照常显示。

## 工具清单（当前）

### `narrchat_webSearch`（`WebSearchTool`）

联网搜索工具：通过自研 `HtmlSearchService.search` 抓取搜索引擎结果。

- 参数：`query`（string，必填，关键词尽量简洁具体）
- 行为：返回最多 20 条结果的标题、链接与摘要；结果为空或失败时返回 `success: false` 并回传错误信息。
- 约束：`description` 与工具结果中明确要求——调用后必须紧接着用 `narrchat_webFetchPage` 打开最相关的 1~3 个结果页面阅读正文，禁止只依赖摘要。
- 注入时机：Chat 模式仅当用户开启「联网搜索」时注入；**Agent 档位下强制注入**
  （联网在 Agent 期间强制开启，模型配置页关闭搜索能力时不注入）。
- 维护回合不执行搜索 / 打开页（执行器直接拒绝，只维护记忆总结）。

### `narrchat_webFetchPage`（`FetchPageTool`）

打开网页工具：通过 `HtmlSearchService.fetchPageText` 抓取可读正文（截取前 30000 字符）。

- 参数：`url`（string，必填，完整的 http(s) 链接，一般取自搜索结果）
- 行为：返回页面正文文本供模型深入阅读；重定向跳转通过 `onHop` 回调流式展示（跳转链 UI）。
- 拒绝语义：HTTP 4xx/5xx 返回 `refused: true`（黄色 ✕，不计入连续失败），错误信息提示换用其它结果页面；网络/超时等其它失败走 `success: false`。
- 定位：它是 `narrchat_webSearch` 的**配套下游**——"搜索 → 打开页面 → 提炼细节 → 创作"是既定流程，模型不允许跳过打开页面环节。

### 工具描述文案规范（全部工具统一）

- **形态（v2 口径）**：`description` = **简明中文**——撤销中英双语，
  英文只保留**工具名**（`narrchat_*`）、**状态块标签**
  （`<worldState>` / `<characterState>` / `<memorySummary>`）、`op` 取值与参数名；
  不出现成句英文，也不出现 `【中】` / `[EN]` 一类语言标记；
- **同一口径覆盖所有模型面向文本**：除各工具的 `description` 外（六个状态工具
  的文案都保留，无论当前是否注册），还包括
  状态快照块头（`AgentStateWorkingCopy._renderSections`，单行中文声明）、缺口指令
  `StateGap.modelText`、各类「本次未执行」拒绝说明（`AgentRoundRunner`）——
  一律中文、无语言标记；
- **单一出处**：联网工具的**全部调用指导只在 `description` 里**
  （`narrchat_webSearch` 点明「调用后必须紧接着用 `narrchat_webFetchPage`
  打开最相关的 1~3 个结果页面读正文」，打开页工具点明「拒绝访问时换用其它
  结果页面」）；`RoundProvider` 的组装路径**不再向 system 追加任何联网指令**；
- **占位符写法统一为 `{中文名}`**：模型面向文案里涉及具体取值的位置一律写作
  `{轮次}` / `{时间}` / `{记忆内容}`（记忆条目模板）与 `{类别名}` / `{角色名}` /
  `{属性名}` / `{属性值}`（角色状态形态示例），**不写具体案例**；
  旧写法 `<时间>` / `<一句话概括>` / `xxx` / `{name}` 已废弃。
  记忆条目的模板与「格式优先」行是跨文件常量（真源 =
  `lib/utils/memory_entry_format.dart` 的 `kMemoryEntryFormat` /
  `kMemoryEntryFormatPrecedence`）：与历史旧条目 / 既有文案的写法冲突时以新格式
  为准，旧条目本身原样继承、不改写。
  轮次另容忍**合并区间**（`11~15` / `11-15`，半角 `-`/`~` 与全角 `－`/`～`，
  分隔符前可有被转义的 `\`）：
  解析为一条覆盖区间内各轮的条目（升序归一、保留原分隔符供侧栏徽标展示），
  计数对区间内每一轮各计 1（侧栏「记忆总结」区以灰阶徽标渲染合并条目）；
  三段及以上（`11~13~15`）不识别，按未命中行兜底展示。
  **合并条目**的模型面向形态是 `kMemoryMergedEntryFormat`
  （`- {开头轮} - {结尾轮} | {开头轮时间} ~ {结尾轮时间} | {记忆内容}`），由每本书
  的「记忆总结轮次合并」档位驱动（触发规则与判定真源 =
  `lib/services/memory_merge_planner.dart`，落地口径见 `docs/agent_mode.md`
  的「记忆总结轮次合并」小节）；被转义的 `~` 由 `unescapeMemoryEntryText`
  在解析产物上还原，存储与锚点仍是原始字节。
  例外（不算占位符，不改写）：`<worldState>` / `<characterState>` /
  `<memorySummary>` 是读取结果的**字面块标签**；
  真源见 `docs/ai_prompt_v2.md` 顶部「不举例」与 `prompt_v2_sections.dart`
  （Mod 文案不受此约定约束）；
- **参数 schema 文案**沿用同一简明中文写法（如 `before` / `reason` 的说明）；
- 契约由 `test/agent_tool_descriptions_test.dart`（工具描述形态与调用指导）、
  `test/state_coverage_test.dart` / `test/agent_state_working_copy_test.dart`
  （缺口指令、快照块为单行中文、无标记）、`test/memory_entry_format_test.dart`
  （条目解析 / 计数）与 `test/prompt_placeholders_test.dart`
  （占位符写法与格式优先级行）守护。

### 状态工具（`state/state_tools.dart`；当前只注册历史一读一写）

**六个工具按栏目成对拆分**（每个栏目一个只读读取器 + 一个锚定式编辑器），
全部作用于本轮「工作副本」（`AgentStateWorkingCopy`）。世界 / 角色两对是保留
框架（Agent Lv.2 已移除，当前没有档位注册它们）；现役只有历史一对。
工具调用在流式响应中**即时预览**（卡片随 `output_item.added` / 参数增量出现），
执行完成后展示成功 / 错误结果。

| 栏目 | 读取器 | 编辑器 |
|---|---|---|
| 世界状态 | `narrchat_readWorldState` | `narrchat_editWorldState` |
| 角色状态 | `narrchat_readCharacterState` | `narrchat_editCharacterState` |
| 历史（记忆总结） | `narrchat_readHistory` | `narrchat_editHistory` |

**注册顺序 = 读取器在前、编辑器在后**（`buildStateTools(copy, sections: ...)`），
`AgentModeProfile.toolSections` 决定注册哪些栏目：当前档位只传历史一栏
（一读一写）；世界 / 角色两对随六工具保留为框架，没有任何档位注册它们。

| 工具 | 参数 | 语义 / 校验 |
|---|---|---|
| `narrchat_readWorldState` / `narrchat_readCharacterState` / `narrchat_readHistory` | `round`（可选，核对用） | **读取工作副本该栏目的当前渲染**（`<<<NARRCHAT_STATE round=N>>>` 包裹**单个** `<tag>` 块，空栏目标 `empty="true"`）。纯只读、幂等、无副作用：**调研回合读一次**（= 上一轮库内状态）；维护回合**不再重复读取**（写正文不改变状态，读到的那一份就是唯一锚点来源）。**真实注册**（模型必须先调它才能看到状态与锚点）；**每栏只保留最新一份**结果（同栏旧份自动剔除，且只有真正执行成功的读取才剔除旧份——被拒绝的重复读取不得顶掉已有锚点来源）。**维护回合**对「本轮已提供过全文的栏目」的读取调用被**拒绝执行**（回一条说明 + 工具框 ✕，不计入缺项清单）——调研回合已提供过历史全文时，维护回合的重复读取同样被拒绝；未提供过的栏目（漏读 / 参数被截断）照常执行 |
| `narrchat_editWorldState` / `narrchat_editCharacterState` / `narrchat_editHistory` | 仅 `edits[]`（工具自身已绑定栏目，**无 `section` 参数**） | **锚定式**行编辑：`op=append`（newLine 追加到栏目末尾，历史条目固定用）/ `set`（`before` 整行/连续多行逐字锚定 → `newLine` 替换）/ `insertAfter`（`before` 锚定 → 其后插入）/ `delete`（`before` 锚定删除）/ `noChange`（**必须带非空 `reason`**，登记进 `declaredUnchanged`；**最后手段**，历史栏不接受）/ `reset`（整栏目替换，仅限空栏目或明确重排）。`before` 锚点必须来自**该栏目读取器**的结果，三级匹配：逐字行 → 归一化行（折叠空白与全/半角标点）→ 归一化行内子串；未命中 → 报错并回传**该栏目当前全文**（≤400 行）供重锚；不唯一 → 报错（列出命中行号）；同调用内按顺序应用（先插入的内容可被后续编辑引用）；事务化（任一失败整体不提交）；**历史**变更后必须恰含一条本轮（轮次 = N）条目 `- {轮次} \| {时间} \| {记忆内容}`（Lv.1 在**维护回合**用 `op=append` 落入**恰好一条**本轮条目，{时间} = 正文 `## 当前时间`；条目解析新旧格式兼容）。**档位驱动的合并**：档位 > 0 且未合并条目达到 `2×档位` 时，维护回合指令会要求把最旧的若干条用区间形态 `- {开头轮} - {结尾轮} \| {开头轮时间} ~ {结尾轮时间} \| {记忆内容}` 合并（一个区间一条 `op=set`，`before` = 该区间各条原文用 `\n` 连接），合并未落地时维护不判完成（回合数用尽转常驻提示）；工具描述只在「本轮指令要求合并时」才引导该手法。旧的 `line` 行号参数已被移除，携带时明确报错引导改用 `before` / `append` |

**状态编辑只允许在第二步维护执行**：第一步（调研 / 正文）对历史编辑器的调用
一律拒绝，避免正文前抢写记忆导致重复条目。**当前时间不设工具**：属于正文
`## 当前时间` 小节（正文的合法输出段），应用从正文解析写入工作副本
（缺失则沿用上一轮时间），不参与缺口判定。

### 状态快照的获取方式（模型自取，不做预置）

状态不再由 app 预置进上下文，而是模型**主动调用对应栏目读取器**获取
（结果以 `function_call_output` 形态进入上下文）：

```
<<<NARRCHAT_STATE round=N>>>
这是应用侧状态真值（刚读取回来的）。`before` 锚点必须从本块逐字复制；禁止把本块重复输出到回复里。
<worldState>…</worldState>       ← 只有被请求的那一栏
<<<END_NARRCHAT_STATE>>>
```

- 为什么这么做：预置注入时模型把快照里的 md 块当成**可模仿的输出格式**，
  要么照格式堆进正文，要么写完正文再调工具，困惑「我不是都写了吗」；
- 为什么按栏目拆分：**读多少给多少**、**锚点归属唯一**、**按需注册**；
- 为什么维护回合不再读取：状态只在**编辑**时改变，写正文不影响它，因此
  此前读到的那一份结果就是维护回合唯一正确的锚点来源——它已在上下文中。
  提示词（契约 + 维护回合指令）与执行器护栏（`_refusedRepeatRead`，作用于
  **维护回合**）共同保证「直接改」；Lv.1 在**调研回合**读一次（历史的唯一来源），
  维护回合复用，重复读取被护栏拒绝；
- 上下文里**每栏只保留最新一份**读取结果：新的**成功**读取才剔除该栏旧条目
  （`_pruneStaleReadState` 按工具名剔除），每轮输入不随修复回合数膨胀。

## 缺口判定（`state/state_coverage.dart`）

`inspectState` 只看应用侧事实（`touchedSections` / `declaredUnchanged` /
`sectionText` 与 `sectionBaseText` 比对 / 出场角色块是否逐字节未变），产出
`StateGap` 列表：每个缺口同时给出面向模型的 `modelText`（**简明中文**、
不加语言标记，并**点名该栏对应的编辑器**；保留 `<worldState>` 一类小写块标签，
维护回合清单的优先级排序依赖它）与面向用户的 `uiText`。
模型说「已更新」不算更新。判定范围由调用方传入：当前档位只判定历史、关闭角色块
懒修改检查（世界 / 角色由正文携带）。三栏判定与 `lazyCharacters` 懒修改检查作为
框架保留，当前不触发。当前时间属于正文，不参与判定。

## 提示词里的通用规则（仅 Agent 档位）

- **读取只做一次**：在**调研回合**读（`narrchat_readHistory`）；读到的那一份
  结果即后续唯一锚点来源，维护回合的重复读取会被护栏拒绝，并要求**第一个维护
  回合就完成**（直接编辑）；
- **不约束思考链**：任何模式都不限定思考的语言与写法；但功能性步骤照旧
  （调研回合读史、调研结束后**立刻**写正文、记忆只在第二步维护）。
  回合指令文案见 `prompt_v2_sections.dart`。

## 命名规范

自定义函数工具统一使用 `narrchat_` 前缀 + 小驼峰（如 `narrchat_webSearch`、
`narrchat_editWorldState`），原因：

- 与厂商内置工具（`web_search` 等服务端工具、`custom` 类型保留名 `apply_patch` 等）**零命名重叠**；
- 遵循 OpenAI 兼容 function 命名规范（`^[a-zA-Z0-9_-]{1,64}$`，建议控制在 50 字符以内）；
- 一眼可辨"这是 NarrChat 应用侧工具"。

状态工具的**名字单一真源**在 `state/state_tool_names.dart`（提示词契约、工具注册、
缺口指令都引用它）；栏目 ↔ 工具名的映射由 `state_tools.dart` 的
`agentReadToolName` / `agentEditToolName` 提供。六个工具名都保留，当前只注册
历史一读一写；其余四个是后续档位的框架。

注意：文件 / 类名（`web_search_tool.dart` / `WebSearchTool`）为**公共代码面**，与线上工具名无关，保持稳定不动。

## 扩展指引（新增工具）

1. 实现 `NarrAgentTool`（参考 `state/state_tools.dart` / `web_search_tool.dart`，工具名按上述规范，并声明 `activityType` 与 `isReadOnly`）；
2. 注册：Chat 搜索工具在 `RoundProvider._makeAgentTools`；Agent 状态工具在
   `buildStateTools`（`state/state_tools.dart`，按 `AgentModeProfile.toolSections`
   传入栏目清单，当前清单只有历史），Agent 工具集 = 注册的状态工具 + 联网工具
   （各步共用同一份 `tools`，保证前缀逐字节一致）；
3. 新增**档位**：扩展 `AgentModeLevel` + `AgentModeProfile`（提示词模式、
   工具栏目、正文禁用标题、历史消息形态都从档案取）；六工具与多栏目缺口判定
   可以直接复用，只要把对应栏目放进 `toolSections`。若新增**栏目**，还需扩展
   `AgentStateSection`（工作副本字段 / 渲染 / 校验）与提示词契约；
4. 新增 / 更新测试：`test/agent_runner_test.dart`（Chat 循环与失败语义）、
   `test/agent_round_runner_test.dart`（两步流程 / 档位 / 降级 /
   链式 / 正文采纳制）、`test/agent_state_working_copy_test.dart`（锚点唯一匹配 /
   字节级保留 / `noChange`+`reason`）、`test/state_tools_test.dart`（六工具契约，
   框架用例）、
   `test/state_coverage_test.dart`（缺口与判定范围）、`test/agent_round_test.dart`
   与 `test/agent_over_chat_test.dart`（provider 集成：两步请求体与统一入库）、
   `test/raw_dialog_test.dart`（Agent 路径与 RAW 捕获），使用
   `test/helpers/fakes.dart` 公共替身；
5. 更新本文档与 `docs/agent_mode.md`。
