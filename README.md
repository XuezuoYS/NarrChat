# NarrChat — AI 叙事交互引擎

一个基于 **Flutter** 的 AI 叙事创作应用，支持 **Android** 与 **Windows 桌面端**，遵循 **MVVM** 架构。

用户向大模型（DeepSeek / Claude / GPT 等，OpenAI 兼容接口）发送剧情指令，AI 严格返回 6 个
二级标题（`##`）区块，App 自动解析并分别存库；聊天流、状态侧边栏、折叠式角色状态编辑器、
书籍/轮次管理一应俱全。

## 功能特性

- **左侧书籍栏**（桌面端固定显示 / 移动端左抽屉）：书籍列表、新建/编辑/删除、快速切换。
- **AI 接口设置**（AppBar 钥匙图标）：
  - API Key 按业界标准存入系统安全存储（`flutter_secure_storage`，
    Android Keystore / Windows DPAPI），不落明文；
  - 参数遵循 DeepSeek 官方文档：模型（`deepseek-v4-pro` / `deepseek-v4-flash`，可自定义）、
    **思考模式**（`thinking.type` 开关 + `reasoning_effort` 低/高/最大）、**流式输出**（SSE）、
    **温度**（0~2，思考模式下官方不支持、自动不发送）、最大输出 Tokens。
- **第零轮**：书籍首次加载时自动创建 `round_index = 0`，
  用于在开始对话前编辑初始的「世界状态 / 角色状态」；
  其状态快照将作为第 1 轮的 System Prompt 输入。
- **世界书**（AppBar 地球图标）：按「关键词 + 注入内容」管理条目，支持新增、编辑、
  启用/停用、删除；发送剧情指令时自动扫描本轮输入与最近历史，命中关键词即注入 System Prompt。
- **对话区**：每轮以气泡展示（用户靠左、AI 靠右）；AI 气泡底部含 Token 用量、
  「查看本轮侧边栏」「删除本轮」「刷新本轮」操作；流式输出实时显示。
- **状态侧边栏**（桌面端右侧栏 / 移动端右抽屉）：
  - 区分「当前轮次」与「历史轮次」（历史轮次以浅灰背景 + 红色边框醒目区分）；
  - `world_state` / `character_state` / `memory_summary` / `current_time` /
    `recommended_action` 均可编辑，底部「保存快照」原样写回数据库；
  - `character_state` 使用 **Markdown 层级折叠组件**：自动解析 `#`/`##`/`###` 标题树，
    默认展示顶层分组，点击箭头展开子级；双击进入原始文本编辑模式。
- **书籍设置**：标题、类别、基础设定、文笔参考、全局前置/后置词、历史轮次数（步进器）、
  可拖拽排序 + 增删的角色分类列表（默认：主角 > 女主角 > 次要女主角 > 其它重要人物 > NPC）。
- **AI 交互**：System Prompt 注入书籍设定/文笔/角色层级/世界书条目/上一轮状态快照与记忆总结；
  User Prompt 注入最近 N 轮历史上下文 + 全局/临时前置后置词 + 用户输入。
- **容错解析**：AI 漏掉某个标题时对应字段存空字符串，App 绝不崩溃。

## 目录结构

```
lib/
├── config/     # 全局配置（API Key / Base URL / 模型名）
├── models/     # 数据模型（Book / Round）
├── database/   # SQLite 数据库（helper + DAO，全部带异常处理）
├── services/   # AI 调用、Prompt 组装、回复解析、世界书扫描
├── providers/  # 状态管理（Provider：Book / Round / Sidebar）
├── screens/    # 页面（首页、对话、书籍列表、书籍设置对话框）
├── widgets/    # 可复用组件（聊天气泡、侧边栏、折叠编辑器、拖拽角色列表等）
└── utils/      # 常量与工具
```

## 数据库

SQLite（`sqflite`），Windows 桌面端自动切换 `sqflite_common_ffi`。

- `books`：书籍信息（设定、文笔、前后置词、历史轮次数、角色层级排序等）。
- `rounds`：每轮用户输入、AI 剧情正文与 5 个状态区块、Token 用量、创建时间，关联 `books.id`。

数据库文件位于系统文档目录下的 `narrchat.db`。

## 运行

### 环境要求

- Flutter **3.44+**（稳定版），Dart 3.12+
- Android：Android SDK（API 21+）；Windows：Visual Studio 2022+（含 C++ 桌面开发组件）

### 配置 API

API Key 与接口参数在应用内通过 **AppBar 钥匙图标 →「AI 接口设置」** 配置：
- API Key 保存至系统安全存储（`flutter_secure_storage`），不落明文；
- 支持思考模式（含推理强度 low/high/max）、流式输出、模型选择
  （`deepseek-v4-pro` / `deepseek-v4-flash` / 自定义）、温度与最大输出 Tokens。

也可以使用 `--dart-define` 覆盖默认值：

```bash
flutter run --dart-define=NARRCHAT_API_KEY=sk-xxx \
            --dart-define=NARRCHAT_API_BASE_URL=https://api.deepseek.com \
            --dart-define=NARRCHAT_MODEL=deepseek-v4-flash
```

### Windows 桌面端

> **注意**：构建含插件的 Windows 应用需要系统启用 **开发者模式**（允许符号链接）。
> 未启用时会报 `Building with plugins requires symlink support`。
> 启用方法：设置 → 隐私和安全性 → 开发者选项 → 打开「开发人员模式」
> （或运行 `start ms-settings:developers` 后开启）。

```bash
flutter run -d windows
# 或构建发布版
flutter build windows --release
```

### Android

```bash
flutter run
# 或构建 APK
flutter build apk --debug
```

> 若在国内网络下 Gradle 依赖下载缓慢/超时，可将
> `android/gradle/wrapper/gradle-wrapper.properties` 的发行版地址换为
> 腾讯云镜像（`https://mirrors.cloud.tencent.com/gradle/gradle-9.1.0-all.zip`），
> 并在 `android/settings.gradle.kts`、`android/build.gradle.kts` 增加阿里云 Maven 镜像。

### 测试

```bash
flutter test
```

## AI 回复格式约定

AI 必须严格返回以下 6 个二级标题区块（App 按 `##` 标题匹配提取，容错处理）：

```
## 剧情演绎
（剧情正文）

## 世界状态
（世界状态原始文本）

## 角色状态
（角色状态原始文本，Markdown 结构完全由用户自定义，App 绝不解析内部结构）

## 记忆总结
（记忆总结）

## 当前时间
（当前时间）

## 推荐行动
（推荐行动）
```

## 扩展点

- **世界书（World Book）**：`lib/services/world_book_scanner.dart` 为占位实现；
  后续可在数据库新增世界书条目表，并在扫描器中实现关键词匹配与动态注入。
- **更多模型**：`AiService` 使用 OpenAI 兼容的 `/chat/completions` 接口，
  更换 Base URL 与模型名即可接入其他提供商。
