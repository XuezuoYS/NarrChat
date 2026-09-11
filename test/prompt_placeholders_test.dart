import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/models/round.dart';
import 'package:narrchat/services/agent/fetch_page_tool.dart';
import 'package:narrchat/services/agent/state/agent_state_working_copy.dart';
import 'package:narrchat/services/agent/state/state_coverage.dart';
import 'package:narrchat/services/agent/state/state_tools.dart';
import 'package:narrchat/services/agent/web_search_tool.dart';
import 'package:narrchat/services/prompt_formats.dart';

/// 内置提示词（Mod 除外）的**占位符约定**守护。
///
/// 约定（真源：`prompt_formats.dart` 文件头「文案约定」）：
/// - 涉及具体取值的位置一律写成 `{中文名}`——`{当前时间}` / `{概括内容}` /
///   `{类别名}` / `{角色名}` / `{属性名}` / `{属性值}`；
/// - **不得出现具体案例示例**（写死的角色名 / 类别名 / 日期取值），也不得回退
///   到旧写法（`<时间>` / `<一句话概括>` / `xxx` / `{name}`）。
///
/// 理由：示例只表达**形状**，写死的取值会被模型当成设定照抄，也与用户实际
/// 书籍设定冲突。覆盖范围 = 三种模式的全部提示词槽位、8 个工具的 `description`、
/// 缺口指令（[StateGap.modelText]）；Mod 文案（预置 / 用户 Mod）不受本约定约束。
void main() {
  /// 全部内置（Mod 除外）模型面向文案。
  List<String> modelFacingTexts() {
    final texts = <String>[];
    for (final format in const <PromptFormatSpec>[
      ChatPromptFormat(),
      AgentLv1PromptFormat(),
      AgentLv2PromptFormat(),
    ]) {
      texts.addAll(format.systemHead);
      texts.addAll(format.systemAfterIdentity);
      texts.addAll(format.systemTail);
      texts.addAll(format.userHead);
      texts.addAll(format.userExecuteNote);
    }
    final workingCopy = AgentStateWorkingCopy(
      roundIndex: 2,
      lastRound: const Round(id: 1, bookUuid: 'b1', roundIndex: 1),
      categoryNames: const ['类别甲'],
    );
    texts
      ..add(WebSearchTool().description)
      ..add(FetchPageTool().description)
      ..addAll(
        buildStateTools(workingCopy, sections: AgentStateSection.values)
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

  test('内置文案不含具体案例示例与旧占位写法', () {
    for (final text in modelFacingTexts()) {
      for (final token in banned) {
        expect(text, isNot(contains(token)), reason: '出现「$token」：$text');
      }
    }
  });

  test('记忆条目模板在三种模式与历史工具中统一为占位符写法', () {
    const template = '- 第N轮｜日期：{当前时间}｜{概括内容}';
    // Chat：系统规则 + 用户消息提醒各一处。
    expect(const ChatPromptFormat().systemTail.join('\n'), contains(template));
    expect(const ChatPromptFormat().userHead.join('\n'), contains(template));
    // Agent Lv.1：历史工具契约的「每轮义务」；Lv.2：每轮义务（systemHead）。
    expect(const AgentLv1PromptFormat().systemTail.join('\n'),
        contains(template));
    expect(const AgentLv2PromptFormat().systemHead.join('\n'),
        contains(template));
    // 历史读取器与编辑器描述引用同一模板（锚点来源与追加格式一致）。
    final workingCopy = AgentStateWorkingCopy(
      roundIndex: 2,
      lastRound: const Round(id: 1, bookUuid: 'b1', roundIndex: 1),
      categoryNames: const ['类别甲'],
    );
    final descriptions = {
      for (final tool in buildStateTools(
        workingCopy,
        sections: AgentStateSection.values,
      ))
        tool.name: tool.description,
    };
    expect(descriptions[kReadHistoryToolName], contains(template));
    expect(descriptions[kEditHistoryToolName], contains(template));
  });

  test('角色状态形态示例：围栏内每一行都用中文占位符', () {
    final lines = const ChatPromptFormat().systemAfterIdentity;
    final start = lines.indexOf('```markdown');
    expect(start, greaterThan(0));
    final example = lines.sublist(start, lines.indexOf('```', start + 1) + 1);
    expect(example, [
      '```markdown',
      '# {类别名}',
      '## {角色名}',
      '- {属性名}：{属性值}',
      '```',
    ]);
    // 三行示例各自带中文占位符（不是写死的设定取值）。
    for (final line in example.sublist(1, example.length - 1)) {
      expect(RegExp(r'\{[\u4e00-\u9fff]+\}').hasMatch(line), isTrue,
          reason: '示例行缺占位符：$line');
    }
  });
}
