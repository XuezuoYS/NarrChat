import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/models/round.dart';
import 'package:narrchat/services/agent/state/agent_state_working_copy.dart';

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
    test('noChange：不计变更但栏目视为已触及', () {
      final c = copy(lastRound: baseRound);
      final r = c.applyEdits(AgentStateSection.worldState, [
        const AgentLineEdit(op: 'noChange'),
      ]);
      expect(r.applied, isTrue);
      expect(c.touchedSections, contains(AgentStateSection.worldState));
      expect(c.worldState, baseRound.worldState);
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

  test('setTime：任意非空接受；空报错；mergedSnapshot 一致', () {
    final c = copy(lastRound: baseRound);
    expect(c.setTime('仙历2年七月十八日，亥时中（议事堂内）').applied, isTrue);
    expect(c.setTime('  ').applied, isFalse);
    final snap = c.mergedSnapshot();
    expect(snap.currentTime, '仙历2年七月十八日，亥时中（议事堂内）');
    expect(snap.worldState, baseRound.worldState);
  });
}
