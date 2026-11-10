/// 状态工具名（**单一真源**：提示词契约、工具注册、缺口指令都引用这里）。
///
/// 六个工具按栏目成对拆分：每个栏目一个**只读**读取器与一个**锚定式编辑**
/// 编辑器（实现见 `state_tools.dart`）。命名遵循「`narrchat_` 前缀 + 小驼峰」
/// 规范（见 `docs/agent_tools.md`）。
///
/// 当前唯一 Agent 档位（Lv.1）只注册历史一读一写；世界 / 角色两对是**保留
/// 框架**（完整 Agent Lv.2 已移除，暂无档位注册它们）。
library;

/// 世界状态读取（只返回 `<worldState>` 块）。
const String kReadWorldStateToolName = 'narrchat_readWorldState';

/// 角色状态读取（只返回 `<characterState>` 块）。
const String kReadCharacterStateToolName = 'narrchat_readCharacterState';

/// 历史（记忆总结）读取（只返回 `<memorySummary>` 块）。
const String kReadHistoryToolName = 'narrchat_readHistory';

/// 世界状态编辑（锚定式文本替换）。
const String kEditWorldStateToolName = 'narrchat_editWorldState';

/// 角色状态编辑（锚定式文本替换）。
const String kEditCharacterStateToolName = 'narrchat_editCharacterState';

/// 历史（记忆总结）编辑（锚定式文本替换；每轮恰一条本轮条目）。
const String kEditHistoryToolName = 'narrchat_editHistory';

/// 全部读取器（注册顺序即此顺序：先读后写）。
const List<String> kReadStateToolNames = [
  kReadWorldStateToolName,
  kReadCharacterStateToolName,
  kReadHistoryToolName,
];

/// 全部编辑器（注册顺序即此顺序）。
const List<String> kEditStateToolNames = [
  kEditWorldStateToolName,
  kEditCharacterStateToolName,
  kEditHistoryToolName,
];

/// 六个状态工具（读取器在前；当前档位只注册历史一读一写，其余为保留框架）。
const List<String> kStateToolNames = [
  ...kReadStateToolNames,
  ...kEditStateToolNames,
];
