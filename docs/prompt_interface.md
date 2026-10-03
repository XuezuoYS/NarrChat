# Prompt 取用接口（`prompt_interface`）

本文档说明「发送给 AI 的文本与工具」的**唯一取用入口**——分源接口套件
`lib/services/prompt_interface.dart`，以及两套实现：

| 实现 | 文件 | 状态 |
|---|---|---|
| **v2** | `prompt_v2_build.dart` + `prompt_v2_sections.dart` + `prompt_v2_tools.dart` | **当前生效**（按 `docs/ai_prompt_v2.md` 的总模板与格式模板） |
| v1 | `prompt_interface_v1.dart`（转发 `prompt_sections.dart` / `prompt_formats.dart` / `agent_stage_directives.dart`） | 回退路径，行为冻结、由锁测试守护 |

目的：把「本轮要发给 AI 什么内容」与「怎么发」（线路 / 报文 / 参数 / 图片 / 历史消息）
彻底分开——提示词换版只改一处绑定，报文与历史不受影响。

## 一、覆盖范围

| | 内容 | 由谁负责 |
|---|---|---|
| ✅ | **拼合后**的 system（instructions）文本 | 接口 `system()` |
| ✅ | **拼合后**的本轮 user 消息文本 | 接口 `user()` |
| ✅ | Agent **阶段帧指令**（准备 / 记忆 / 正文 / 维护 / 修复） | 接口 `stage*()` |
| ✅ | **工具集**（状态工具 + 联网工具；工具定义即文本） | 接口 `tools()` |
| ❌ | **历史 messages + 请求体**（同属请求组装侧——**历史跟随报文**） | `wire_messages.dart`（历史轮次 + 图片 content）+ `RoundProvider` + `wire_adapters` + `ai_request_body_builder`：这一侧只消费接口产出的纯文本 / 工具清单，不引用任何提示词模块 |
| ❌ | vision 图片 content 多部分拼装 | `RoundProvider` |
| ❌ | 世界书关键词扫描、Mod 解析与筛选 | `WorldBookScanner` / `ModProvider` |
| ❌ | 工具的执行、失败语义与 UI 回调实现 | 各 `NarrAgentTool` / `RoundProvider` |

## 二、接口套件

### 分源接口（`prompt_interface.dart`）

| 接口 | 方法 | 说明 |
|---|---|---|
| `SystemPromptSource` | `String system(PromptRequest)` | 拼合完成的 system；调用方不得再增删改写 |
| `UserPromptSource` | `String user(PromptRequest)` | 拼合完成的本轮 user 消息（历史消息不在此列） |
| `StageDirectiveSource` | `stagePrepare` / `stageMemory` / `stageStory` / `stageState` | 该帧 `role: user` 消息的正文；准备 / 记忆仅 Lv.1，正文帧 Lv.2 不追加，维护帧两档共用 |
| `AgentToolSource` | `List<NarrAgentTool> tools(AgentToolsRequest)` | 本轮工具清单；**顺序即请求体 `tools` 数组顺序**（前缀一致性要求稳定） |

聚合门面：`abstract interface class PromptInterface implements
SystemPromptSource, UserPromptSource, StageDirectiveSource, AgentToolSource {}`。

### 请求对象（只搬运已取好的数据，不负责取数）

- `PromptRequest`：`book` / `mode`（Chat、Lv.1、Lv.2，`format` 派生）/ `lastRound` /
  `userInput` / `worldBookEntries`（已按关键词筛好）/ `mods`；
- `AgentStageRequest`：`level` / `workingCopy`（记忆与维护帧判定条目与合并）/ `memoryMergePlan` /
  `first`（主帧 / 修复帧）/ `problems`（维护帧待修清单）；
- `AgentToolsRequest`：`level` / `workingCopy`（状态工具绑定对象，null = 不构造）/
  `useSearch` / `search` / `webSearch` / `fetchPage`（替身优先）/ `handlers`（过程回调）。

### 唯一绑定

```dart
/// 当前绑定 v2（文本 = PromptV2Build，工具 = prompt_v2_tools）；
/// 换实现只改这一行（v1 回退 = PromptInterfaceV1()）。
const PromptInterface promptInterface = PromptV2();
```

契约分两半，便于纯 Dart 环境只取文本层：

| 文件 | 内容 | Flutter 依赖 |
|---|---|---|
| `prompt_text.dart` | `PromptRequest` / `AgentStageRequest` + system / user / 阶段帧三个源接口 | 无 |
| `prompt_interface.dart` | `AgentToolsRequest` / `AgentToolSource` + `PromptInterface` 聚合 + `PromptV2` 聚合实现 + 绑定 | 有（工具类型带抓取服务） |

## 三、v2 实现

### 三个文件的分工

| 文件 | 职责 |
|---|---|
| `prompt_v2_sections.dart` | **全部 v2 文案**：固定行（人设 / 沙箱位置 / 服从 / 完整性 / 收尾）、共用契约、记忆条目格式与合并策略、三模式 system 与 user 契约、阶段帧指令、状态工具契约 |
| `prompt_v2_build.dart` | **拼接顺序与空块删除**：按总模板拼 system、按新建轮模板拼 user、按阶段给帧指令；实现 `prompt_text.dart` 的三个文本源（纯 Dart 依赖） |
| `prompt_v2_tools.dart` | **工具清单**：`listPromptTools(...)`，档位栏目 + 联网开关 → 工具列表（v1 / v2 共用同一份） |

设计口径（与 `docs/ai_prompt_v2.md` 一致）：

- 外层用 `#` 一级标题分区、区域之间 `---` 分隔；块内分条只用 `- `（不用数字序号）；
- **无内容即删块**：可选项为空就连标题一起删（书籍设定 / 世界书 / 角色状态栏协议 /
  文笔参考范文 / 文笔要求行 / Mod / 上下文字段），不写「（无）」「未设置」；
- 撤销中英双语：简明中文、口语化；英文只保留工具名、状态块标签与
  `[State-maintenance turn]` 回合标记；
- 不举例：只用 `{}` 占位符表达形状；
- 不约束思考链格式（不要求思考语言、不要求把思考写出来），但保留功能性要求
  （读史一次、**先定大纲**、记忆先于正文、按序四步）。

### v2 各槽位与来源

| 总模板槽位 | 内容来源 |
|---|---|
| 人设 / 沙箱位置 / 服从 / 收尾 | `PromptV2Sections` 固定行 |
| 书籍名 / 分类 / 文笔要求 | `PromptRequest.book`（空则整行不注入） |
| Mod system | `PromptRequest.mods.systemPrompts`（**抬升**到 `# 总协议：` 之前） |
| `# 总协议：` | 共用契约 + 记忆条目格式 + 模式契约 +（Agent）状态工具契约 + 记忆合并策略 |
| `# 书籍设定和要求：` / `# 世界书：` | `book.baseSetting` / `worldBookEntries` + `mods.worldBooks` |
| `# 角色状态栏协议：` | `book.roleHierarchy` + `book.roleCategories`（空的小节整块删除） |
| `# 角色状态完整性要求：` / `# 执行惩罚和奖励：` | 固定文本 |
| `# 文笔参考范文：` | `book.writingStyle`（空 → 整个板块删除） |
| user：轮次 / 上轮时间 / 前置词 / 主人输入 / 后置词 / `# 总协议2` | `lastRound`、`book.globalPre/PostPrompt`、`mods.pre/postPrompts`、`userInput`、三模式 user 契约 |
| user（Chat）：本轮记忆合并指令 | `planMemoryMerge(...)`（Agent 走阶段帧） |

> 「修改轮」（按轮定向重写）暂无实现；落地时复用 `PromptV2Build.user`，只把标题换成
> 「重写第 {轮次} 轮」、上轮时间换成本轮时间。

## 四、v1 回退实现

`PromptInterfaceV1` 不含任何文案，逐字转发旧组装流程：

| 接口方法 | 转发目标 |
|---|---|
| `system` / `user` | `PromptSections.buildSystemPrompt` / `buildUserPrompt` |
| `stagePrepare` / `stageStory` | `AgentLv1PromptFormat.prepareNote` / `storyNote` |
| `stageMemory` / `stageState` | `AgentStageDirectives.memoryDirective` / `stateDirective`（含未落地的合并指令行） |
| `tools` | `listPromptTools`（档位栏目 + 联网） |

错误语义（两版一致，不静默回落）：`stageMemory` 缺 `workingCopy` → `ArgumentError`；
`tools` 启用联网却既无抓取服务、也无两个替身 → `ArgumentError`。

## 五、工具清单

`prompt_v2_tools.dart` 的 `listPromptTools` 是**唯一实现**（v1 / v2 共用）：

- 状态工具：按档位栏目现构（`buildStateTools(workingCopy, sections)`），绑定本轮工作副本；
- 联网工具：`useSearch` 时叠加（搜索 → 打开页，`buildDefaultAgentTools`），替身优先；
- **顺序固定**（状态工具在前、联网在后），任何变化都会改动请求前缀、使服务商上下文缓存失效；
- 工具定义（名字 / schema / description）**已迁移到 v2 口径**：`description` 与参数说明
  一律简明中文，英文只保留工具名 / 状态块标签 / `op` 取值（见 `docs/agent_tools.md`）；
  v1 回退路径复用同一份工具文案（工具类不再维护双语）。

## 六、调用链接入现状（已完成）

| 位置 | 现在 |
|---|---|
| `RoundProvider._assembleRoundRequest` | `promptInterface.system(request)` / `promptInterface.user(request)` |
| `RoundProvider._agentTools(...)` | `promptInterface.tools(request)`（预览、Chat 联网循环、Agent 单轮三处共用） |
| `RoundProvider` 历史消息 | `buildHistoryMessages(...)`（`wire_messages.dart`，与报文同侧、不经提示词模块） |
| `AgentRoundRunner._runPrepareStage` / `_runMemoryStage` / `_runStoryStage` / `_runStateStage` | `_prompt.stagePrepare / stageMemory / stageStory / stageState` |

报文层（`_agentBody` / `_agentChatBody` / `_makeBodyBuilder` / `wire_adapters`）只接收
接口产出的**纯文本与工具清单**，不认识提示词模块——即「报文拼装与提示词解耦」。

纯 Dart 预览：`dart run tool/preview_prompt.dart` 只引用 `prompt_text.dart` +
`prompt_v2_build.dart`（不含工具 / 抓取服务），因此在 Flutter 之外也能打印 v2 真实
system / user 文本；工具清单与阶段帧请在应用内用「预览请求体」核对。

## 七、切换 / 新增版本

1. 新增实现文件（如 `prompt_v3_build.dart`）实现同一个 `PromptInterface`；
2. 改 `prompt_interface.dart` 末尾的 `promptInterface` 绑定；
3. 调用方与报文 / 历史层**不动**；旧实现保留即可回退。

契约约定：调用方**只调用** `PromptInterface` 上的方法，不得绕过接口直接调用被覆盖的
实现器（否则换版必然漏改）；接口返回的是最终文本，调用方不再拼接或改写。

## 八、测试

| 测试文件 | 锁住什么 |
|---|---|
| `test/prompt_interface_test.dart` | 绑定为 v2；v2 总模板区域 / `---` 分隔 / 空块即删 / 模式契约差异 / Mod 抬升 / 合并档位 / user 注入与合并指令 / 工具路由 / 阶段帧文案；**v1 回退路径**的 system / user / 工具 / 阶段帧与旧组装流程逐字节一致 |
| `test/agent_stage_directives_test.dart` | v1 阶段帧指令行为（记忆帧三种说明、清单排序与上限、维护帧档位文案） |
| `test/wire_messages_test.dart` | 历史 messages 拼装（三种 assistant 形态、占位、vision 图片）——报文侧 |
| `test/prompt_builder_test.dart` / `prompt_formats_test.dart` | v1 文案与格式规格（v1 回退路径的文案断言） |

## 九、文件一览

| 文件 | 角色 |
|---|---|
| `lib/services/prompt_text.dart` | **文本契约**（请求对象 + 文本三源，纯 Dart，脚本 / CLI 可直接引用） |
| `lib/services/prompt_interface.dart` | 工具契约 + `PromptInterface` 聚合 + `PromptV2` 聚合实现 + 唯一绑定 |
| `lib/services/prompt_v2_build.dart` | v2 文本实现（总模板 / 新建轮模板 / 阶段帧；纯 Dart 依赖） |
| `lib/services/prompt_v2_sections.dart` | v2 文案真源 |
| `lib/services/prompt_v2_tools.dart` | 工具清单（v1 / v2 共用） |
| `lib/services/prompt_interface_v1.dart` | v1 回退实现（逐字转发） |
| `lib/services/wire_messages.dart` | 报文侧消息组装：历史 messages + 图片 content（历史跟随报文，与提示词接口解耦） |
| `lib/services/prompt_sections.dart` / `prompt_formats.dart` / `prompt_builder.dart` | v1 文案与组装（回退路径） |
| `lib/services/agent/agent_stage_directives.dart` | v1 阶段帧指令真源（执行器与 v1 实现共用） |
| `lib/services/agent/agent_default_tools.dart` | 联网工具公共工厂 |
| `docs/ai_prompt_v2.md` | v2 提示词设计（总模板 / 格式模板，文案的评审真源） |
