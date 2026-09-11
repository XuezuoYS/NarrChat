import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/models/round.dart';
import 'package:narrchat/services/agent/fetch_page_tool.dart';
import 'package:narrchat/services/agent/narr_agent_tool.dart';
import 'package:narrchat/services/agent/state/agent_state_working_copy.dart';
import 'package:narrchat/services/agent/state/state_tools.dart';
import 'package:narrchat/services/agent/web_search_tool.dart';

/// Agent 工具 `description` 的文案契约（联网 2 个 + 状态 6 个共用同一形态）：
/// **英文详细要求在前、简短中文概述在后**，两者之间不加【中】一类语言标记。
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

  test('描述形态统一：英文详细要求在前、中文概述收尾，无语言标记', () {
    for (final tool in allTools()) {
      final description = tool.description;
      final reason = '${tool.name}：$description';
      // 旧的显式语言标记已全部移除。
      for (final marker in const ['【中】', '【EN】', '[中]', '[EN]']) {
        expect(description, isNot(contains(marker)), reason: reason);
      }
      // 英文详细要求在前（以英文开头）、中文概述在后（以中文句号收尾）。
      expect(RegExp(r'^[A-Za-z]').hasMatch(description), isTrue, reason: reason);
      expect(description.trimRight(), endsWith('。'), reason: reason);
      // 中英两段都在（英文词 + 中文句子）。
      expect(RegExp(r'[A-Za-z]{3,}').hasMatch(description), isTrue,
          reason: reason);
      expect(RegExp(r'[\u4e00-\u9fff]').hasMatch(description), isTrue,
          reason: reason);
    }
  });

  test('联网工具描述承载调用指导：主动使用 → 搜索 → 必须打开页面读正文', () {
    final tools = {for (final t in allTools()) t.name: t};
    final search = tools['narrchat_webSearch']!.description;
    final fetch = tools['narrchat_webFetchPage']!.description;

    // 搜索：主动使用（不必等用户点名）+ 摘要不足以支撑创作 + 下一步工具。
    expect(search, contains('without waiting for the user'));
    expect(search, contains('summary alone is not sufficient'));
    expect(search, contains('narrchat_webFetchPage'));
    expect(search, contains('联网搜索获取真实世界信息'));
    expect(search, contains('阅读正文'));

    // 打开页面：搜索的配套下游 + 拒绝访问时换页 + 不得只依赖摘要。
    expect(fetch, contains('narrchat_webSearch'));
    expect(fetch, contains('MUST open'));
    expect(fetch, contains('HTTP 4xx/5xx'));
    expect(fetch, contains('打开网页链接并返回页面正文'));
    expect(fetch, contains('不得只凭摘要'));
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
      expect(tools[read]!.description, contains('ONLY'), reason: read);
      expect(tools[read]!.description, contains('逐字复制'), reason: read);
      // 编辑器：逐字锚点、禁止行号（中英两边都点明）。
      expect(tools[edit]!.description, contains(read), reason: edit);
      expect(tools[edit]!.description, contains('NEVER line numbers'),
          reason: edit);
      expect(tools[edit]!.description, contains('before'), reason: edit);
    }
    // 编辑器各自的英文硬要求（沿用原描述的措辞，防改写时丢失约束）。
    expect(
      tools[kEditWorldStateToolName]!.description,
      contains('NEVER re-type the whole section'),
    );
    expect(
      tools[kEditCharacterStateToolName]!.description,
      contains('NEVER re-type the whole section'),
    );
    expect(
      tools[kEditCharacterStateToolName]!.description,
      contains('LAST RESORT'),
    );
    expect(
      tools[kEditHistoryToolName]!.description,
      contains('EXACTLY ONE entry'),
    );
    // 状态类栏目「只改变更行」的中文概述同样保留。
    expect(
      tools[kEditWorldStateToolName]!.description,
      contains('禁止重抄整栏'),
    );
    expect(
      tools[kEditCharacterStateToolName]!.description,
      contains('禁止重抄整栏'),
    );
    expect(tools[kEditHistoryToolName]!.description, contains('不接受'));
  });
}
