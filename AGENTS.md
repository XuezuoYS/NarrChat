## **[IMPORTANT]受限模式下运行 Flutter / Dart 命令的权限与审批**

- 顶层 `flutter` / `dart` 命令（`flutter analyze`、`flutter test`、`flutter pub get`、`flutter precache` 等）通常需要访问**工作区之外**的资源：pub 缓存、Flutter SDK / engine 工件、网络下载。在受限沙箱（如`workspace-write`）下这些访问会被挡住，命令会长时间空转或超时。
- 因此，需要运行这类命令时，**不要自行尝试** *Don't attempt on your own*，**直接向用户发起单次权限申请**（单次审批），说明越权访问的原因，记住，你应使用当前 Harness or Agents 工具的类**危险权限申请**渠道申请，而非提问等。
- 若用户未授予完整权限：向用户说明需要执行的命令并跳过执行，**不要**在受限沙箱下反复等待超时。

## 开始工作

### 项目简介

这是一个使用 flutter 编写的，面向 windows 和 android 的 AI 对话式文章生成工具。

### 操作前

你需要严谨按照要求和约束，若你对于任意问题不确定、未知或拿不准，认为我的要求模糊的，请先向我提问后得到准确回答后再进行。

### 编写要求

请尽可能保持代码的**模块化、高可维护性、少冗余代码、架构与代码层面低耦合**，若用户无要求，在不影响**模块化、高可维护性、少冗余代码、架构与代码层面低耦合**的前提下，执行*最小修改面*。

### 命名风格

此项目命名风格将使用：对于函数名、变量名、文件名，默认使用小驼峰 `camelCase` 命名，对于类名，默认使用大驼峰 `PascalCase` 命名。

### 数据结构

以文件形式显性区分用户数据和本地数据（不包括AI KEY），用户数据使用 sqlite 存储。
- 用户数据：用户创建的书籍以及书籍的一切数据、mod，可通过 webdev 云端存储同步。
- 本地数据：AI 设置、UI 设置等杂项设置，可便捷配置，自定义程度不高，无需云同步的数据。
- 令牌（包括 AI 和 webdav 等）：此需要按照安全规范存储到本地对应操作系统的秘钥管理中，禁止明文存储和进入云存储。

### 其余要求

- 所有多行输入框都需要支持 md 高亮解析，详见 `lib/widgets/markdown_editing_controller.dart`


## 测试规范

所有功能改动必须配套新增 / 更新测试（`flutter test` 全绿后方可提交）。

#### 运行方式

- 全部测试：`flutter test`（无需真机 / 模拟器；平台敏感用例自动跳过或降级）。
- 单文件：`flutter test test/<文件名>.dart`；单用例：加 `--plain-name '<用例名>'`。
- 禁止依赖真实网络 / 真实系统密钥库 / 真实数据库文件；对外部依赖一律注入替身（见下）。

#### 目录结构与公共设施

```
test/
  helpers/
    fakes.dart         # 数据/服务层公共替身（唯一来源，禁止在用例内再复制）
    chat_harness.dart  # pumpChatScreen / pumpHomeScreen / waitSendDone 公共脚手架
  <module>_test.dart   # 每个测试文件聚焦一个模块 / 一组行为
```

- **公共替身一律用 `test/helpers/fakes.dart`**：`FakeBookDao`、`FakeRoundDao`、
  `FakeWorldBookDao`、`FakeStreamingAiService`、`ToggleAiService`、
  `FakeNotificationBackend`。新增测试若需要同款替身，直接复用；确需扩展时
  优先在 helpers 中增强而非在用例内重新实现。
- **对话页 / 首页脚手架一律用 `test/helpers/chat_harness.dart`**：
  `pumpChatScreen(...)` / `pumpHomeScreen(...)` 已统一 Provider 组合、视口设置与
  轮次预置（`seedRounds` / `seedBodyRepeats`）；`waitSendDone(...)` 处理
  「isSending 期间无限转圈动画不能用 pumpAndSettle」的等待语义。
- 新增测试文件时若发现某个 mock / 脚手架需要在 2 个以上文件复用，
  必须先下沉到 `test/helpers/` 再使用（禁止复制粘贴）。

#### 替身使用要点（易错项）

- 内存 DAO 替身**必须覆写会被调用的全部方法**。此前 `ai_retry` /
  `stop_generation` 的 `_MockBookDao` 漏覆写 `getAllBooks()`，导致真实
  DatabaseHelper / path_provider 初始化链被 provider 的 catch 吞掉而“碰巧通过”。
  使用 `FakeBookDao` / `FakeRoundDao` / `FakeWorldBookDao` 即已全部覆写，
  不会触碰真实数据库。
- 首页测试的 `pumpHomeScreen` 已默认注入 `FakeNotificationBackend`，
  勿再构造真实 `GenerationNotificationService`（会走 flutter_local_notifications
  插件通道）。需要模拟“未开启系统通知”时，传入预构建且已 `refresh()` 的
  `NotificationSettingsProvider`。

#### 文件组织与命名

- 一个文件聚焦一个模块 / 一组行为，避免“大杂烩”测试文件
  （曾有 `widget_test.dart` 同时测 5 个无关模块并产生重复，已拆分为
  `prompt_builder_test.dart`、`world_book_scanner_test.dart`、`constants_test.dart`）。
- 文件名与被测模块对应（如 `ai_response_parser_test.dart` 测
  `AiResponseParser`）；被测对象跨模块时以主要模块命名并注释说明。
- 禁止创建零断言的“调试残留”测试（如 `debug_editor_test.dart`）或
  只测自制夹具、不触生产代码的测试（如 `sidebar_animation_test.dart`）。
- 重复用例（同一行为在集成层与隔离层各测一遍）默认只保留一层：
  优先保留隔离层（直接测组件），集成层只保留与其它组件交互的独特场景。

#### 断言质量

- 每个用例必须有明确断言；避免“只调不验”与“常量自比”
  （断言实现里写死的同一字面量仅作为外部标准锚定时有意义）。
- 优先精确断言（`expect(actual, expected)`、`closeTo`、`contains`），
  慎用仅验证“无异常 / 文本存在”的弱断言。
- 相同模板重复 2 次以上时收敛为参数化用例或共享 helper
  （如 `markdown_editing_controller_test.dart` 的 `renderSpans`），
  但避免在同一 testWidgets 内循环多次 pump（主题/时序切换易失效，宁可拆用例）。

#### 平台与 CI 注意事项

- 仓库当前无 CI；目标平台为 Windows + Android。
- 平台敏感测试需显式门控：非目标平台用 `markTestSkipped` 或
  `debugDefaultTargetPlatformOverride` 模拟，勿直接依赖真实系统字体 /
  真实目录（如 `system_fonts_service_test` 的 Windows 字体扫描）。
- 长尾异步用例建议显式设置 `timeout:`；依赖真实事件循环的轮询
  （`Future.delayed`）存在轻微 flake 风险，优先用可控 Completer / FakeAsync。
- 需补盲区时优先补：数据库迁移（`sqflite_common_ffi` + 临时目录）、
  纯逻辑服务（`local_config_service` / `formats` / `release_info`）、
  大面板基础交互（`book_settings_screen` 三面板）。
