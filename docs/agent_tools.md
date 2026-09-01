# Agent 工具说明

本文档描述 NarrChat 的 Agent 工具（`lib/services/agent/`）

## 工具接口与循环机制

- 接口：`NarrAgentTool`（`narr_agent_tool.dart`）——`name`（模型调用名）/ `description`（指导模型何时调用）/ `parameters`（JSON Schema）/ `run(arguments)`（执行并返回文本结果）。
- 循环：`AgentRunner.run`（`agent_runner.dart`），`maxIterations = 30`。
- 失败语义：
  - `success: false`：普通工具故障（网络/超时/无结果），错误信息回传模型**继续执行**；
  - `refused: true`：页面拒绝访问（HTTP 4xx/5xx），**不计入**工具连续失败次数（UI 黄色 ✕）；
  - 连续失败 3 次：该工具停用，回传模型"请勿再使用"，避免死循环。
- UI 活动映射：`AgentActivityType`（`turn` / `searching` / `fetching`）驱动聊天页的搜索框 / 打开页事件；`AgentEvent`（thinking / search / fetch / hop）驱动时间线展示。

## 工具清单（当前）

### `narrchat_webSearch`（`WebSearchTool`）

联网搜索工具：通过自研 `HtmlSearchService.search` 抓取搜索引擎结果。

- 参数：`query`（string，必填，关键词尽量简洁具体）
- 行为：返回最多 20 条结果的标题、链接与摘要；结果为空或失败时返回 `success: false` 并回传错误信息。
- 约束：`description` 与工具结果中明确要求——调用后必须紧接着用 `narrchat_webFetchPage` 打开最相关的 1~3 个结果页面阅读正文，禁止只依赖摘要。
- 注入时机：仅当用户开启「联网搜索」时注入（系统提示词追加【联网搜索】指令）；未开启时不注入任何工具。

### `narrchat_webFetchPage`（`FetchPageTool`）

打开网页工具：通过 `HtmlSearchService.fetchPageText` 抓取可读正文（截取前 30000 字符）。

- 参数：`url`（string，必填，完整的 http(s) 链接，一般取自搜索结果）
- 行为：返回页面正文文本供模型深入阅读；重定向跳转通过 `onHop` 回调流式展示（跳转链 UI）。
- 拒绝语义：HTTP 4xx/5xx 返回 `refused: true`（黄色 ✕，不计入连续失败），错误信息提示换用其它结果页面；网络/超时等其它失败走 `success: false`。
- 定位：它是 `narrchat_webSearch` 的**配套下游**——"搜索 → 打开页面 → 提炼细节 → 创作"是既定流程，模型不允许跳过打开页面环节。

## 命名规范

自定义函数工具统一使用 `narrchat_` 前缀 + 小驼峰（如 `narrchat_webSearch`），原因：

- 与厂商内置工具（`web_search` 等服务端工具、`custom` 类型保留名 `apply_patch` 等）**零命名重叠**；
- 遵循 OpenAI 兼容 function 命名规范（`^[a-zA-Z0-9_-]{1,64}$`，建议控制在 50 字符以内）；
- 一眼可辨"这是 NarrChat 应用侧工具"。

注意：文件 / 类名（`web_search_tool.dart` / `WebSearchTool`）为**公共代码面**，与线上工具名无关，保持稳定不动。

## 扩展指引（新增工具）

1. 实现 `NarrAgentTool`（参考 `web_search_tool.dart`，工具名按上述规范）；
2. 在 `RoundProvider._makeAgentTools` 注册（与搜索工具同一执行通道）；
3. 新增 / 更新测试：`test/agent_runner_test.dart`（循环与失败语义）、`test/raw_dialog_test.dart`（Agent 路径与 RAW 捕获），使用 `test/helpers/fakes.dart` 公共替身；
4. 更新本文档（工具清单、参数、约束）。
