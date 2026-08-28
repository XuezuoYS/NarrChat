# NarrChat

> 注意：此项目几乎为纯 AI Vibe Coding 产物，请谨慎使用。

**NarrChat** 是基于 AI 大模型 API 的对话式剧情创作工具（"AI 叙事交互引擎"）。
以"聊天"的方式驱动 AI 续写剧情，同时将 AI 输出结构化地沉淀为剧情正文、世界状态、角色状态与记忆总结，支持多本书并行创作、图片带入、Mod 提示词扩展与 WebDAV 云同步。

## 支持平台

| 平台 | 架构 | 产物 |
| --- | --- | --- |
| Windows | x64（amd64） | `setup.exe` 安装包 / ZIP 便携包 |
| Android | arm64 | APK |

> 此仓库仅维护以上两个平台。

## 功能特性

### 剧情创作

- **对话式交互**：在书籍对话页发送消息，AI 按固定格式输出
  「剧情演绎 → 推荐行动 → 当前时间 → 世界状态 → 角色状态 → 记忆总结」六个区块；
  剧情正文落库为正式章节，各状态块自动沉淀。
- **流式生成**：实时渲染回复；支持思考模式（思维链）展示、断流自动重连、
  多本书并发生成、生成中途停止 / 重试。
- **结构化上下文**：书籍设定、角色层级、世界书条目、记忆总结、上一轮状态快照、
  文笔要求与参考样式（内置"去 AI 味"与增强服从性提示词）。
- **Agent 支持**：模型可调用联网搜索、网页抓取工具，对话中可查看详细的调用记录。
- **Markdown**：聊天气泡、RAW 调试框等多处支持 Markdown 渲染与语法高亮，
  多行输入框支持 md 高亮解析（`lib/widgets/markdown_editing_controller.dart`）。
- **图片**：输入框粘贴 / 文件导入 / 桌面拖拽，全屏可缩放查看器（同轮多图左右滑动，
  Windows 端为独立系统窗口），图片库统一管理。
- **辅助面板**：记忆总结编辑、楼层跳转悬浮条（BETA）、RAW 调试（含换行符转译）、
  每轮使用模型展示、历史轮次回溯与重试。

### AI 接入

- **OpenAI 兼容 API**：默认内置 DeepSeek 开放平台（预置 V4 Pro / V4 Flash /
  V4 Flash Vision Exp 识图模型），支持自定义平台、Base URL 与模型（含推理强度、
  温度、流式等参数），也支持预设 Mod 一键切换参数组合。

### 云同步

- **WebDAV 云同步**：数据平面（书籍 / 轮次 / 世界书 / Mod，UUID 身份三向合并）
  与图片平面（内容寻址 blob + 墓碑 + 全局复活标记）两平面独立收敛。
- **自动同步**：开启后由真实操作节点驱动（启动、回前台、进入书籍、生成结束、
  设置保存、图片库删除等），空闲无轮询；冲突时进入合并决策页人工裁决。
- 详见 [云同步设计文档](docs/sync_auto_triggers.md)。

### 其它

- **后台通知**：生成完成时系统推送（Windows / Android）；Android 支持后台生成保活，
  点击通知直达对应书籍对话页。
- **界面**：亮 / 暗色（跟随系统）、全局字体（自动扫描并加载系统字体）、
  宽窄屏自适应布局、内置「关于 / 更新日志 / 开放源代码许可」页。
- **后台生成**：掉线 / 切后台时生成不丢（Android 端后台生成保活）。

## 运行

从 [Releases](https://github.com/XuezuoYS/NarrChat/releases) 下载对应版本：

- **Windows**：解压 ZIP 便携包直接运行，或使用 `setup.exe`
  （默认按用户目录安装、免管理员权限）。
- **Android**：安装 APK（arm64）；首次使用请开启系统通知权限，
  并在「设置 → API 设置」中配置 API Key。

## 数据与存储

数据按敏感度分层存储（详见 `AGENTS.md`）：

| 类别 | 内容 | 存储方式 |
| --- | --- | --- |
| 用户数据 | 书籍、轮次、世界书、Mod | SQLite 数据库（`books` / `rounds` / `world_book_entries` / `mods` / `book_mods` 等），可 WebDAV 云同步 |
| 本地数据 | AI / UI 等杂项设置 | 本地 JSON 配置（`local_config/app_settings.json` 等），无需同步 |
| 令牌 | API Key、WebDAV 密码 | 操作系统密钥库（`flutter_secure_storage`），禁止明文存储、禁止进入云同步 |

## 开发

### 环境

- Flutter 3.47.0+（Dart SDK `^3.12.2`），依赖见 [`pubspec.yaml`](pubspec.yaml)。
- 代码规范：`flutter_lints`；命名遵循小驼峰（函数 / 变量 / 文件）与大驼峰（类）。

### 常用命令

```bash
flutter pub get            # 安装依赖
flutter run -d windows     # Windows 运行
flutter run                # Android 运行（连接设备后选择）
flutter test               # 全部测试（无需真机；平台敏感用例自动跳过或降级）
flutter test test/<文件名>.dart   # 单文件测试
flutter analyze            # 静态分析
```

> 测试规范：公共替身统一使用 `test/helpers/fakes.dart`，页面脚手架使用
> `test/helpers/chat_harness.dart`；禁止依赖真实网络 / 密钥库 / 数据库。
> 详见 `AGENTS.md`「测试规范」。

### 可注入的 dart-define

```bash
flutter run --dart-define=NARRCHAT_API_KEY=sk-xxx \
            --dart-define=NARRCHAT_API_BASE_URL=https://api.deepseek.com \
            --dart-define=NARRCHAT_MODEL=deepseek-v4-flash
```

- `NARRCHAT_API_KEY` / `NARRCHAT_API_BASE_URL` / `NARRCHAT_MODEL`：覆盖默认 API 配置。
- `NARRCHAT_FLUTTER_VERSION`：构建脚本自动注入当前 Flutter 版本（「关于」面板展示，
  无需手动设置）。

### 目录结构

```
lib/
  config/       应用配置、默认 AI 平台与模型
  database/     SQLite DAO（books / rounds / world_book / mods）
  models/       数据模型（Book / Round / Mod / WorldBookEntry ...）
  providers/    状态管理（Provider）
  screens/      页面（首页 / 对话 / 设置 / 书架 ...）
  services/     服务（AI 请求 / 提示词组装 / WebDAV / 图片 / 通知 ...）
  utils/        工具（markdown 高亮 / 搜索 / 格式 ...）
  widgets/      通用组件
  theme/        主题与字体
tool/
  build_release.dart  发布构建脚本
  preview_prompt.dart 提示词预览
  inno/               Inno Setup 中文语言文件
test/
  helpers/      公共替身与页面脚手架（fakes.dart / chat_harness.dart）
  * _test.dart  模块化单元 / Widget 测试
docs/
  sync_auto_triggers.md  云同步设计文档（触发时机、合并与并发策略）
```

## 构建

使用一键构建脚本（自动完成版本号自增、构建与打包，产物输出到 `build/release/`）：

```bash
dart run tool/build_release.dart                 # 交互菜单
dart run tool/build_release.dart --all           # Android + Windows
dart run tool/build_release.dart --android       # 仅 Android arm64 APK
dart run tool/build_release.dart --windows       # Windows（setup.exe + ZIP 便携包）
dart run tool/build_release.dart --zip-only      # Windows 仅 ZIP 便携包
dart run tool/build_release.dart --no-bump       # 跳过 build 号自增
dart run tool/build_release.dart --version 1.2.0 # 构建前设置版本号（x.y.z）
```

- **版本号唯一来源**：[`release.yaml`](release.yaml)；构建时自动将 `build` +1
  并同步 `pubspec.yaml` 的 `version` 为 `{version}+{build}`（Android versionCode）。
- **产物命名**：`NarrChat_{version}-{build}_{device}_{arch}[.apk | .zip | -setup.exe]`。
- **Windows 安装包**：依赖 [Inno Setup](https://jrsoftware.org/isdl.php)（免费开源），
  未安装时自动降级为仅产出 ZIP 便携包；中文语言文件随仓库维护。
- 构建脚本会修复 Windows 增量构建常见的引擎包装源码缺失问题（自动清理缓存重解包）。

## License

本项目未附带开源许可证文件；第三方依赖的许可证列表可在应用内
「设置 → 开放源代码许可」页查看。
