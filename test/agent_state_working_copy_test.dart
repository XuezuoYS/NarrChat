import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/models/round.dart';
import 'package:narrchat/services/agent/state/agent_state_working_copy.dart';
import 'package:narrchat/services/agent/state/state_tools.dart';
import 'package:narrchat/services/prompt_formats.dart';

/// `AgentStateWorkingCopy` 锚定式编辑单元测试。
///
/// 核心断言（对齐 DeepSeek Harness `edit` / `str_replace_editor` 的定位机制）：
/// 锚点 `before` **逐字匹配 + 唯一性校验**（未命中 / 不唯一返回精确错误，
/// 不提交）；`append` 追加到栏目末尾（无需定位）；同调用内按顺序应用
/// （锚点在应用时刻解析）、**事务化**（任一失败不提交）、**字节级保留**
/// （未触及行原样保留）、记忆栏目必须含本轮条目、noChange 计入「触及」。
void main() {
  AgentStateWorkingCopy copy({
    Round? lastRound,
    List<String> categories = const ['主角', '女主角'],
    int roundIndex = 2,
  }) => AgentStateWorkingCopy(
        roundIndex: roundIndex,
        lastRound: lastRound,
        categoryNames: categories,
      );

  const baseRound = Round(
    id: 1,
    bookUuid: 'b1',
    roundIndex: 1,
    worldState: '- 地点：青云宗\n- 天气：晴',
    characterState: '# 主角\n## 林远\n- 气血：80\n\n# 女主角\n## 苏清月\n- 心情：平静',
    memorySummary: '- 第1轮｜日期：第一天 午时｜初入宗门',
    currentTime: '第二天 午时',
  );

  group('锚点编辑（set / insertAfter / delete / append）', () {
    test('set：before 整行逐字命中，未触及行与行尾字节保留', () {
      final c = copy(lastRound: baseRound);
      final r = c.applyEdits(AgentStateSection.characterState, [
        const AgentLineEdit(
          op: 'set',
          before: '- 气血：80',
          newLine: '- 气血：60',
        ),
      ]);
      expect(r.applied, isTrue);
      expect(c.characterState, contains('- 气血：60'));
      expect(c.characterState, contains('## 林远'));
      expect(c.characterState, contains('心情：平静'));
      expect(c.worldState, baseRound.worldState);
    });

    test('insertAfter：在锚点行后插入；锚点行不变', () {
      final c = copy(lastRound: baseRound);
      expect(
        c.applyEdits(AgentStateSection.worldState, [
          const AgentLineEdit(
            op: 'insertAfter',
            before: '- 天气：晴',
            newLine: '- 事件：宗门大比',
          ),
        ]).applied,
        isTrue,
      );
      expect(c.worldState, '- 地点：青云宗\n- 天气：晴\n- 事件：宗门大比');
    });

    test('delete：before 锚定删除，未触及行保留', () {
      final c = copy(lastRound: baseRound);
      expect(
        c.applyEdits(AgentStateSection.worldState, [
          const AgentLineEdit(op: 'delete', before: '- 天气：晴'),
        ]).applied,
        isTrue,
      );
      expect(c.worldState, '- 地点：青云宗');
    });

    test('append：追加到栏目末尾；空栏目即首行；结尾换行不产生空行', () {
      final c = copy(lastRound: baseRound);
      expect(
        c.applyEdits(AgentStateSection.worldState, [
          const AgentLineEdit(
            op: 'append',
            newLine: '- 事件：宗门大比',
          ),
        ]).applied,
        isTrue,
      );
      expect(c.worldState, '- 地点：青云宗\n- 天气：晴\n- 事件：宗门大比');

      // 空栏目：append 即首行。
      final c2 = copy(lastRound: const Round(id: 1, bookUuid: 'b1', roundIndex: 1));
      expect(
        c2.applyEdits(AgentStateSection.worldState, [
          const AgentLineEdit(op: 'append', newLine: '- 地点：青云宗'),
        ]).applied,
        isTrue,
      );
      expect(c2.worldState, '- 地点：青云宗');

      // 来源以换行结尾：append 不插入多余空行。
      final c3 = copy(
        lastRound: const Round(
          id: 1,
          bookUuid: 'b1',
          roundIndex: 1,
          worldState: '- 地点：青云宗\n',
        ),
      );
      c3.applyEdits(AgentStateSection.worldState, [
        const AgentLineEdit(op: 'append', newLine: '- 天气：晴'),
      ]);
      expect(c3.worldState, '- 地点：青云宗\n- 天气：晴');
    });

    test('多行锚点：before 含 \\n 命中连续多行', () {
      final c = copy(lastRound: baseRound);
      expect(
        c.applyEdits(AgentStateSection.characterState, [
          const AgentLineEdit(
            op: 'set',
            before: '## 林远\n- 气血：80',
            newLine: '## 林远\n- 气血：60',
          ),
        ]).applied,
        isTrue,
      );
      expect(c.characterState, contains('- 气血：60'));
      expect(c.characterState, contains('## 林远'));
    });

    test('宽松匹配：逐字未命中但空白差异唯一命中 → 回退命中', () {
      final c = copy(
        lastRound: const Round(
          id: 1,
          bookUuid: 'b1',
          roundIndex: 1,
          worldState: '- 地点：  青云宗',
        ),
      );
      final r = c.applyEdits(AgentStateSection.worldState, [
        const AgentLineEdit(op: 'set', before: '- 地点： 青云宗', newLine: '- 地点：主峰'),
      ]);
      expect(r.applied, isTrue);
      expect(c.worldState, '- 地点：主峰');
    });

    test('锚点未找到 → 报错（含当前行数）且不提交', () {
      final c = copy(lastRound: baseRound);
      final before = c.worldState;
      final r = c.applyEdits(AgentStateSection.worldState, [
        const AgentLineEdit(op: 'set', before: '- 地点：不存在', newLine: '- x'),
      ]);
      expect(r.applied, isFalse);
      expect(r.message, contains('逐字'));
      expect(r.message, contains('2 行'));
      expect(c.worldState, before);
    });

    test('锚点不唯一 → 报错含命中行号且不提交（事务化）', () {
      final c = copy(
        lastRound: const Round(
          id: 1,
          bookUuid: 'b1',
          roundIndex: 1,
          characterState: '# 主角\n## 林远\n- 气血：80\n\n# 敌役\n## 林远\n- 气血：80',
        ),
      );
      final before = c.characterState;
      // 同调用内：先一条合法 set，再一条歧义 delete → 全部不提交。
      final r = c.applyEdits(AgentStateSection.characterState, [
        const AgentLineEdit(op: 'set', before: '# 主角', newLine: '# 主角（已重写）'),
        const AgentLineEdit(op: 'delete', before: '## 林远'),
      ]);
      expect(r.applied, isFalse);
      expect(r.message, contains('不唯一'));
      expect(r.message, contains('2、'));
      expect(c.characterState, before);
    });

    test('未知 op → 报错且不提交', () {
      final c = copy(lastRound: baseRound);
      final r = c.applyEdits(AgentStateSection.worldState, [
        const AgentLineEdit(op: 'setLine', before: '- 天气：晴'),
      ]);
      expect(r.applied, isFalse);
      expect(r.message, contains('未知 op'));
    });
  });

  group('noChange / reset / 触及栏目', () {
    test('noChange：附 reason 才成立，不计变更但栏目视为已触及', () {
      final c = copy(lastRound: baseRound);
      final r = c.applyEdits(AgentStateSection.worldState, [
        const AgentLineEdit(op: 'noChange', reason: '本轮未涉及世界设定'),
      ]);
      expect(r.applied, isTrue);
      expect(c.touchedSections, contains(AgentStateSection.worldState));
      // 声明登记进 declaredUnchanged：缺口判定据此放行（合法无变化）。
      expect(
          c.declaredUnchanged[AgentStateSection.worldState], '本轮未涉及世界设定');
      expect(c.worldState, baseRound.worldState);
    });

    test('noChange 缺 reason → 拒绝（省略不等于无变化）', () {
      final c = copy(lastRound: baseRound);
      final r = c.applyEdits(AgentStateSection.worldState, [
        const AgentLineEdit(op: 'noChange'),
      ]);
      expect(r.applied, isFalse);
      expect(r.message, contains('reason'));
      expect(c.touchedSections, isEmpty);
      expect(c.failedSections, contains(AgentStateSection.worldState));
    });

    test('reset：整栏目替换（明确重排/空栏目）', () {
      final c = copy(lastRound: baseRound);
      expect(
        c.applyEdits(AgentStateSection.worldState, [
          const AgentLineEdit(op: 'reset', newLine: '新世界：荒野\n- 风沙'),
        ]).applied,
        isTrue,
      );
      expect(c.worldState, '新世界：荒野\n- 风沙');
      expect(c.touchedSections, contains(AgentStateSection.worldState));
    });
  });

  group('记忆总结（每轮一条承诺）', () {
    test('变更后不含本轮条目 → 校验失败且不提交；noChange 被拒', () {
      final c = copy(lastRound: baseRound, roundIndex: 2);
      // 只保留第 1 轮条目（用 set 重建旧条目 = 未含本轮条目）。
      final r = c.applyEdits(AgentStateSection.memorySummary, [
        const AgentLineEdit(
          op: 'set',
          before: '- 第1轮｜日期：第一天 午时｜初入宗门',
          newLine: '- 第1轮｜日期：第一天 午时｜初入宗门',
        ),
      ]);
      expect(r.applied, isFalse);
      expect(r.message, contains('第 2 轮'));
      expect(r.message, contains('append'));
      expect(c.memorySummary, baseRound.memorySummary);

      final bad = c.applyEdits(AgentStateSection.memorySummary, [
        const AgentLineEdit(op: 'noChange'),
      ]);
      expect(bad.applied, isFalse);
      expect(bad.message, contains('不能声明 noChange'));
    });

    test('append 本轮条目 → 通过；历史条目保留', () {
      final c = copy(lastRound: baseRound, roundIndex: 2);
      final r = c.applyEdits(AgentStateSection.memorySummary, [
        const AgentLineEdit(
          op: 'append',
          newLine: '- 第2轮｜日期：第二天 申时｜主角见到掌门',
        ),
      ]);
      expect(r.applied, isTrue);
      expect(c.memorySummary, contains('第2轮'));
      expect(c.memorySummary, contains('第1轮'));
      // 条目追加在最后一行。
      expect(c.memorySummary.split('\n').last, contains('第2轮'));
    });
  });

  test('当前时间属于正文：字段直写（无时间工具），mergedSnapshot 一致', () {
    final c = copy(lastRound: baseRound);
    c.currentTime = '仙历2年七月十八日，亥时中（议事堂内）';
    final snap = c.mergedSnapshot();
    expect(snap.currentTime, '仙历2年七月十八日，亥时中（议事堂内）');
    expect(snap.worldState, baseRound.worldState);
  });

  group('快照渲染（模型唯一的状态来源）', () {
    test('轮号标记 / 单栏目标签（无时间）/ 空栏目 empty="true" / 禁止复读提示', () {
      final c = copy(lastRound: baseRound, roundIndex: 4);
      final world = c.renderSection(AgentStateSection.worldState);
      expect(world, startsWith('<<<NARRCHAT_STATE round=4>>>'));
      expect(world, endsWith('<<<END_NARRCHAT_STATE>>>'));
      // 时间属于正文：快照不含 <time> 块。
      expect(world, isNot(contains('<time>')));
      expect(world, contains('- 地点：青云宗'));
      // 只渲染被请求的那一栏（读取工具按栏目拆分）。
      expect(world, isNot(contains('<characterState>')));
      expect(world, isNot(contains('## 苏清月')));
      expect(world, isNot(contains('<memorySummary>')));
      expect(
        c.renderSection(AgentStateSection.memorySummary),
        contains('第1轮'),
      );
      // 空栏目显式标注（模型据此知道该用 op=reset / 首次填入）。
      expect(
        copy(roundIndex: 1).renderSection(AgentStateSection.worldState),
        contains('<worldState empty="true"></worldState>'),
      );
      // 输入身份声明（防止把快照块当成输出模板复读）：块头之后**英文行在前、
      // 中文行在后**，两行都不带 [EN] / 【中】 语言标记。
      expect(world, contains('it is input, not an output format'));
      expect(world, contains('它是输入，不是输出格式'));
      expect(world, isNot(contains('[EN]')));
      expect(world, isNot(contains('【中】')));
      final lines = world.split('\n');
      expect(lines[1], startsWith('This is the app-side state truth'));
      expect(lines[2], startsWith('这是应用侧状态真值'));
    });

    test('首轮渲染与库快照同源（工作副本基座 = 库内快照）', () {
      final c = AgentStateWorkingCopy(roundIndex: 1, lastRound: baseRound);
      final world = c.renderSection(AgentStateSection.worldState);
      expect(world, contains('<<<NARRCHAT_STATE round=1>>>'));
      expect(world, contains('- 天气：晴'));
      expect(
        c.renderSection(AgentStateSection.characterState),
        contains('- 心情：平静'),
      );
      expect(c.sectionText(AgentStateSection.memorySummary),
          baseRound.memorySummary);
    });

    test('契约引用的标签与渲染器一致（改一处必须同步另一处）', () {
      final contract = const AgentLv2PromptFormat().systemHead.join('\n');
      final c = copy(lastRound: baseRound);
      for (final section in AgentStateSection.values) {
        final tag = '<${section.tag}>';
        expect(c.renderSection(section), contains(tag),
            reason: '渲染器缺标签 $tag');
        expect(contract, contains(tag), reason: 'Lv.2 契约未引用 $tag');
      }
      // 时间在正文（## 当前时间），契约与快照都不再以 <time> 引用。
      final world = c.renderSection(AgentStateSection.worldState);
      expect(world, isNot(contains('<time>')));
      expect(contract, isNot(contains('<time>')));
      // 契约引用六个工具（读取器在前）。
      for (final name in kStateToolNames) {
        expect(contract, contains(name), reason: 'Lv.2 契约未引用 $name');
      }
    });
  });
}
