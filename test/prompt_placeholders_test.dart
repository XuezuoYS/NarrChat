import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/services/agent/fetch_page_tool.dart';
import 'package:narrchat/services/agent/state/agent_state_working_copy.dart';
import 'package:narrchat/services/agent/state/state_coverage.dart';
import 'package:narrchat/services/agent/state/state_tools.dart';
import 'package:narrchat/services/agent/web_search_tool.dart';
import 'package:narrchat/services/memory_merge_planner.dart';
import 'package:narrchat/services/prompt_interface.dart';
import 'package:narrchat/services/prompt_v2_build.dart';
import 'package:narrchat/services/prompt_v2_sections.dart';
import 'package:narrchat/utils/memory_entry_format.dart';

/// 内置提示词（Mod 除外）的**占位符约定**守护（v2）。
///
/// 约定（真源：`docs/ai_prompt_v2.md` 顶部「不举例」+ `prompt_v2_sections.dart`）：
/// - 涉及具体取值的位置一律写成 `{中文名}`——`{轮次}` / `{时间}` / `{记忆内容}` /
///   `{开头轮}` / `{开头轮时间}` / `{类别名}` / `{角色名}` / `{属性名}` / `{属性值}`；
/// - **不得出现具体案例示例**（写死的角色名 / 类别名 / 日期取值），也不得回退到
///   旧写法（`<时间>` / `<一句话概括>` / `xxx` / `{name}`）。
///
/// 理由：示例只表达**形状**，写死的取值会被模型当成设定照抄，也与用户实际书籍
/// 设定冲突。覆盖范围 = v2 全部文本块与真实组装产物、8 个工具的 `description`、
/// 缺口指令（[StateGap.modelText]）；Mod 文案（预置 / 用户 Mod）不受本约定约束。
void main() {
  const book = Book(title: '占位符书', category: '玄幻');
  const lastRound = Round(
    id: 1,
    bookUuid: 'b1',
    roundIndex: 1,
    currentTime: '第一天',
  );

  AgentStateWorkingCopy workingCopy() => AgentStateWorkingCopy(
        roundIndex: 2,
        lastRound: const Round(id: 1, bookUuid: 'b1', roundIndex: 1),
        categoryNames: const ['类别甲'],
      );

  /// 全部内置（Mod 除外）模型面向文案。
  List<String> modelFacingTexts() {
    final mergePlan = planMemoryMerge(
      memoryText: [
        for (var i = 1; i <= 10; i++) '- $i | 第$i天 | 事件$i。',
      ].join('\n'),
      tier: 5,
      newRoundIndex: 11,
    );
    final texts = <String>[
      PromptV2Sections.persona,
      PromptV2Sections.sandboxPosition,
      PromptV2Sections.obedience,
      PromptV2Sections.characterStateCompleteness,
      PromptV2Sections.endNote,
      ...PromptV2Sections.sharedContractLines,
      ...PromptV2Sections.memoryFormatLines(),
      ...PromptV2Sections.toolContractLines(),
      ...PromptV2Sections.memoryMergePolicyLines(0),
      ...PromptV2Sections.memoryMergePolicyLines(5),
      ...PromptV2Sections.memoryMergeAgentLines(mergePlan),
      ...PromptV2Sections.memoryMergeChatNote(mergePlan),
      PromptV2Sections.stagePrepare,
      PromptV2Sections.stageMemoryBody(),
      PromptV2Sections.stageStory,
      PromptV2Sections.stateHeadLv1,
      PromptV2Sections.stateHeadLv2,
      PromptV2Sections.stateHeadFix,
    ];
    for (final mode in PromptMode.values) {
      final request = PromptRequest(
        book: book,
        mode: mode,
        lastRound: lastRound,
        userInput: '输入',
      );
      texts
        ..addAll(PromptV2Sections.modeContractLines(mode))
        ..add(PromptV2Sections.userContract(mode))
        ..add(const PromptV2Build().system(request))
        ..add(const PromptV2Build().user(request))
        // 修改轮（按意见重写某轮）：与新建轮同构的另一份 user 模板，同样受
        // 「不举例 / 只用中文占位符」约束。
        ..add(const PromptV2Build().user(PromptRequest(
          book: book,
          mode: mode,
          lastRound: lastRound,
          userInput: '输入',
          rewrite: RewriteTarget(
            roundIndex: 2,
            roundTime: lastRound.currentTime,
          ),
        )));
    }
    final copy = workingCopy();
    texts
      ..add(WebSearchTool().description)
      ..add(FetchPageTool().description)
      ..addAll(
        buildStateTools(copy, sections: AgentStateSection.values)
            .map((tool) => tool.description),
      );
    for (final kind in StateGapKind.values) {
      texts.add(
        StateGap(
          kind: kind,
          section: AgentStateSection.characterState,
          names: const ['角色甲'],
        ).modelText,
      );
    }
    return texts;
  }

  /// 具体案例示例与旧占位写法（出现在内置文案里即失败）。
  const banned = [
    '# 主角', // 具体类别名（示例应写 {类别名}）
    '林远', // 具体角色名（示例应写 {角色名}）
    '苏清月',
    '第三天', // 具体日期取值（示例应写 {当前时间}）
    '午时',
    'xxx', // 旧占位写法
    '<时间>',
    '<当前时间>',
    '<一句话概括>',
    '{name}', // 旧占位写法（占位名统一用中文）
  ];

  test('内置文案（含 v2 三种模式实发文本）不含具体案例示例与旧占位写法', () {
    for (final text in modelFacingTexts()) {
      for (final token in banned) {
        expect(text, isNot(contains(token)), reason: '出现「$token」：$text');
      }
    }
  });

  test('记忆条目模板与格式优先级在 v2 三种模式与历史工具中统一', () {
    // 单一真源：新格式（带 `- ` 列表符）+ 合并条目模板。
    const template = kMemoryEntryFormat;
    expect(template, startsWith('- '));
    expect(template, contains('{轮次}'));
    expect(template, contains('{时间}'));
    expect(template, contains('{记忆内容}'));

    // 共用部分：单轮 + 合并两种形态都在，并声明「冲突时以本格式为准」。
    final format = PromptV2Sections.memoryFormatLines().join('\n');
    expect(format, contains(template));
    expect(format, contains(kMemoryMergedEntryFormat));
    expect(format, contains('以本格式为准'));

    // 三种模式组装出的 system 都带同一模板与合并策略。
    for (final mode in PromptMode.values) {
      final system = const PromptV2Build().system(PromptRequest(
        book: book,
        mode: mode,
        lastRound: lastRound,
        userInput: '输入',
      ));
      expect(system, contains(template), reason: mode.name);
      expect(system, contains('记忆总结·轮次合并'), reason: mode.name);
    }

    // 历史读取器与编辑器描述引用同一模板（锚点来源与追加格式一致），
    // 并各自带上格式优先级行。
    final descriptions = {
      for (final tool in buildStateTools(
        workingCopy(),
        sections: AgentStateSection.values,
      ))
        tool.name: tool.description,
    };
    for (final name in const [kReadHistoryToolName, kEditHistoryToolName]) {
      expect(descriptions[name], contains(template), reason: name);
      expect(
        descriptions[name],
        contains(kMemoryEntryFormatPrecedence),
        reason: name,
      );
    }
  });

  test('角色状态形态：围栏内结构用中文占位符表达（不写死取值）', () {
    final shared = PromptV2Sections.sharedContractLines.join('\n');
    for (final placeholder in const [
      '`# 类别名`',
      '`## 角色名`',
      '`- 属性名：属性值`',
    ]) {
      expect(shared, contains(placeholder), reason: '共用部分缺：$placeholder');
    }
    expect(shared, contains('围栏'), reason: '必须点明 `## 角色状态` 的围栏要求');
  });
}
