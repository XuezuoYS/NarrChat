import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/models/round.dart';
import 'package:narrchat/services/agent/fetch_page_tool.dart';
import 'package:narrchat/services/agent/narr_agent_tool.dart';
import 'package:narrchat/services/agent/state/agent_state_working_copy.dart';
import 'package:narrchat/services/agent/state/state_tools.dart';
import 'package:narrchat/services/agent/web_search_tool.dart';

/// Agent 工具 `description` 的 **v2** 文案契约（联网 2 个 + 状态 6 个共用同一形态）：
/// **简明中文**——撤销中英双语，英文只保留工具名（`narrchat_*`）、状态块标签
/// （`<worldState>` / `<characterState>` / `<memorySummary>`）与参数 / `op` 取值；
/// 不出现语言标记，也不出现成句英文。
///
/// 联网工具的调用指导（何时调用、搜索后必须打开页面）只在这里声明——
/// system 不再注入联网指令，故本文件的断言就是那条指令的落点。
void main() {
  AgentStateWorkingCopy workingCopy() => AgentStateWorkingCopy(
        roundIndex: 2,
        lastRound: const Round(
          id: 1,
          bookUuid: 'b1',
          roundIndex: 1,
          worldState: '- 地点：青云宗',
          characterState: '# 主角\n## 林远\n- 气血：80',
          memorySummary: '- 第1轮｜日期：第一天 午时｜初入宗门',
          currentTime: '第二天 午时',
        ),
        categoryNames: const ['主角', '女主角'],
      );

  /// 全部工具（联网在前、状态工具在后，与注入顺序一致）。
  /// 只读取文案，绝不调用 `run`（不会发起任何网络请求）。
  List<NarrAgentTool> allTools() => [
        WebSearchTool(),
        FetchPageTool(),
        ...buildStateTools(
          workingCopy(),
          sections: AgentStateSection.values,
        ),
      ];

  test('描述形态统一：简明中文，英文只保留工具名 / 块标签 / 取值', () {
    for (final tool in allTools()) {
      final description = tool.description;
      final reason = '${tool.name}：$description';
      // 旧的语言标记与成句英文都已移除。
      for (final marker in const ['【中】', '【EN】', '[中]', '[EN]']) {
        expect(description, isNot(contains(marker)), reason: reason);
      }
      expect(
        RegExp(r'[A-Za-z]+ [A-Za-z]+ [A-Za-z]+').hasMatch(description),
        isFalse,
        reason: '不应出现成句英文：$reason',
      );
      // 中文为主，并以中文句号收尾。
      expect(RegExp(r'[\u4e00-\u9fff]').hasMatch(description), isTrue,
          reason: reason);
      expect(description.trimRight(), endsWith('。'), reason: reason);
    }
  });

  test('联网工具描述承载调用指导：主动使用 → 搜索 → 必须打开页面读正文', () {
    final tools = {for (final t in allTools()) t.name: t};
    final search = tools['narrchat_webSearch']!.description;
    final fetch = tools['narrchat_webFetchPage']!.description;

    // 搜索：主动使用（不必等主人点名）+ 摘要不足以支撑创作 + 下一步工具。
    expect(search, contains('主动使用'));
    expect(search, contains('不必等主人点名'));
    expect(search, contains('只看摘要不足以支撑创作'));
    expect(search, contains('narrchat_webFetchPage'));
    expect(search, contains('阅读正文'));

    // 打开页面：搜索的配套下游 + 拒绝访问时换页 + 不得只看摘要。
    expect(fetch, contains('narrchat_webSearch'));
    expect(fetch, contains('配套下游'));
    expect(fetch, contains('只看摘要不算数'));
    expect(fetch, contains('HTTP 4xx/5xx'));
    expect(fetch, contains('改用其它结果页面'));
    // 截取长度随构造参数（默认 30000）出现在描述里。
    expect(fetch, contains('30000'));
  });

  test('状态工具描述：读取器点名配套编辑器，编辑器点名读取器（锚点来源）', () {
    final tools = {for (final t in allTools()) t.name: t};
    const pairs = [
      (kReadWorldStateToolName, kEditWorldStateToolName),
      (kReadCharacterStateToolName, kEditCharacterStateToolName),
      (kReadHistoryToolName, kEditHistoryToolName),
    ];
    for (final (read, edit) in pairs) {
      // 读取器：只回本栏、是编辑器的唯一锚点来源。
      expect(tools[read]!.description, contains(edit), reason: read);
      expect(tools[read]!.description, contains('唯一正确的锚点来源'), reason: read);
      expect(tools[read]!.description, contains('逐字复制'), reason: read);
      // 编辑器：逐字锚点、禁止数行号。
      expect(tools[edit]!.description, contains(read), reason: edit);
      expect(tools[edit]!.description, contains('绝不数行号'), reason: edit);
      expect(tools[edit]!.description, contains('`before`'), reason: edit);
    }
    // 编辑器各自的硬要求（防改写时丢失约束）。
    expect(
      tools[kEditWorldStateToolName]!.description,
      contains('禁止重抄整栏'),
    );
    expect(
      tools[kEditCharacterStateToolName]!.description,
      contains('禁止重抄整栏'),
    );
    expect(
      tools[kEditCharacterStateToolName]!.description,
      contains('禁止懒修改'),
    );
    expect(
      tools[kEditCharacterStateToolName]!.description,
      contains('最后手段'),
    );
    expect(
      tools[kEditHistoryToolName]!.description,
      contains('恰好一条'),
    );
    expect(tools[kEditHistoryToolName]!.description, contains('不接受'));
    // 状态块标签照旧出现在描述里（模型据此定位锚点来源）。
    expect(
      tools[kReadWorldStateToolName]!.description,
      contains('<worldState>'),
    );
    expect(
      tools[kReadCharacterStateToolName]!.description,
      contains('<characterState>'),
    );
    expect(
      tools[kReadHistoryToolName]!.description,
      contains('<memorySummary>'),
    );
  });
}
