import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/models/round.dart';
import 'package:narrchat/services/agent/agent_activity.dart';
import 'package:narrchat/services/agent/state/agent_state_working_copy.dart';
import 'package:narrchat/services/agent/state/state_tools.dart';

/// 状态工具（锚定式 `narrchat_editSection` / `narrchat_advanceTime`）单元测试：
/// 工具契约（name/schema/activityType）与 run() 的锚点编辑语义。
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

  test('工具集：名称 / 前缀 / 活动类型 / schema（锚点参数）', () {
    final tools = buildStateTools(copy());
    expect(tools.map((t) => t.name), [
      'narrchat_editSection',
      'narrchat_advanceTime',
    ]);
    for (final t in tools) {
      expect(t.name, startsWith('narrchat_'));
      expect(t.activityType, AgentActivityType.tooling);
      expect(t.description, isNotEmpty);
      expect(t.parameters['type'], 'object');
      expect(t.parameters['required'], isNotEmpty);
    }
    final ps = (tools[0].parameters['properties'] as Map)['edits'] as Map;
    expect(ps['type'], 'array');
    final opEnum = ((ps['items'] as Map)['properties'] as Map)['op']['enum'] as List;
    expect(opEnum, containsAll(['append', 'set', 'insertAfter', 'delete', 'noChange', 'reset']));
    expect(opEnum, isNot(contains('insert')));
    expect(((ps['items'] as Map)['properties'] as Map).containsKey('line'), isFalse);
    expect(((ps['items'] as Map)['properties'] as Map).containsKey('before'), isTrue);
  });

  test('editSection：before 锚定命中成功，未命中 success=false（含当前行数）', () async {
    final working = copy();
    final tool = NarrchatEditSectionTool(working);

    final ok = await tool.run({
      'section': 'characterState',
      'edits': [
        {'op': 'set', 'before': '- 气血：80', 'newLine': '- 气血：60'},
      ],
    });
    expect(ok.success, isTrue);
    expect(working.characterState, contains('- 气血：60'));
    expect(working.characterState, contains('## 林远'));

    final miss = await tool.run({
      'section': 'characterState',
      'edits': [
        {'op': 'set', 'before': '- 气血：1', 'newLine': '- 气血：100'},
      ],
    });
    expect(miss.success, isFalse);
    expect(miss.content, contains('逐字'));
    expect(miss.content, contains('3 行'));
  });

  test('editSection：弃用的行号参数（line）→ 明确报错引导 before/append', () async {
    final working = copy();
    final tool = NarrchatEditSectionTool(working);
    final before = working.worldState;

    final res = await tool.run({
      'section': 'worldState',
      'edits': [
        {'op': 'set', 'line': 1, 'newLine': '- 地点：主峰'},
      ],
    });
    expect(res.success, isFalse);
    expect(res.content, contains('已弃用'));
    expect(res.content, contains('before'));
    expect(working.worldState, before);
  });

  test('editSection：noChange 声明 + 记忆条目校验', () async {
    final working = copy();
    final tool = NarrchatEditSectionTool(working);

    final noChange = await tool.run({
      'section': 'worldState',
      'edits': [
        {'op': 'noChange'},
      ],
    });
    expect(noChange.success, isTrue);
    expect(working.touchedSections, contains(AgentStateSection.worldState));

    final badMem = await tool.run({
      'section': 'memorySummary',
      'edits': [
        {'op': 'set', 'before': '- 第1轮｜日期：第一天 午时｜初入宗门', 'newLine': '- 第1轮｜日期：第一天 午时｜初入宗门'},
      ],
    });
    expect(badMem.success, isFalse);
    expect(badMem.content, contains('第 2 轮'));
  });

  test('非法 section / edits 非数组 → success=false', () async {
    final working = copy();
    final tool = NarrchatEditSectionTool(working);
    expect(
      (await tool.run({'section': '不存在', 'edits': const []})).success,
      isFalse,
    );
    expect(
      (await tool.run({'section': 'worldState', 'edits': 'x'})).success,
      isFalse,
    );
  });

  test('advanceTime：非空通过；空报错', () async {
    final working = copy();
    final tool = NarrchatAdvanceTimeTool(working);
    expect(
      (await tool.run({'time': '仙历2年七月十八日，亥时中'})).success,
      isTrue,
    );
    expect((await tool.run({'time': ''})).success, isFalse);
  });

  test('整轮串行：世界/角色/记忆锚点编辑 + 时间，快照正确', () async {
    final working = copy();
    final tools = {for (final t in buildStateTools(working)) t.name: t};

    await tools['narrchat_editSection']!.run({
      'section': 'worldState',
      'edits': [
        {'op': 'set', 'before': '- 地点：青云宗', 'newLine': '- 地点：主峰'},
      ],
    });
    await tools['narrchat_editSection']!.run({
      'section': 'memorySummary',
      'edits': [
        {
          'op': 'append',
          'newLine': '- 第2轮｜日期：第二天 申时｜主角见到掌门',
        },
      ],
    });
    await tools['narrchat_advanceTime']!.run({'time': '第二天 申时'});

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
}
