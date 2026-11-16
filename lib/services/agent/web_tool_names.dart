/// 联网工具名（**单一真源**：工具注册、提示词的工具指南、测试都引用这里）。
///
/// 单独放一个文件是因为提示词文案层（`prompt_v3_sections.dart`）要在**纯 Dart**
/// 环境下引用这两个名字，而工具实现本身依赖抓取服务（带 Flutter 依赖）。
library;

/// 联网搜索工具名。
const String kWebSearchToolName = 'narrchat_webSearch';

/// 打开网页工具名。
const String kWebFetchPageToolName = 'narrchat_webFetchPage';
