import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/models/round.dart';
import 'package:narrchat/services/agent/agent_activity.dart';
import 'package:narrchat/services/agent/narr_agent_tool.dart';
import 'package:narrchat/services/agent/state/agent_state_working_copy.dart';
import 'package:narrchat/services/agent/state/state_tools.dart';

/// 六个状态工具（每个栏目一读一写；当前时间属于正文 `## 当前时间`，不设工具）
/// 单元测试：工具契约（name/schema/isReadOnly/activityType）与 run() 的
/// 锚点编辑 / 单栏读取语义。
void main() {
  AgentStateWorkingCopy copy({int roundIndex = 2}) => AgentStateWorkingCopy(
        roundIndex: roundIndex,
        lastRound: const Round(
          id: 1,
          bookUuid: 'b1',
          roundIndex: 1,
          worldState: '- 地点：青云宗\n- 天气：晴',
          characterState: '# 主角\n## 林远\n- 气血：80',
          memorySummary: '- 第1轮｜日期：第一天 午时｜初入宗门',
          currentTime: '第二天 午时',
        ),
        categoryNames: const ['主角', '女主角'],
      );

  /// Lv.2 = 三个栏目全部启用（读取器在前、编辑器在后）。
  List<NarrAgentTool> lv2Tools(AgentStateWorkingCopy working) =>
      buildStateTools(working, sections: AgentStateSection.values);

  /// 工具名 → 工具（按构建顺序）。
  Map<String, NarrAgentTool> byName(AgentStateWorkingCopy working) => {
        for (final t in lv2Tools(working)) t.name: t,
      };

  test('工具集（Lv.2）：六个工具、读取器在前、命名与活动类型', () {
    final tools = lv2Tools(copy());
    expect(tools.map((t) => t.name), [
      'narrchat_readWorldState',
      'narrchat_readCharacterState',
      'narrchat_readHistory',
      'narrchat_editWorldState',
      'narrchat_editCharacterState',
      'narrchat_editHistory',
    ]);
    // 旧的合并工具已完全移除；时间不属于工具（属正文 `## 当前时间` 小节）。
    expect(tools.map((t) => t.name), isNot(contains('narrchat_readState')));
    expect(tools.map((t) => t.name), isNot(contains('narrchat_editSection')));
    expect(tools.map((t) => t.name), isNot(contains('narrchat_advanceTime')));
    for (final t in tools) {
      expect(t.name, startsWith('narrchat_'));
      expect(t.activityType, AgentActivityType.tooling);
      expect(t.description, isNotEmpty);
      expect(t.parameters['type'], 'object');
    }
    // 读取器：只读、全参数可选。
    for (final t in tools.take(3)) {
      expect(t.isReadOnly, isTrue, reason: '${t.name} 应为只读');
      expect(t.parameters['required'], isEmpty);
    }
    // 编辑器：非只读、必填参数非空、schema 只有 edits（无 section 参数）。
    for (final t in tools.skip(3)) {
      expect(t.isReadOnly, isFalse, reason: '${t.name} 应为编辑器');
      expect(t.parameters['required'], isNotEmpty);
      final props = t.parameters['properties'] as Map;
      expect(props.keys, ['edits'], reason: '${t.name} 只接受 edits');
    }
  });

  test('编辑器：edits op 枚举 / before 锚点 / 无行号参数；描述点明懒修改', () {
    final tools = byName(copy());
    final edit = tools['narrchat_editCharacterState']!;
    final ps = (edit.parameters['properties'] as Map)['edits'] as Map;
    expect(ps['type'], 'array');
    final item = ps['items'] as Map;
    final opEnum = (item['properties'] as Map)['op']['enum'] as List;
    expect(
      opEnum,
      containsAll(['append', 'set', 'insertAfter', 'delete', 'noChange', 'reset']),
    );
    expect(opEnum, isNot(contains('insert')));
    expect((item['properties'] as Map).containsKey('line'), isFalse);
    expect((item['properties'] as Map).containsKey('before'), isTrue);
    // 描述明确「小幅改动用 set、noChange 是最后手段」（防模型用 noChange 偷懒）。
    expect(edit.description, contains('one op per changed line'));
    expect(edit.description, contains('LAST RESORT'));
    expect(edit.description, contains('最后手段'));
    expect(edit.description, contains('narrchat_readCharacterState'));
    // 历史编辑器：每轮恰一条 + 不接受 noChange。
    final history = tools['narrchat_editHistory']!;
    expect(history.description, contains('EXACTLY ONE entry'));
    expect(history.description, contains('不接受'));
    // 读取器描述点明「只回本栏」且时间不在快照里。
    expect(tools['narrchat_readWorldState']!.description, contains('<worldState>'));
    expect(tools['narrchat_readWorldState']!.description, contains('ONLY'));
    expect(tools['narrchat_readHistory']!.description, contains('<memorySummary>'));
  });

  test('buildStateTools：Lv.1 只注册历史一读一写', () {
    final tools = buildStateTools(
      copy(),
      sections: const [AgentStateSection.memorySummary],
    );
    expect(tools.map((t) => t.name), [
      'narrchat_readHistory',
      'narrchat_editHistory',
    ]);
    expect(tools.first.isReadOnly, isTrue);
    expect(tools.last.isReadOnly, isFalse);
  });

  test('编辑器：before 锚定命中成功，未命中 success=false（含当前行数）', () async {
    final working = copy();
    final tool = NarrchatEditCharacterStateTool(working);

    final ok = await tool.run({
      'edits': [
        {'op': 'set', 'before': '- 气血：80', 'newLine': '- 气血：60'},
      ],
    });
    expect(ok.success, isTrue);
    expect(working.characterState, contains('- 气血：60'));
    expect(working.characterState, contains('## 林远'));

    final miss = await tool.run({
      'edits': [
        {'op': 'set', 'before': '- 气血：1', 'newLine': '- 气血：100'},
      ],
    });
    expect(miss.success, isFalse);
    expect(miss.content, contains('逐字'));
    expect(miss.content, contains('3 行'));
  });

  test('编辑器：只改自己那一栏（多余的 section 参数被忽略）', () async {
    final working = copy();
    final tool = NarrchatEditWorldStateTool(working);
    final beforeCharacters = working.characterState;

    final res = await tool.run({
      // 旧版合并工具的 section 参数：现在无意义（工具自身已绑定世界状态）。
      'section': 'characterState',
      'edits': [
        {'op': 'set', 'before': '- 地点：青云宗', 'newLine': '- 地点：主峰'},
      ],
    });
    expect(res.success, isTrue);
    expect(working.worldState, contains('- 地点：主峰'));
    expect(working.characterState, beforeCharacters, reason: '角色状态不应被改动');
  });

  test('编辑器：弃用的行号参数（line）→ 明确报错引导 before/append', () async {
    final working = copy();
    final tool = NarrchatEditWorldStateTool(working);
    final before = working.worldState;

    final res = await tool.run({
      'edits': [
        {'op': 'set', 'line': 1, 'newLine': '- 地点：主峰'},
      ],
    });
    expect(res.success, isFalse);
    expect(res.content, contains('已弃用'));
    expect(res.content, contains('before'));
    expect(working.worldState, before);
  });

  test('编辑器：noChange 声明 + 历史条目校验', () async {
    final working = copy();
    final world = NarrchatEditWorldStateTool(working);

    // 缺 reason 的 noChange 不再被接受（省略 ≠ 无变化）。
    final bare = await world.run({
      'edits': [
        {'op': 'noChange'},
      ],
    });
    expect(bare.success, isFalse);
    expect(bare.content, contains('reason'));
    expect(working.touchedSections, isEmpty);

    final noChange = await world.run({
      'edits': [
        {'op': 'noChange', 'reason': '本轮未涉及世界设定'},
      ],
    });
    expect(noChange.success, isTrue);
    expect(working.touchedSections, contains(AgentStateSection.worldState));
    // UI 一行摘要 vs 回传模型全文：失败/成功都各自分栏，互不混用。
    expect(noChange.summary, contains('本轮无变化'));
    expect(noChange.summary, isNot(contains('<worldState>')));

    final history = NarrchatEditHistoryTool(working);
    final badMem = await history.run({
      'edits': [
        {
          'op': 'set',
          'before': '- 第1轮｜日期：第一天 午时｜初入宗门',
          'newLine': '- 第1轮｜日期：第一天 午时｜初入宗门',
        },
      ],
    });
    expect(badMem.success, isFalse);
    expect(badMem.content, contains('第 2 轮'));
    // 历史栏目拒绝 noChange 声明（每轮必须补一条）。
    final memNoChange = await history.run({
      'edits': [
        {'op': 'noChange', 'reason': '本轮无进展'},
      ],
    });
    expect(memNoChange.success, isFalse);
    expect(memNoChange.content, contains('不能声明 noChange'));
  });

  test('edits 非数组 → success=false', () async {
    final working = copy();
    final tool = NarrchatEditWorldStateTool(working);
    final res = await tool.run({'edits': 'x'});
    expect(res.success, isFalse);
    expect(res.content, contains('数组'));
  });

  test('整轮串行：世界/角色/历史各自编辑 + 时间由正文写入，快照正确', () async {
    final working = copy();
    final tools = byName(working);

    await tools['narrchat_editWorldState']!.run({
      'edits': [
        {'op': 'set', 'before': '- 地点：青云宗', 'newLine': '- 地点：主峰'},
      ],
    });
    await tools['narrchat_editHistory']!.run({
      'edits': [
        {
          'op': 'append',
          'newLine': '- 第2轮｜日期：第二天 申时｜主角见到掌门',
        },
      ],
    });
    // 时间属于正文：正文解析后直接写工作副本字段（无时间工具）。
    working.currentTime = '第二天 申时';

    final snap = working.mergedSnapshot();
    expect(snap.worldState, '- 地点：主峰\n- 天气：晴');
    expect(snap.memorySummary, contains('第2轮'));
    expect(snap.currentTime, '第二天 申时');
    expect(
      working.touchedSections,
      containsAll([
        AgentStateSection.worldState,
        AgentStateSection.memorySummary,
      ]),
    );
  });

  test('读取器：只返回本栏块（不含其它栏目），纯只读、幂等', () async {
    final working = copy();
    final tools = byName(working);

    final world = await tools['narrchat_readWorldState']!.run({'round': 2});
    expect(world.success, isTrue);
    expect(world.content, contains('<<<NARRCHAT_STATE round=2>>>'));
    expect(world.content, contains('<worldState>'));
    expect(world.content, contains('- 地点：青云宗'));
    // 只回本栏：角色 / 历史块不出现（拆分工具的核心收益）。
    expect(world.content, isNot(contains('<characterState>')));
    expect(world.content, isNot(contains('<memorySummary>')));
    expect(world.content, isNot(contains('## 林远')));

    final history = await tools['narrchat_readHistory']!.run({});
    expect(history.content, contains('<memorySummary>'));
    expect(history.content, contains('第1轮'));
    expect(history.content, isNot(contains('<worldState>')));

    // 纯读：不改变任何栏目、不登记触及。
    expect(
      working.sectionText(AgentStateSection.worldState),
      '- 地点：青云宗\n- 天气：晴',
    );
    expect(working.touchedSections, isEmpty);
    expect(working.declaredUnchanged, isEmpty);

    // 编辑后再读：返回工作副本当前态（幂等，调用时机不改变语义）。
    working.applyEdits(AgentStateSection.worldState, [
      const AgentLineEdit(op: 'set', before: '- 地点：青云宗', newLine: '- 地点：主峰'),
    ]);
    expect(
      (await tools['narrchat_readWorldState']!.run({})).content,
      contains('- 地点：主峰'),
    );
  });

  test('空栏目：读取器渲染 empty 标记', () async {
    final working = AgentStateWorkingCopy(roundIndex: 1);
    final tools = byName(working);
    final res = await tools['narrchat_readHistory']!.run({});
    expect(res.content, contains('<memorySummary empty="true">'));
    expect(res.success, isTrue);
  });
}
