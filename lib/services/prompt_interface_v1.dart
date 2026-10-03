/// [PromptInterface] 的 **v1 实现**：把每个方法逐字转发到现有实现器。
///
/// 本文件**不含任何提示词文案**——它只做映射，保证接口与线上行为逐字节一致：
///
/// | 接口方法 | 转发目标 |
/// |---|---|
/// | `system` | `PromptSections.buildSystemPrompt` |
/// | `user` | `PromptSections.buildUserPrompt` |
/// | `stagePrepare` / `stageMemory` / `stageStory` | `AgentLv1PromptFormat.prepareNote` / `AgentStageDirectives.memoryDirective` / `AgentLv1PromptFormat.storyNote` |
/// | `stageState` | `AgentStageDirectives.stateDirective` |
/// | `tools` | `buildStateTools`（档位栏目）+ `buildDefaultAgentTools`（联网） |
///
/// 将来接入 v2 时新增 `prompt_v2_build.dart` 的同名实现，并把
/// `prompt_interface.dart` 里的 `promptInterface` 绑定改过去即可，本文件保持不动
/// （可作为 v1 回退路径）。
library;

import 'agent/agent_stage_directives.dart';
import 'agent/narr_agent_tool.dart';
import 'prompt_formats.dart';
import 'prompt_interface.dart';
import 'prompt_sections.dart';
import 'prompt_v2_tools.dart';

/// v1（现行）提示词实现的转发层。无状态，可安全复用。
class PromptInterfaceV1 implements PromptInterface {
  const PromptInterfaceV1();

  /// 共享组装流程（与 `PromptBuilder` 同一实现）。
  static const PromptSections _sections = PromptSections();

  /// 阶段帧指令的单一真源（与 `AgentRoundRunner` 同一实现）。
  static const AgentStageDirectives _directives = AgentStageDirectives();

  @override
  String system(PromptRequest request) => _sections.buildSystemPrompt(
        book: request.book,
        worldBookEntries: request.worldBookEntries,
        mods: request.mods,
        format: request.format,
      );

  @override
  String user(PromptRequest request) => _sections.buildUserPrompt(
        book: request.book,
        lastRound: request.lastRound,
        userInput: request.userInput,
        mods: request.mods,
        format: request.format,
      );

  @override
  String stagePrepare(AgentStageRequest request) =>
      const AgentLv1PromptFormat().prepareNote().join('\n');

  @override
  String stageMemory(AgentStageRequest request) {
    final workingCopy = request.workingCopy;
    if (workingCopy == null) {
      throw ArgumentError.notNull(
        'AgentStageRequest.workingCopy（记忆帧需要工作副本判定本轮条目 / 合并）',
      );
    }
    return _directives.memoryDirective(
      first: request.first,
      workingCopy: workingCopy,
      memoryMergePlan: request.memoryMergePlan,
    )['content'] as String;
  }

  @override
  String stageStory(AgentStageRequest request) =>
      const AgentLv1PromptFormat().storyNote().join('\n');

  @override
  String stageState(AgentStageRequest request) {
    final workingCopy = request.workingCopy;
    // 尚未落地的记忆合并指令行并入清单（与执行器旧行为一致：先并入、再排序截断）。
    final problems = <String>[
      ...request.problems,
      if (workingCopy != null)
        ..._directives.pendingMemoryMergeLines(
          workingCopy: workingCopy,
          memoryMergePlan: request.memoryMergePlan,
        ),
    ];
    return _directives.stateDirective(
      problems: problems,
      first: request.first,
      level: request.level,
    )['content'] as String;
  }

  @override
  List<NarrAgentTool> tools(AgentToolsRequest request) => listPromptTools(
        level: request.level,
        workingCopy: request.workingCopy,
        useSearch: request.useSearch,
        search: request.search,
        webSearch: request.webSearch,
        fetchPage: request.fetchPage,
        handlers: request.handlers,
      );
}
