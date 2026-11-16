/// 本轮注册工具的**名字投影**（纯 Dart，不依赖 Flutter）。
///
/// 只做「档位栏目 + 联网开关 → 工具名」的纯计算：不构造工具实例、不碰抓取服务，
/// 因此可以在组装 system **之前**调用（`system()` 早于工具实例构造），
/// `RoundProvider` 就是靠它填 `PromptRequest.toolNames` 的。
///
/// 与 [listPromptTools]（`prompt_v3_tools.dart`，带 Flutter 依赖）共用同一份档位
/// 档案与同一批工具名常量；两边的一致性由 `test/prompt_interface_test.dart` 逐一
/// 比对锁住，任何一边改名都会红。
library;

import '../models/agent_mode_level.dart';
import 'agent/agent_mode_profile.dart';
import 'agent/state/state_tools.dart';
import 'agent/web_tool_names.dart';

/// 本轮注册工具的名字（顺序与 `listPromptTools` 完全一致：状态工具在前、
/// 联网工具在后）。
List<String> promptToolNames({
  required AgentModeLevel level,
  required bool useSearch,
}) {
  final sections = AgentModeProfile.of(level).toolSections;
  return [
    for (final section in sections) ...[
      agentReadToolName(section),
      agentEditToolName(section),
    ],
    if (useSearch) ...[kWebSearchToolName, kWebFetchPageToolName],
  ];
}
