# Prompt 取用接口（`prompt_interface`）

本文档说明「发送给 AI 的文本与工具」的**唯一取用入口**——分源接口套件
`lib/services/prompt_interface.dart`，以及唯一实现（v2，按 `docs/ai_prompt_v2.md`
的总模板与格式模板组装）：

| 实现 | 文件 |
|---|---|
| **v2（当前唯一）** | `prompt_v2_build.dart`（文本）+ `prompt_v2_sections.dart`（文案）+ `prompt_v2_tools.dart`（工具清单） |

> v1 提示词代码（`prompt_sections` / `prompt_formats` / `prompt_builder` /
> `prompt_interface_v1` / `agent_stage_directives`）**已删除**，不再有回退路径。

目的：把「本轮要发给 AI 什么内容」与「怎么发」（线路 / 报文 / 参数 / 图片 / 历史消息）
彻底分开——提示词改版只落在这一层，报文与历史不受影响。

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

### 分源接口

| 接口 | 方法 | 说明 |
|---|---|---|
| `SystemPromptSource` | `String system(PromptRequest)` | 拼合完成的 system；调用方不得再增删改写 |
| `UserPromptSource` | `String user(PromptRequest)` | 拼合完成的本轮 user 消息（历史消息不在此列） |
| `StageDirectiveSource` | `stagePrepare` / `stageMemory` / `stageStory` / `stageState` | 该帧 `role: user` 消息的正文；准备 / 记忆仅 Lv.1，正文帧 Lv.2 不追加，维护帧两档共用 |
| `AgentToolSource` | `List<NarrAgentTool> tools(AgentToolsRequest)` | 本轮工具清单；**顺序即请求体 `tools` 数组顺序**（前缀一致性要求稳定） |

聚合门面：`abstract interface class PromptInterface implements
SystemPromptSource, UserPromptSource, StageDirectiveSource, AgentToolSource {}`。

### 请求对象（只搬运已取好的数据，不负责取数）

- `PromptRequest`：`book` / `mode`（`PromptMode`：Chat、Lv.1、Lv.2）/ `lastRound` /
  `userInput` / `worldBookEntries`（已按关键词筛好）/ `mods`；
- `AgentStageRequest`：`level` / `workingCopy`（记忆与维护帧判定条目与合并）/ `memoryMergePlan` /
  `first`（主帧 / 修复帧）/ `problems`（维护帧待修清单）；
- `AgentToolsRequest`：`level` / `workingCopy`（状态工具绑定对象，null = 不构造）/
  `useSearch` / `search` / `webSearch` / `fetchPage`（替身优先）/ `handlers`（过程回调）。

### 唯一绑定

```dart
/// 改实现只改这一行。
const PromptInterface promptInterface = PromptV2();
```

契约分两半，便于纯 Dart 环境只取文本层：

| 文件 | 内容 | Flutter 依赖 |
|---|---|---|
| `prompt_text.dart` | `PromptMode` / `PromptRequest` / `AgentStageRequest` + system / user / 阶段帧三个源接口 | 无 |
| `prompt_interface.dart` | `AgentToolsRequest` / `AgentToolSource` + `PromptInterface` 聚合 + `PromptV2` 聚合实现 + 绑定 | 有（工具类型带抓取服务） |

## 三、实现分工

| 文件 | 职责 |
|---|---|
| `prompt_v2_sections.dart` | **全部文案**：固定行（人设 / 沙箱位置 / 服从 / 完整性 / 收尾）、共用契约、记忆条目格式与合并策略、三模式 system 与 user 契约、阶段帧指令、状态工具契约 |
| `prompt_v2_build.dart` | **拼接顺序与空块删除**：按总模板拼 system、按新建轮模板拼 user、按阶段给帧指令；实现 `prompt_text.dart` 的三个文本源（纯 Dart 依赖） |
| `prompt_v2_tools.dart` | **工具清单**：`listPromptTools(...)`，档位栏目 + 联网开关 → 工具列表 |

设计口径（与 `docs/ai_prompt_v2.md` 一致）：

- 外层用 `#` 一级标题分区、区域之间 `---` 分隔；块内分条只用 `- `（不用数字序号）；
- **无内容即删块**：可选项为空就连标题一起删（书籍设定 / 世界书 / 角色状态栏协议 /
  文笔参考范文 / 文笔要求行 / Mod / 上下文字段），不写「（无）」「未设置」；
- **多行内容保留换行**（Mod / 书籍设定 / 世界书 / 文笔参考 / 类别格式 / 前后置词），
  只有单行字段（书籍名 / 分类 / 上轮时间 / 角色层级）才折叠换行；
- 撤销中英双语：简明中文、口语化；英文只保留工具名、状态块标签与
  `[State-maintenance turn]` 回合标记；
- 不举例：只用 `{}` 占位符表达形状；
- **文风口径**：文风依据排序 = 用户本轮指令 > 文笔参考范文 > 文笔要求 / Mod 文笔要求
  > 其他；历史 assistant 文本只作剧情、格式与状态档案，不作效仿对象。落地三处：
  文笔要求行的「冲突以此为准」标记、`# 文笔参考范文：` 块内的说明（**无范文随块删除**，
  此时文风口径只剩 user 那句）、user 的「文风口径优先顺序」一句与收尾板块顶部的
  收口句；system 侧不设独立的「文本口径」固定条目；
- 不约束思考链格式（不要求思考语言、不要求把思考写出来），但保留功能性要求
  （调研回合读史一次、**大纲与记忆条目在同一回合落定**、记忆先于正文、按序三段）。

### 槽位与来源

| 总模板槽位 | 内容来源 |
|---|---|
| 人设 / 沙箱位置 / 服从 / 收尾 | `PromptV2Sections` 固定行 |
| 书籍名 / 分类 / 文笔要求 | `PromptRequest.book`（空则整行不注入；文笔要求行带「冲突以此为准」标记） |
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

## 四、工具清单

`prompt_v2_tools.dart` 的 `listPromptTools` 是唯一实现：

- 状态工具：按档位栏目现构（`buildStateTools(workingCopy, sections)`），绑定本轮工作副本；
- 联网工具：`useSearch` 时叠加（搜索 → 打开页，`buildDefaultAgentTools`），替身优先；
- **顺序固定**（状态工具在前、联网在后），任何变化都会改动请求前缀、使服务商上下文缓存失效；
- 工具定义（名字 / schema / description / 参数说明）为 v2 口径：简明中文，英文只保留
  工具名 / 状态块标签 / `op` 取值（见 `docs/agent_tools.md`）。

错误语义（显式报错，不静默回落）：`stageMemory` 缺 `workingCopy` → `ArgumentError`；
`tools` 启用联网却既无抓取服务、也无两个替身 → `ArgumentError`。

## 五、调用链接入现状

| 位置 | 现在 |
|---|---|
| `RoundProvider._assembleRoundRequest` | `promptInterface.system(request)` / `promptInterface.user(request)` |
| `RoundProvider._agentTools(...)` | `promptInterface.tools(request)`（预览、Chat 联网循环、Agent 单轮三处共用） |
| `RoundProvider` 历史消息 | `buildHistoryMessages(...)`（`wire_messages.dart`，与报文同侧、不经提示词模块） |
| `AgentRoundRunner._runPrepareStage` / `_runMemoryStage` / `_runStoryStage` / `_runStateStage` | `_prompt.stagePrepare / stageMemory / stageStory / stageState` |

报文层（`_agentBody` / `_agentChatBody` / `_makeBodyBuilder` / `wire_adapters`）只接收
接口产出的**纯文本与工具清单**，不认识提示词模块——即「报文拼装与提示词解耦」。

纯 Dart 预览：`dart run tool/preview_prompt.dart` 只引用 `prompt_text.dart` +
`prompt_v2_build.dart`（不含工具 / 抓取服务），因此在 Flutter 之外也能打印真实
system / user 文本；工具清单与阶段帧请在应用内用「预览请求体」核对。

## 六、改版约定

1. 文案改动：先改 `docs/ai_prompt_v2.md`（评审真源），再同步 `prompt_v2_sections.dart`；
2. 结构改动：改 `prompt_v2_build.dart` 的拼接与空块规则；
3. 契约扩展（新增槽位 / 新增源）：改 `prompt_text.dart` / `prompt_interface.dart`，
   调用方与报文 / 历史层**不动**。

契约约定：调用方**只调用** `PromptInterface` 上的方法，不得绕过接口直接读取实现细节；
接口返回的是最终文本，调用方不再拼接或改写。

## 七、测试

| 测试文件 | 锁住什么 |
|---|---|
| `test/prompt_interface_test.dart` | 绑定实现；总模板区域 / `---` 分隔 / 空块即删 / 多行保留 / 模式契约差异 / **文风口径（system 固定行、范文说明在范文之前、收口句在最前、user 侧口径位置）** / Mod 抬升与顺序 / 记忆合并档位与注入 / 工具路由与替身 / 阶段帧文案 / 请求对象 |
| `test/prompt_placeholders_test.dart` | 内置文案的占位符约定（`{中文名}`、不写死取值）+ 记忆模板与格式优先级统一 |
| `test/agent_tool_descriptions_test.dart` | 8 个工具的中文文案形态、联网指导落点、状态工具互指 |
| `test/wire_messages_test.dart` | 报文侧历史 messages 拼装（三种 assistant 形态、占位、vision 图片） |

## 八、文件一览

| 文件 | 角色 |
|---|---|
| `lib/services/prompt_text.dart` | **文本契约**（`PromptMode` + 请求对象 + 文本三源，纯 Dart，脚本 / CLI 可直接引用） |
| `lib/services/prompt_interface.dart` | 工具契约 + `PromptInterface` 聚合 + `PromptV2` 聚合实现 + 唯一绑定 |
| `lib/services/prompt_v2_sections.dart` | 文案真源 |
| `lib/services/prompt_v2_build.dart` | 文本实现（总模板 / 新建轮模板 / 阶段帧；纯 Dart 依赖） |
| `lib/services/prompt_v2_tools.dart` | 工具清单 |
| `lib/services/wire_messages.dart` | 报文侧消息组装：历史 messages + 图片 content（历史跟随报文） |
| `lib/services/agent/agent_default_tools.dart` | 联网工具公共工厂 |
| `lib/services/agent/state/state_tools.dart` | 六个状态工具（v2 中文文案） |
| `docs/ai_prompt_v2.md` | 提示词设计（总模板 / 格式模板，文案的评审真源） |
