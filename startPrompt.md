# 任务目标
请使用 Flutter (最新稳定版) 框架，为名为 "NarrChat" 的应用程序生成完整的、可编译运行的工程源代码。该应用需支持 Android 和 Windows 桌面端，并遵循 MVVM 架构模式。

## 核心数据模型 (SQLite 表结构)
数据库使用 sqflite，表设计如下：

### 表名: books
- id (INTEGER PK)
- title (TEXT) : 书籍名称
- category (TEXT) : 书籍总类别（如玄幻后宫）
- base_setting (TEXT) : 书籍不会变更的基础设定
- writing_style (TEXT) : 文笔参考段落
- global_pre_prompt (TEXT) : 全局前置词
- global_post_prompt (TEXT) : 全局后置词
- history_rounds (INTEGER) : 历史上下文轮次数，默认 1
- role_hierarchy (TEXT) : 用户自定义的角色分类排序（如 "主角 > 女主角 > NPC"）

### 表名: rounds (关联 books.id)
- id (INTEGER PK)
- book_id (INTEGER FK)
- round_index (INTEGER) : 轮次序号
- user_input (TEXT) : 用户原始输入
- ai_narrative (TEXT) : AI 返回的剧情正文
- world_state (TEXT) : AI 返回的 `## 世界状态` 原始文本
- character_state (TEXT) : AI 返回的 `## 角色状态` 原始文本（Markdown 结构完全由用户自定义）
- memory_summary (TEXT) : AI 返回的 `## 记忆总结`
- current_time (TEXT) : AI 返回的 `## 当前时间`
- recommended_action (TEXT) : AI 返回的 `## 推荐行动`
- tokens_in (INTEGER) : 请求消耗 Token
- tokens_out (INTEGER) : 响应消耗 Token
- created_at (DATETIME)

## 绝对强制的 AI 回复解析规则（核心逻辑）
App 与 AI 大模型（如 DeepSeek/Claude/GPT）交互，AI 必须严格返回以下 Markdown 结构。App 端需通过正则或字符串截取，**按二级标题（##）** 提取对应区块内容：
1. `## 剧情演绎` -> 存入 `ai_narrative`
2. `## 世界状态` -> 存入 `world_state`
3. `## 角色状态` -> 存入 `character_state` (此为纯文本块，App 绝不解析内部结构)
4. `## 记忆总结` -> 存入 `memory_summary`
5. `## 当前时间` -> 存入 `current_time`
6. `## 推荐行动` -> 存入 `recommended_action`

## 向 AI 发送请求的拼接逻辑 (User Prompt 组装)
当用户发送第 n+1 轮输入时，App 必须按以下结构组装请求体发送给大模型：

**【System Prompt 内容】** (作为 API 的 system 字段)：
```
你是叙事引擎 NarrChat。严格遵循书籍设定与状态，输出必须仅包含上述 6 个二级标题区块。
书籍设定：{books.base_setting}
文笔参考：{books.writing_style}
角色层级排序规则：{books.role_hierarchy}
精确匹配触发的世界书条目：...（由 App 根据关键词扫描本轮和历史上下文动态注入）
第 n 轮状态快照（必须被完整复制到输出的 `## 角色状态` 和 `## 世界状态` 中，仅修改变动项）：
[character_state 文本]
[world_state 文本]
第 n 轮记忆总结：{memory_summary}
```

**【User Prompt 内容】** (作为 API 的 user 字段)：
```
【历史原文上下文（最近 N 轮，N = books.history_rounds）】
(循环取出最近 N 轮的 user_input + ai_narrative)

【本轮创作指令】
{全局前置词}
{本轮临时前置词}
{用户实际输入}
{本轮临时后置词}
{全局后置词}

请严格执行 System 指令，输出 6 个二级标题区块。
```

## UI/UX 实现细节（必须达到的交互标准）

### 1. 主界面布局
- **桌面端 (Windows)**：采用左右两栏布局。左侧为主对话区（聊天气泡流），右侧为侧边栏（状态查看/编辑）。
- **移动端 (Android)**：主对话区占据全屏，侧边栏为从右向左滑出的抽屉（Drawer），并提供悬浮按钮或顶部图标呼出。

### 2. 对话区（左侧/主屏）
- 每一轮次以气泡形式展示。左侧显示 "用户" 头像+内容，右侧显示 "AI" 头像+内容。
- **AI 气泡底部必须包含以下控件**：
  - `输入 Tokens: xxx` | `输出 Tokens: xxx` (只读文本)
  - **查看本轮侧边栏** 按钮（点击后右侧栏滚动定位到该轮次数据）
  - **删除本轮** 按钮（弹出 BottomSheet 或 Dialog，提供两个选项："仅删除本轮" 与 "删除本轮及后续所有轮次"）
  - **刷新本轮** 按钮（点击弹出二次确认："将丢失后续所有轮次，是否继续？" 确认后自动执行删除后续，并立即以当前轮次的用户输入重新请求 AI）

### 3. 侧边栏（右侧/抽屉）
- **顶部 Top Bar**：固定显示当前查看的是 "当前轮次 (第 N 轮)" 还是 "历史轮次 (第 X 轮)"。若为历史轮次，整个侧边栏背景色应变为浅灰或添加红色警告边框以作醒目区分。
- **内容区**：将数据库存储的 `world_state`、`character_state`、`memory_summary`、`current_time`、`recommended_action` 以可编辑的文本形式显示。
- **关键交互**：侧边栏底部固定一个 **"保存快照"** 按钮。点击后，将侧边栏内所有文本内容原样写回数据库对应字段。历史轮次的修改**绝不**影响后续轮次，仅作为快照存档。
- **折叠功能（重点）**：针对 `character_state` 文本，由于用户可能使用 `#`、`##`、`###` 定义多层角色（如 # 角色状态 -> ## 女主角 -> ### 苏清月）。请实现一个 **Markdown 层级折叠组件**：自动解析 `character_state` 中的标题级别，默认只显示一级标题（如"女主角"），点击标题前的箭头可展开显示该标题下的详细内容（如"苏清月"及其属性）。该组件需保持纯文本编辑能力（即双击可进入原始文本编辑模式）。

### 4. 书籍设置对话框
- 包含：书籍标题、类别、基础设定（多行文本框）、文笔参考（多行文本框）、全局前置词/后置词（多行文本框）。
- **历史轮次数**：使用数字步进器（Stepper），默认 1。
- **角色排序规则**：提供一个可拖拽排序的列表（默认项：主角、女主角、NPC），允许用户增删分类名称。这些名称将拼接为 `角色层级排序规则` 字符串存入数据库。

## 技术栈与状态管理
- 使用 **Provider** 或 **Riverpod** 进行状态管理（推荐 Provider 以降低复杂度）。
- 使用 **sqflite** + **path_provider** 处理本地 SQLite 存储。
- 使用 **http** 或 **dio** 请求大模型 API（API Key 和 Base URL 暂时写死在配置文件或 `.env` 中，后续可扩展）。
- 使用 **flutter_markdown** 或 **markdown_widget** 渲染状态栏（可选），但主要展示以文本编辑器为主。

## 代码结构与质量要求
- 目录结构清晰：`lib/models/` (数据模型)、`lib/database/` (数据库操作)、`lib/providers/` (状态管理)、`lib/screens/` (页面)、`lib/widgets/` (可复用组件)、`lib/services/` (AI API 调用与解析服务)。
- 所有数据库增删改查操作必须包含完整的异常处理（try-catch）。
- AI 返回内容的解析器（Parser）必须具有容错性，即使 AI 漏掉某个标题，App 也不能崩溃，对应字段存为空字符串即可。

请开始生成完整的 Flutter 项目工程代码，包括 `pubspec.yaml`、所有 Dart 文件以及必要的资源配置。


# 开始前

对于变量、文件名、函数名，使用小驼峰命名。对于类名，使用大驼峰命名。

如果你有任何不理解的地方，请先问我再执行，如果你需要配置项目依赖，此项目根目录你可以随意配置，若涉及到全局环境或文件夹以外的操作，请先问我后再开始生成。项目依赖请尽可能使用隔离的和可部署的方式