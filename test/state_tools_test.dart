import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/models/round.dart';
import 'package:narrchat/services/agent/agent_activity.dart';
import 'package:narrchat/services/agent/state/agent_state_working_copy.dart';
import 'package:narrchat/services/agent/state/state_tools.dart';

/// 状态工具（锚定式 `narrchat_readState` / `narrchat_editSection`；当前时间
/// 属于正文 `## 当前时间`，不设工具）单元测试：
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
      'narrchat_readState',
      'narrchat_editSection',
    ]);
    // 当前时间不属于工具（属正文 `## 当前时间` 小节）。
    expect(tools.map((t) => t.name), isNot(contains('narrchat_advanceTime')));
    for (final t in tools) {
      expect(t.name, startsWith('narrchat_'));
      expect(t.activityType, AgentActivityType.tooling);
      expect(t.description, isNotEmpty);
      expect(t.parameters['type'], 'object');
      // readState 全参数可选（round 仅核对用）；编辑器必填参数非空。
      if (t.name != kReadStateToolName) {
        expect(t.parameters['required'], isNotEmpty);
      }
    }
    final ps = (tools[1].parameters['properties'] as Map)['edits'] as Map;
    expect(ps['type'], 'array');
    final opEnum = ((ps['items'] as Map)['properties'] as Map)['op']['enum'] as List;
    expect(opEnum, containsAll(['append', 'set', 'insertAfter', 'delete', 'noChange', 'reset']));
    expect(opEnum, isNot(contains('insert')));
    expect(((ps['items'] as Map)['properties'] as Map).containsKey('line'), isFalse);
    expect(((ps['items'] as Map)['properties'] as Map).containsKey('before'), isTrue);
    // 描述明确「小幅改动用 set、noChange 是最后手段」（防模型用 noChange 偷懒）。
    expect(tools[1].description, contains('one op PER CHANGED LINE'));
    expect(tools[1].description, contains('LAST RESORT'));
    expect(tools[1].description, contains('最后手段'));
    expect(tools[1].description, contains('视为失败'));
    // 读取器描述明确快照不含时间（时间在正文 `## 当前时间`）。
    expect(tools[0].description, contains('time is NOT included'));
    expect(tools[0].description, contains('当前时间'));
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

    // 缺 reason 的 noChange 不再被接受（省略 ≠ 无变化）。
    final bare = await tool.run({
      'section': 'worldState',
      'edits': [
        {'op': 'noChange'},
      ],
    });
    expect(bare.success, isFalse);
    expect(bare.content, contains('reason'));
    expect(working.touchedSections, isEmpty);

    final noChange = await tool.run({
      'section': 'worldState',
      'edits': [
        {'op': 'noChange', 'reason': '本轮未涉及世界设定'},
      ],
    });
    expect(noChange.success, isTrue);
    expect(working.touchedSections, contains(AgentStateSection.worldState));
    // UI 一行摘要 vs 回传模型全文：失败/成功都各自分栏，互不混用。
    expect(noChange.summary, contains('本轮无变化'));
    expect(noChange.summary, isNot(contains('<worldState>')));

    final badMem = await tool.run({
      'section': 'memorySummary',
      'edits': [
        {'op': 'set', 'before': '- 第1轮｜日期：第一天 午时｜初入宗门', 'newLine': '- 第1轮｜日期：第一天 午时｜初入宗门'},
      ],
    });
    expect(badMem.success, isFalse);
    expect(badMem.content, contains('第 2 轮'));
    // 记忆栏目拒绝 noChange 声明（每轮必须补一条）。
    final memNoChange = await tool.run({
      'section': 'memorySummary',
      'edits': [
        {'op': 'noChange', 'reason': '本轮无进展'},
      ],
    });
    expect(memNoChange.success, isFalse);
    expect(memNoChange.content, contains('不能声明 noChange'));
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

  test('整轮串行：世界/角色/记忆锚点编辑 + 时间由正文写入，快照正确', () async {
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
    // readState 渲染包含正文时间。
    expect(
      (await tools['narrchat_readState']!.run({})).content,
      contains('第二天 申时'),
    );
  });

  test('readState：纯只读，返回工作副本当前渲染（不触碰任何栏目）', () async {
    final working = copy();
    final tool = NarrchatReadStateTool(working);

    final result = await tool.run({'round': 2});
    expect(result.success, isTrue);
    expect(result.content, contains('<<<NARRCHAT_STATE round=2>>>'));
    expect(result.content, contains('- 地点：青云宗'));
    expect(result.content, contains('## 林远'));
    // 纯读：不改变任何栏目、不登记触及。
    expect(working.sectionText(AgentStateSection.worldState), '- 地点：青云宗\n- 天气：晴');
    expect(working.touchedSections, isEmpty);
    expect(working.declaredUnchanged, isEmpty);
    // 正文轮 or 状态轮调用都返回同一渲染（工作副本当前态）。
    working.applyEdits(AgentStateSection.worldState, [
      const AgentLineEdit(op: 'set', before: '- 地点：青云宗', newLine: '- 地点：主峰'),
    ]);
    expect((await tool.run({})).content, contains('- 地点：主峰'));
  });
}
