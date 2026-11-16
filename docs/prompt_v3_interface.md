# Prompt 取用接口（v3）

> **配对文档**：system 侧设计见 `docs/prompt_v3_system.md`，上下文设计见
> `docs/prompt_v3_context.md`。
> **适用版本**：v3.1.0（v2 接口文档已归档到 `docs/old/prompt_interface_v2.md`）。

本文说明「发送给 AI 的文本与工具」的**唯一取用入口**——分源接口套件
`lib/services/prompt_interface.dart`；实现是 `prompt_v3_sections.dart`（system 文案）+
`prompt_v3_build.dart`（system 拼合）+ `prompt_v3_context.dart`（上下文文案与拼装）+
`prompt_v3_tools.dart`（工具清单），按 system 文档的 8 模块与上下文文档的成分顺序拼合。

> 接口套件本身不换：`prompt_text.dart` / `prompt_interface.dart` 只多一个「按模块取」的读法
> （见 §二），调用方与报文 / 历史层一概不动。

目的：把「本轮要发给 AI 什么内容」与「怎么发」（线路 / 报文 / 参数 / 图片 / 历史消息）
彻底分开——提示词改版只落在这一层，报文与历史不受影响。

## 一、覆盖范围

| | 内容 | 由谁负责 |
|---|---|---|
| ✅ | **拼合后**的 system（instructions）文本 | 接口 `system()` |
| ✅ | **按模块切分**的 system（调试 / 预览 / 测试用） | 接口 `systemSections()` |
| ✅ | **拼合后**的本轮 user 消息文本（设计见 `docs/prompt_v3_context.md`） | 接口 `user()` |
| ✅ | Agent **回合指令**（调研 / 正文 / 维护 / 修复；设计同上） | 接口 `stage*()` |
| ✅ | **工具集**（状态工具 + 联网工具；工具定义即文本） | 接口 `tools()` |
| ❌ | **历史 messages + 请求体** | `wire_messages.dart` + `RoundProvider` + `wire_adapters` + `ai_request_body_builder`：这一侧只消费接口产出的纯文本 / 工具清单，不引用任何提示词模块 |
| ❌ | vision 图片 content 多部分拼装 | `RoundProvider` |
| ❌ | 世界书关键词扫描、Mod 解析与筛选 | `WorldBookScanner` / `ModProvider` |
| ❌ | 工具的执行、失败语义与 UI 回调实现 | 各 `NarrAgentTool` / `RoundProvider` |

## 二、接口套件

### 分源接口

| 接口 | 方法 | 说明 |
|---|---|---|
| `SystemPromptSource` | `String system(PromptRequest)` | 拼合完成的 system；调用方不得再增删改写 |
| `SystemSectionSource` | `List<PromptSection> systemSections(PromptRequest)` | 按模块给出 system，空模块不出现，顺序即拼合顺序 |
| `UserPromptSource` | `String user(PromptRequest)` | 拼合完成的本轮 user 消息（历史消息不在此列） |
| `StageDirectiveSource` | `stagePrepare` / `stageStory` / `stageState` | 该回合 `role: user` 消息的正文（Agent Lv.1 的三个回合；修复回合由 `stageState` 按 `first=false` 出文案） |
| `AgentToolSource` | `List<NarrAgentTool> tools(AgentToolsRequest)` | 本轮工具清单；**顺序即请求体 `tools` 数组顺序**（前缀一致性要求稳定） |

聚合门面：`abstract interface class PromptInterface implements SystemPromptSource,
SystemSectionSource, UserPromptSource, StageDirectiveSource, AgentToolSource {}`。

`system()` 就是把 `systemSections()` 里各模块的 `text` 用**一个空行**串起来（空模块本来就不
出现），所以两者永远不会打架：调用方要报文就用 `system()`，要断言 / 预览某一块就用
`systemSections()`。

### `PromptSection`

```dart
/// system 里的一个模块：稳定的名字 + 拼好的一段正文。
class PromptSection {
  const PromptSection({required this.name, required this.text});

  /// 稳定标识，测试与预览按它取（见下面的名字表）。
  final String name;

  /// 该模块的最终正文（不含模块之间那一个空行）。
  final String text;
}
```

名字表（改名等于改测试锚点，别随手改）：

| `name` | 对应模块 | 空 |
|---|---|---|
| `must` | `{system_must}` | 否 |
| `accord` | `{system_accord}` | 否 |
| `extra` | `{system_extra}` | 是 |
| `about` | `{system_about}` | 是 |
| `setting` | `{system_setting}` | 是 |
| `writingStyle` | `{system_writing_style}` | 是 |
| `accordEnding` | `{system_accord_ending}` | 否 |
| `mustReverse` | `{system_must-}` | 否 |

### 请求对象（只搬运已取好的数据，不负责取数）

- `PromptRequest`：`book` / `mode`（`PromptMode`：Chat、Agent Lv.1）/ `lastRound` /
  `userInput` / `worldBookEntries`（已按关键词筛好）/ `mods` /
  `rewrite`（`RewriteTarget`，非 null = **修改轮**）/ `toolNames`；
- `toolNames`：本轮**实际注册**的工具名（`['narrchat_readHistory', …]`），只用来生成
  `accordEnding` 的简要工具指南；空列表 = 本轮没有工具 = 指南整块删。名字不认识就忽略，
  不做映射、不报错（工具清单的真源永远是 `tools()`）；
- `AgentStageRequest` / `AgentToolsRequest`：与 v2 相同，无变化。

### 唯一绑定

```dart
/// 改实现只改这一行。
const PromptInterface promptInterface = PromptV3();
```

契约分两半，便于纯 Dart 环境只取文本层：

| 文件 | 内容 | Flutter 依赖 |
|---|---|---|
| `prompt_text.dart` | `PromptMode` / `PromptRequest` / `AgentStageRequest` / `PromptSection` + 四个文本源接口 | 无 |
| `prompt_interface.dart` | `AgentToolsRequest` / `AgentToolSource` + `PromptInterface` 聚合 + `PromptV3` 聚合实现 + 绑定 | 有（工具类型带抓取服务） |

## 三、实现分工

| 文件 | 职责 |
|---|---|
| `prompt_v3_sections.dart` | **system 文案**：固定行、8 个模块与各块的文本、must 的段、模式契约、记忆格式与合并、工具指南条目 |
| `prompt_v3_build.dart` | **system 拼合**：按序取模块 → 空模块丢弃 → must 的块序列反转出 `mustReverse` → 空行 join；实现 `system()` / `systemSections()`（纯 Dart 依赖） |
| `prompt_v3_context.dart` | **上下文**：本轮 user 消息与 Agent 回合指令的文案 + 拼装，实现 `user()` / `stage*()`（纯 Dart 依赖） |
| `prompt_v3_tools.dart` | **工具清单**：`listPromptTools(...)`，档位栏目 + 联网开关 → 工具列表（沿用 v2 路由）；并重新导出 `promptToolNames` |
| `prompt_tool_names.dart` | **名字投影**：`promptToolNames(...)`，纯 Dart；`toolNames` 与工具实例同源的一致性由测试兜底 |
| `prompt_text_format.dart` | 三个拼装纯函数（多行保留 / 单行折叠 / 段间空行），sections 与 context 共用 |

两条实现规矩（与 `docs/prompt_v3_system.md` 一致）：

- **模块只在一个地方排序**：模块顺序写死在 `prompt_v3_build` 的一个常量列表里，文案层只管
  各模块正文，不许自己排；
- **空模块在 `systemSections()` 就丢掉**：`system()` 不再做第二轮过滤，避免两处判断不一致。

设计口径（与 `docs/prompt_v3_system.md` 一致）：

- 模块 / 子模块一律 `#` 一级标题；**must 与 must- 例外**——它们是不带标题的段落序列
  （段1 + Mod 段），块内分条只用 `- `（不用数字序号）；
- **Mod 内容不单独起标题、不标 Mod 字样**：紧贴宿主块往下接。例外是 `extra`——它没有宿主块，
  标题由程序给（`# 杂项要求：`）；
- **无内容即删块**：可选项为空就连标题一起删，不写「（无）」「未设置」；
- **多行内容保留换行**（Mod / 书籍设定 / 世界书 / 文笔参考 / 类别格式 / 前后置词），
  只有单行字段（书籍名 / 分类 / 上轮时间 / 角色层级）才折叠换行；
- **准确的书面语**：术语统一、句式完整、仅在必要区域使用语气词与撒娇口吻；英文只留工具名、状态块标签与
  `[State-maintenance turn]`；
- 不举例：只用 `{}` 占位符表达形状；
- 不约束思考链格式，但保留功能性要求（调研回合读一次记忆、调研结束**立刻**写正文、记忆只在
  维护回合做、按步执行）。

## 四、模块与来源

8 个模块的顺序、每个块装什么、空块怎么删——以 `docs/prompt_v3_system.md` 的「模块顺序」与
「模块 × 来源」两张表为准，本文不抄第二份（抄了必然不同步）。

接口侧只记三条：

1. **模块顺序**：`must → accord → extra → about → setting → writingStyle → accordEnding →
   mustReverse`；
2. **`mustReverse` 不是文案**：由 `prompt_v3_build` 把 `must` 的块序列（段1 + 各 Mod 段）
   整体反转，块内文案原样、不加标题；文案层没有它的手写稿；
3. **`toolNames` 只喂 `accordEnding`**：其余模块不看它；Chat / Agent 的差异仍由 `mode` 决定，
   两者的工具组合本来就不同，别把两件事搅在一起。

## 五、Mod 注入位

`ModsBundle` 按注入位提供 7 段（段内顺序由调用方按用户设定排好）：

| 字段 | 落到哪儿 | 来源列 |
|---|---|---|
| `prePrompts` | user 消息前置词区 | `pre_prompt` |
| `postPrompts` | user 消息后置词区 | `post_prompt` |
| `mustPrompts` | `must` 的段 2~n（不标标题、不标 Mod 字样） | `system_must` |
| `systemPrompts` | `extra` 的 `# 杂项要求：` 下 | `system_prompt` |
| `settingPrompts` | `setting` 的 `# 书籍设定和要求：` 内，紧随书籍设定 | `system_setting` |
| `worldBooks` | `setting` 的 `# 世界书：` 内，紧随书籍世界书 | `world_book` |
| `writingStylePrompts` | `writingStyle` 的 `# 文笔要求与参考段落：`（不标 Mod 字样） | `system_writing_style` |

四条约定：

- **`ModsBundle` 多出三段**：`mustPrompts` / `settingPrompts` / `writingStylePrompts` 分别承载
  Mod 的强指令、设定、文笔；`systemPrompts` 的语义收窄为「杂项要求」，字段名不变；
- **注入文本不标身份**：不出现 Mod 字样、不起标题——立一块标题，模型就容易把 Mod 当成
  "另一套规则"分而治之。`extra` 的标题是程序给的、中性名，不属于 Mod 文案；
- **空段不接**：`writingStylePrompts` 为空时连标题一起删、`systemPrompts` 为空时整个 `extra`
  模块消失；其余段为空就是少一段内容；
- **`mustPrompts` 参与逆序**：`mustReverse` 是 `[段1, mustPrompts…]` 整体反转，所以 Mod 段在
  末尾以倒序复现（有意为之）。`mustPrompts` 是拼好的整段，反转要**按块**做，所以
  `ModsBundle` 另带一个 `mustSegments`（每个 Mod 一块、顺序与设定一致，由
  `ModsBundleBuilder` 与 `mustPrompts` 一次填出）；手工构造 bundle 时它为空，
  拼合层就把整段当一块，行为与旧写法一致。

## 六、工具清单

`prompt_v3_tools.dart` 的 `listPromptTools` 是唯一实现：

- 状态工具：按档位栏目现构（`buildStateTools(workingCopy, sections)`），绑定本轮工作副本；
  Lv.1 只注册历史一读一写，世界 / 角色两对是保留框架（`toolSections` 里不出现就不构造）；
- 联网工具：`useSearch` 时叠加（搜索 → 打开页，`buildDefaultAgentTools`），替身优先；
- **顺序固定**（状态工具在前、联网在后），任何变化都会改动请求前缀、使服务商上下文缓存失效；
- 工具定义（名字 / schema / description / 参数说明）沿用同一套口径，英文只保留工具名 /
  状态块标签 / `op` 取值（见 `docs/agent_tools.md`）。

错误语义（显式报错，不静默回落）：`tools` 启用联网却既无抓取服务、也无两个替身 → `ArgumentError`。

> 注意：`tools()` 给的是**工具定义**，`accordEnding` 里的**简要工具指南**是另一件事——后者
> 只写「什么时候用哪个」，两者别混。指南的条目在 `prompt_v3_sections.dart` 里按工具名索引。

## 七、调用链接入点

| 位置 | 接法 |
|---|---|
| `RoundProvider._assembleRoundRequest` | `promptInterface.system(request)` / `user(request)`；组装时把本轮工具名填进 `PromptRequest.toolNames` |
| `RoundProvider._agentTools(...)` | `promptInterface.tools(request)`（预览、Chat 联网循环、Agent 单轮三处共用） |
| `RoundProvider` 历史消息 | `buildHistoryMessages(...)`（`wire_messages.dart`，与报文同侧） |
| `AgentRoundRunner._appendStageDirective` | `_prompt.stagePrepare / stageStory / stageState`（实发各步与「预览请求体」的回合骨架共用同一追加点） |
| 「预览请求体」 | 按当前发送意图走同一份组装，取实发首回合；顺手多打印一份 `systemSections()` 就能按模块核对 |

修改轮（按意见重写某一轮）走**同一条**组装路径：提示词只多一个 `RewriteTarget`，历史 /
状态基座由组装层按当前投影现算（历史 = 被重写轮生成时收到的 n 轮 + 该轮自身；基座 = 该轮的
上一轮）。user 侧模板与 v2 一致，所以这条路径只有 system 是模块化的。

纯 Dart 预览：`dart run tool/preview_prompt.dart` 只引用 `prompt_text.dart` +
`prompt_v3_build.dart`（不含工具 / 抓取服务），因此在 Flutter 之外也能打印真实 system / user
文本；想把 8 个模块分开看，就打印 `systemSections()`。

## 八、改版与扩展约定

1. 文案改动：先改 `docs/prompt_v3_system.md`，再同步 `prompt_v3_sections.dart`；
2. 结构改动：改 `prompt_v3_build.dart` 的模块顺序与空块规则——模块顺序只在这里有一份；
3. 新增模块：`PromptSection` 名字表、`docs/prompt_v3_system.md` 的「模块 × 来源」表、测试锚点三处
   一起补；
4. 契约扩展（新增槽位 / 新增源）：改 `prompt_text.dart` / `prompt_interface.dart`，调用方与
   报文 / 历史层**不动**；
5. Mod 新增注入位：先给 `ModsBundle` 加段，再在 `prompt_v3_sections` / `prompt_v3_build` /
   `prompt_v3_context` 的对应块接上，文档的「Mod 注入位」表同步；
6. 上下文改动（user 消息成分 / 回合指令）：先改 `docs/prompt_v3_context.md`，再同步
   `prompt_v3_context.dart`。

契约约定：调用方**只调用** `PromptInterface` 上的方法，不得绕过接口直接读取实现细节；
接口返回的是最终文本，调用方不再拼接或改写。

## 九、测试

| 测试文件 | 锁住什么 |
|---|---|
| `test/prompt_interface_test.dart` | 绑定实现；模块顺序与空行；标题层级（must / must- 无标题、`extra` 有程序标题、结构标题不出现 `##`）；空块即删；多行保留；模式契约差异；**文风口径四处落点**；Mod 注入位（除 `extra` 外不标标题）与七个注入段的落点；工具路由与替身；`user()` / `stage*()` 与 system 的衔接；请求对象 |
| `test/prompt_v3_modules_test.dart` | 逐模块断言：`systemSections()` 的名字与顺序；`mustReverse` 是 must 全部块（段1 + Mod 段）的逆序；`toolNames` 驱动的简要工具指南（有 / 无工具、Chat / Agent 两种组合） |
| `test/prompt_v3_context_test.dart` | 上下文拼装：user 消息成分的顺序与 `---` 分隔、每类空成分的删除、两种模式的本轮输出契约、四份回合指令与维护回合的补充清单 |
| `test/prompt_placeholders_test.dart` | 内置文案的占位符约定（`{中文名}`、不写死取值）+ 记忆模板与格式优先级统一 |
| `test/agent_tool_descriptions_test.dart` | 各工具的中文文案形态、联网指导落点、状态工具互指 |
| `test/wire_messages_test.dart` | 报文侧历史 messages 拼装（三种 assistant 形态、占位、vision 图片） |

写测试的两条口径：断言优先落在 `systemSections()` 的**单模块**上（整段 system 的
`indexOf` 断言一旦换行就脆），跨模块的只断言「谁在谁前 / 谁不出现」。

## 十、文件一览

| 文件 | 角色 |
|---|---|
| `lib/services/prompt_text.dart` | **文本契约**（`PromptMode` + 请求对象 + `PromptSection` + 文本源，纯 Dart） |
| `lib/services/prompt_interface.dart` | 工具契约 + `PromptInterface` 聚合 + `PromptV3` 聚合实现 + 唯一绑定 |
| `lib/services/prompt_v3_sections.dart` | system 文案真源 |
| `lib/services/prompt_v3_build.dart` | system 实现（模块拼合 / 空块删除 / `mustReverse`；纯 Dart 依赖） |
| `lib/services/prompt_v3_context.dart` | 上下文实现（user 消息成分 / 回合指令；纯 Dart 依赖） |
| `lib/services/prompt_v3_tools.dart` | 工具清单（`listPromptTools`，带 Flutter 依赖） |
| `lib/services/prompt_tool_names.dart` | 工具**名字投影**（`promptToolNames`，纯 Dart；供组装 system 之前填 `toolNames`） |
| `lib/services/prompt_text_format.dart` | 拼装用的三个纯函数（多行保留 / 单行折叠 / 段间空行） |
| `lib/services/wire_messages.dart` | 报文侧消息组装：历史 messages + 图片 content（历史跟随报文） |
| `lib/services/agent/agent_default_tools.dart` | 联网工具公共工厂 |
| `lib/services/agent/state/state_tools.dart` | 六个状态工具（Lv.1 只注册历史一读一写，其余是保留框架） |
| `lib/services/agent/web_tool_names.dart` | 两个联网工具名（纯 Dart，文案层引用它） |
| `docs/prompt_v3_system.md` | system 设计（8 模块模板，system 文案的评审真源） |
| `docs/mods.md` | Mod 设计（七列 / 七个注入位 / 导出格式 / 3.0 兼容口径） |
| `docs/prompt_v3_context.md` | 上下文设计（user 消息成分 / 历史形态 / 回合指令） |
| `docs/prompt_v3_interface.md` | 本文档 |

## 十一、设计约束与影响

| 项 | 说明 |
|---|---|
| `toolNames` 的单一来源 | 与同一轮的 `tools()` 同源取一次；预览与实发的注册结果不一致时以实发为准 |
| 工具指南与缓存 | 工具开关一变，system 前缀就变，服务商缓存从改动处失效——接受这个代价，让模型临笔前看见工具清单更值 |
| `must` 的两段来源 | 段1 = 固定行；段2~n = `ModsBundle.mustPrompts`，为空就只剩段1 |
| `mustReverse` 的代价 | 整段 must 在 system 里出现两次（正序 + 倒序），换来的是开头结尾双向强调 |
| user 侧 | 不切分：模块化只做在 system；user 消息按上下文文档的成分顺序拼成一条 |
