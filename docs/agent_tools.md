# Agent 工具说明

本文档描述 NarrChat 的 Agent 工具（`lib/services/agent/`）：

## 工具接口与循环机制

- 接口：`NarrAgentTool`（`narr_agent_tool.dart`）——`name`（模型调用名）/ `description`（指导模型何时调用）/ `parameters`（JSON Schema）/ `run(arguments)`（执行并返回文本结果）/ `activityType`（UI 活动类型：`searching` / `fetching` / `tooling`）。
- 循环器有两种：
  - `AgentRunner`（`agent_runner.dart`）：Chat 模式「联网搜索」循环（首轮带工具 → 搜索/抓取 → 回传 → 再生成），`maxIterations = 30`；
  - `AgentRoundRunner`（`agent_round_runner.dart`）：AGENT 模式单轮执行器——主响应（正文 + 状态工具同响应）→ 校验 → 失败走修复轮（≤2 次）→ 超出钳制跳过；支持有状态链式续接（`previous_response_id`，需平台开启）。**正文采纳制**：本轮正文 = 首个产出正文的帧，修复 / 补充帧复读的正文被丢弃（修复轮只允许工具调用）。
- 失败语义：
  - `success: false`：普通工具故障（网络/超时/校验失败/无结果），错误信息回传模型**继续执行**（状态工具失败即校验失败 → 修复轮）；
  - `refused: true`：页面拒绝访问（HTTP 4xx/5xx），**不计入**工具连续失败次数（UI 黄色 ✕）；
  - 连续失败 3 次：该工具停用，回传模型"请勿再使用"，避免死循环。
- UI 活动映射：`AgentActivityType`（`turn` / `searching` / `fetching` / `tooling`）驱动聊天页的搜索框 / 打开页事件；`AgentEvent`（thinking / search / fetch / tool / hop）驱动时间线展示。状态工具框在「调用间隙」可见（如工具轮完成 → 正文轮进行中）。

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

### 状态工具（`state_tools.dart`，仅 AGENT 模式注入）

两个 `narrchat_*` 状态工具全部作用于本轮「工作副本」（`AgentStateWorkingCopy`），
以**锚定式编辑**（编辑文件式）方式维护：模型只提供**变更的行**，未触及的行
字节级保留；工具调用在流式响应中**即时预览**（卡片随 `output_item.added` /
参数增量出现），执行完成后展示成功 / 错误结果。

| 工具 | 参数 | 语义 / 校验 |
|---|---|---|
| `narrchat_editSection` | `section`（worldState / characterState / memorySummary）+ `edits[]` | **锚定式**行编辑：`op=append`（newLine 追加到栏目末尾，记忆条目固定用）/ `set`（`before` 整行/连续多行逐字锚定 → `newLine` 替换）/ `insertAfter`（`before` 锚定 → 其后插入）/ `delete`（`before` 锚定删除）/ `noChange`（本轮无变化声明）/ `reset`（整栏目替换，仅限空栏目或明确重排）。`before` 必须与当前快照**逐字相同**且**唯一**：未命中 → 报错（提示逐字复制，含当前行数）；不唯一 → 报错（列出命中行号，引导补充上下文）；同调用内按顺序应用（锚点在应用时刻解析，先插入的内容可被后续编辑引用）；事务化（任一失败整体不提交）；记忆总结变更后必须含本轮（第 N 轮）条目，且不许 noChange；旧的 `line` 行号参数已被移除，携带时明确报错引导改用 `before` / `append` |
| `narrchat_advanceTime` | `time` | 仅校验**存在**（非空）；格式由模型按剧情自行组织 |

## 命名规范

自定义函数工具统一使用 `narrchat_` 前缀 + 小驼峰（如 `narrchat_webSearch`），原因：

- 与厂商内置工具（`web_search` 等服务端工具、`custom` 类型保留名 `apply_patch` 等）**零命名重叠**；
- 遵循 OpenAI 兼容 function 命名规范（`^[a-zA-Z0-9_-]{1,64}$`，建议控制在 50 字符以内）；
- 一眼可辨"这是 NarrChat 应用侧工具"。

注意：文件 / 类名（`web_search_tool.dart` / `WebSearchTool`）为**公共代码面**，与线上工具名无关，保持稳定不动。

## 扩展指引（新增工具）

1. 实现 `NarrAgentTool`（参考 `state_tools.dart` / `web_search_tool.dart`，工具名按上述规范，并声明 `activityType`）；
2. 注册：Chat 搜索工具在 `RoundProvider._makeAgentTools`；AGENT 状态工具在
   `buildStateTools`（`state_tools.dart`），AGENT 模式工具集 = 状态工具 + 可选搜索工具；
3. 新增 / 更新测试：`test/agent_runner_test.dart`（Chat 循环与失败语义）、
   `test/agent_round_runner_test.dart`（AGENT 单轮 / 修复轮 / 链式 /
   正文采纳制）、`test/agent_state_working_copy_test.dart`（锚点唯一匹配 /
   字节级保留）、`test/state_tools_test.dart`（工具契约与锚点编辑）、
   `test/raw_dialog_test.dart`（Agent 路径与 RAW 捕获），使用
   `test/helpers/fakes.dart` 公共替身；
4. 更新本文档与 `docs/agent_mode.md`。
