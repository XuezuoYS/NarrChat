# Prompt 取用接口（`prompt_interface`）

本文档说明「发送给 AI 的文本与工具」的**唯一取用入口**——分源接口套件
`lib/services/prompt_interface.dart` 及其 v1 转发实现
`lib/services/prompt_interface_v1.dart`。

目的：把「本轮要发给 AI 什么内容」从「怎么发」（线路 / 报文 / 参数 / 图片 /
历史消息数组）里切出来，作为将来替换 **v2 提示词**（见 `docs/ai_prompt_v2.md`）
的**唯一替换点**。

> 本轮范围：只建接口 + v1 转发实现 + 锁定测试 + 本文档。
> **不实现 v2 提示词**，**不改调用链**（`RoundProvider` 等的取用路径与输出保持原样）。

## 一、覆盖范围

| | 内容 | 由谁负责 |
|---|---|---|
| ✅ 覆盖 | **拼合后**的 system（instructions）文本 | 接口 `system()` |
| ✅ 覆盖 | **拼合后**的本轮 user 消息文本 | 接口 `user()` |
| ✅ 覆盖 | Agent **阶段帧指令**（准备 / 记忆 / 正文 / 维护 / 修复） | 接口 `stage*()` |
| ✅ 覆盖 | **工具集**（状态工具 + 联网工具；工具定义即文本） | 接口 `tools()` |
| ❌ 不覆盖 | 历史 `messages` 数组的拼装形态 | 仍由 `PromptBuilder.buildHistoryMessages` 负责 |
| ❌ 不覆盖 | 请求体 / 线路（chat / responses）/ 采样参数 / `tools` 数组字段拼装 | 仍由 `RoundProvider` + `wire_adapters` 负责 |
| ❌ 不覆盖 | vision 图片 content 多部分拼装 | 仍由 `RoundProvider` 负责 |
| ❌ 不覆盖 | 世界书关键词扫描、Mod 解析与筛选 | 仍由 `WorldBookScanner` / `ModProvider` 负责 |
| ❌ 不覆盖 | 工具的执行、失败语义与 UI 回调实现 | 仍由各 `NarrAgentTool` / `RoundProvider` 负责 |

## 二、接口套件

### 分源接口（`prompt_interface.dart`）

| 接口 | 方法 | 说明 |
|---|---|---|
| `SystemPromptSource` | `String system(PromptRequest)` | 拼合完成的 system；调用方不得再增删改写 |
| `UserPromptSource` | `String user(PromptRequest)` | 拼合完成的本轮 user 消息（历史 user / assistant 不在此列） |
| `StageDirectiveSource` | `stagePrepare` / `stageMemory` / `stageStory` / `stageState`（均返回 `String`） | 该帧 `role: user` 消息的正文；调用方包成消息条目。准备 / 记忆仅 Lv.1 使用，正文帧 Lv.2 不追加，维护帧两档共用 |
| `AgentToolSource` | `List<NarrAgentTool> tools(AgentToolsRequest)` | 本轮工具清单；**顺序即请求体 `tools` 数组顺序**（前缀一致性要求稳定） |

聚合门面：

```dart
abstract interface class PromptInterface
    implements SystemPromptSource, UserPromptSource,
               StageDirectiveSource, AgentToolSource {}
```

### 请求对象（只搬运已取好的数据，不负责取数）

`PromptRequest`（system / user）：

| 字段 | 说明 |
|---|---|
| `book` | 本书（书籍名 / 分类 / 设定 / 文笔 / 角色类别 / 记忆合并档位都在内） |
| `mode` | `PromptMode`：Chat / Agent Lv.1 / Agent Lv.2（`format` 便捷取 `mode.format`） |
| `lastRound` | 上一轮（首轮 null）：上轮时间、状态快照、记忆总结的来源 |
| `userInput` | 本轮用户输入 |
| `worldBookEntries` | 已按关键词命中筛好的世界书条目文本（扫描在调用方完成） |
| `mods` | 启用的 Mod 束（system / 前置词 / 后置词 / 世界书） |

`AgentStageRequest`（阶段帧指令）：`level`、`workingCopy`（记忆帧判定本轮条目 /
合并是否落地）、`memoryMergePlan`、`first`（主帧 / 修复帧）、`problems`（维护帧
待修清单）。

`AgentToolsRequest`（工具集）：`level`（`off` = 无状态工具的 Chat 联网循环）、
`workingCopy`（状态工具绑定对象；null = 不构造状态工具）、`useSearch`、`search`
（抓取服务）、`webSearch` / `fetchPage`（注入替身，非空优先）、`handlers`
（联网工具过程回调；null = 预览路径）。

### 唯一绑定

```dart
/// 替换 v2 时只改这一行。
const PromptInterface promptInterface = PromptInterfaceV1();
```

不做运行时选择、不做注册表：调用方只依赖 `PromptInterface`，切换实现时改这一行。

## 三、v1 实现 = 逐字转发

`PromptInterfaceV1` 不含任何提示词文案，只做映射，保证接口输出与线上行为
**逐字节一致**：

| 接口方法 | 转发目标 |
|---|---|
| `system` | `PromptSections.buildSystemPrompt` |
| `user` | `PromptSections.buildUserPrompt` |
| `stagePrepare` / `stageStory` | `AgentLv1PromptFormat.prepareNote` / `storyNote` |
| `stageMemory` / `stageState` | `AgentStageDirectives.memoryDirective` / `stateDirective` |
| `tools` | `buildStateTools`（档位栏目）+ `buildDefaultAgentTools`（联网） |

错误语义（显式报错，不静默回落）：

- `stageMemory` 缺 `workingCopy` → `ArgumentError`；
- `tools` 启用联网却既没有抓取服务、也没有同时注入两个替身 → `ArgumentError`。

### 为消除重复而做的两处抽取

| 新文件 | 作用 | 同时被谁使用 |
|---|---|---|
| `lib/services/agent/agent_stage_directives.dart` | Agent 阶段帧指令的**纯构建器**（记忆帧 / 维护帧 / 修复帧文案与清单排序、条数上限） | `AgentRoundRunner`（执行器）与 `prompt_interface_v1` |
| `lib/services/agent/agent_default_tools.dart` | 默认联网工具（搜索 → 打开页）的**公共工厂**（含过程回调接线） | `RoundProvider._makeAgentTools` 与 `prompt_interface_v1` |

抽取是**行为保持**的：文案与构造顺序逐字节搬迁，执行器 / Provider 改为调用同一份
实现（单一真源），没有新增分支。

## 四、契约与约定

- 调用方**只调用** `PromptInterface` 上的方法；不得绕过接口直接调用被覆盖的实现器
  （否则 v2 切换时必然漏改）。
- 接口返回的是**最终文本**：线路层只负责把它放进 `system` 消息 / `instructions`
  字段 / `role: user` 消息，不再拼接或改写。
- `tools` 的**顺序与集合必须稳定**（阶段之间、轮次之间一致），否则服务商上下文
  前缀失效、缓存整段不命中。
- 接口**不新增行为**：一切提示词文案的改动都发生在实现层（v1 / v2），接口层只做路由。

## 五、切换到 v2 的步骤

1. 新增 `lib/services/prompt_v2_build.dart`，实现同一个 `PromptInterface`
   （按 `docs/ai_prompt_v2.md` 的总模板 / 格式模板填槽位：总协议 system、总协议2
   user、Mod 槽位、阶段帧指令、工具契约等）；
2. 把 `prompt_interface.dart` 末尾的 `promptInterface` 绑定改到 v2 实现；
3. 调用方与依赖**不动**；`PromptInterfaceV1` 保留，可随时回退。

## 六、接入调用链（未来工作，本轮未做）

现状：接口与 v1 实现已可用并受测试守护，但**生产路径仍经旧调用链**——本轮只做了
上文两处抽取，未把 `RoundProvider` 改走接口。

将来接入时，替换点集中在这几处（均按 `AgentModeProfile` / `PromptMode` 取模式）：

| 位置 | 现在 | 接入后 |
|---|---|---|
| `RoundProvider` 组装 system + user | `_promptBuilder.build(...)` | `promptInterface.system(request)` / `.user(request)` |
| `RoundProvider` 预览与单轮工具集 | `buildStateTools(...)` + `_makeAgentTools(...)` | `promptInterface.tools(request)` |
| `RoundProvider` 联网循环工具集 | `_makeAgentTools(gen)` | 同上 |
| `AgentRoundRunner` 阶段帧指令 | `AgentLv1PromptFormat.*` + `AgentStageDirectives.*` | `promptInterface.stage*()` |

历史 `messages` 数组、报文与图片拼装**保持不动**（不在接口范围内）。

## 七、测试

| 测试文件 | 锁住什么 |
|---|---|
| `test/prompt_interface_test.dart` | 接口 system / user **逐字节等于**线上 `PromptBuilder`（三个模式）；工具集按档位 × 联网的正确组合、顺序与 `same` 实例注入；缺依赖报错；阶段帧指令与真源同源；绑定当前为 v1 |
| `test/agent_stage_directives_test.dart` | 阶段帧指令行为：记忆帧三种阶段说明、合并未落地 / 已落地的差异、维护帧档位文案、清单排序（记忆 → 角色 → 世界 → 其他）、一帧至多 8 条、空清单只发指令头 |

提示词文案本身的断言仍在 `test/prompt_builder_test.dart`、`test/prompt_formats_test.dart`
（接口层不重复断言文案，只锁取用路由）。

## 八、文件一览

| 文件 | 角色 |
|---|---|
| `lib/services/prompt_interface.dart` | 契约：分源接口 + 聚合门面 + 请求对象 + 唯一绑定 |
| `lib/services/prompt_interface_v1.dart` | v1 转发实现（不含文案） |
| `lib/services/agent/agent_stage_directives.dart` | 阶段帧指令唯一真源（执行器与接口共用） |
| `lib/services/agent/agent_default_tools.dart` | 联网工具公共工厂（Provider 与接口共用） |
| `lib/services/prompt_sections.dart` / `prompt_formats.dart` / `prompt_builder.dart` | v1 文案与组装（接口的转发目标，本次未改文案） |
