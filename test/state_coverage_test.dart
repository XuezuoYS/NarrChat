import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/models/round.dart';
import 'package:narrchat/services/agent/state/agent_state_working_copy.dart';
import 'package:narrchat/services/agent/state/state_coverage.dart';

/// `inspectState` 缺口判定单元测试：三类缺口的触发与放行条件。
///
/// 判定只看应用侧工作副本的事实（编辑过 / 声明过 / 角色块变没变），
/// 是「要不要发起状态轮」的唯一依据，故逐条锁死。
/// 当前时间属于**正文**（`## 当前时间` 小节），不参与缺口判定。
void main() {
  const lastRound = Round(
    id: 1,
    bookUuid: 'b1',
    roundIndex: 1,
    worldState: '- 地点：青云宗\n- 天气：晴',
    characterState: '# 主角\n## 林远\n- 气血：80\n## 沈清\n- 位置：外门',
    memorySummary: '- 第1轮｜日期：第一天 午时｜初入宗门',
    currentTime: '第一天 午时',
  );

  AgentStateWorkingCopy copy() => AgentStateWorkingCopy(
        roundIndex: 2,
        lastRound: lastRound,
        categoryNames: const ['主角'],
      );

  /// 把某栏目改成真正不同于基座的一行。
  void editSection(
    AgentStateWorkingCopy c,
    AgentStateSection section,
    String before,
    String newLine,
  ) {
    final r = c.applyEdits(section, [
      AgentLineEdit(op: 'set', before: before, newLine: newLine),
    ]);
    expect(r.applied, isTrue, reason: r.message);
  }

  List<StateGapKind> kinds(List<StateGap> gaps) =>
      [for (final g in gaps) g.kind];

  Set<AgentStateSection?> sectionsOf(
    List<StateGap> gaps,
    StateGapKind kind,
  ) =>
      {for (final g in gaps) if (g.kind == kind) g.section};

  test('刚开播的工作副本：三栏目全部未触及（时间不参与判定）', () {
    final gaps = inspectState(
      copy: copy(),
      story: '林远握紧了剑。',
    );
    expect(kinds(gaps), [
      StateGapKind.sectionUntouched,
      StateGapKind.sectionUntouched,
      StateGapKind.sectionUntouched,
      StateGapKind.lazyCharacters,
    ]);
    expect(
      sectionsOf(gaps, StateGapKind.sectionUntouched),
      AgentStateSection.values.toSet(),
    );
    // 面向模型：英文指令行在前 + 中文一行摘要；面向用户：短提示。
    final first = gaps.first;
    expect(first.modelText, startsWith('Section "worldState"'));
    expect(first.modelText, contains('【中】世界状态栏目'));
    expect(first.uiText, '世界状态本轮未更新');
    // 懒修改点名角色（出场且块未变）：指令以「实际编辑」为主，noChange 仅居末。
    final lazy = gaps.firstWhere((g) => g.kind == StateGapKind.lazyCharacters);
    expect(lazy.names, ['林远']);
    expect(lazy.uiText, '角色未更新：林远');
    expect(lazy.modelText, contains('op=set'));
    expect(lazy.modelText, contains('懒修改'));
    // noChange 是最后手段：只有「被提及但毫无新信息」才允许，且禁止全队一起声明。
    expect(lazy.modelText, contains('op=noChange'));
    expect(lazy.modelText, contains('只是被提及'));
  });

  test('全部补齐（三栏目实际编辑）→ 无缺口；时间不触发缺口', () {
    final c = copy();
    editSection(c, AgentStateSection.worldState, '- 天气：晴', '- 天气：雨');
    editSection(c, AgentStateSection.characterState, '- 气血：80', '- 气血：70');
    c.applyEdits(AgentStateSection.memorySummary, [
      const AgentLineEdit(
        op: 'append',
        newLine: '- 第2轮｜日期：第一天 申时｜林远赴主峰',
      ),
    ]);
    // 时间来自正文（工作副本字段直接由正文解析写入），不参与缺口判定。
    c.currentTime = '第一天 申时';
    expect(
      inspectState(copy: c, story: '林远赴主峰。'),
      isEmpty,
    );
  });

  test('op=noChange + reason 是合法路径（不再被判为无效编辑）', () {
    final c = copy();
    expect(
      c
          .applyEdits(AgentStateSection.worldState, [
            const AgentLineEdit(op: 'noChange', reason: '本轮未涉及世界设定'),
          ])
          .applied,
      isTrue,
    );
    final gaps = inspectState(
      copy: c,
      story: '沈清点头。',
      checkLazy: false,
    );
    expect(
      kinds(gaps),
      containsAll(<StateGapKind>[
        StateGapKind.sectionUntouched,
        StateGapKind.sectionUntouched,
      ]),
    );
    // 声明过的世界状态不再被点名。
    expect(
      sectionsOf(gaps, StateGapKind.sectionUntouched),
      isNot(contains(AgentStateSection.worldState)),
    );
  });

  test('编辑过但整栏逐字节回到原值 → sectionUnchanged（记忆栏除外）', () {
    final c = copy();
    // set 回原值：视为无效编辑。
    editSection(c, AgentStateSection.worldState, '- 天气：晴', '- 天气：晴');
    final gaps = inspectState(
      copy: c,
      story: '沈清离开。',
      checkLazy: false,
    );
    expect(
      sectionsOf(gaps, StateGapKind.sectionUnchanged),
      {AgentStateSection.worldState},
    );
    expect(
      gaps.firstWhere(
          (g) => g.kind == StateGapKind.sectionUnchanged).modelText,
      contains('byte-identical'),
    );

    // 记忆栏目不参与 unchanged 判定：本轮条目缺失已被 applyEdits 硬拒，
    // 「改了又改回原值」在它那里根本不可能提交成功（故此处只登记为未触及）。
    final m = copy();
    m.applyEdits(AgentStateSection.memorySummary, [
      const AgentLineEdit(
        op: 'set',
        before: '- 第1轮｜日期：第一天 午时｜初入宗门',
        newLine: '- 第1轮｜日期：第一天 午时｜初入宗门',
      ),
    ]);
    expect(
      sectionsOf(
        inspectState(
          copy: m,
          story: '沈清离开。',
          checkLazy: false,
        ),
        StateGapKind.sectionUnchanged,
      ),
      isEmpty,
    );
  });

  test('时间属于正文：正文不含角色名时，无论时间推进与否都无缺口', () {
    final c = copy();
    editSection(c, AgentStateSection.worldState, '- 天气：晴', '- 天气：雨');
    editSection(c, AgentStateSection.characterState, '- 位置：外门', '- 位置：主峰');
    c.applyEdits(AgentStateSection.memorySummary, [
      const AgentLineEdit(
        op: 'append',
        newLine: '- 第2轮｜日期：第一天 午时｜林远登主峰',
      ),
    ]);
    // 时间未动（沿用上一轮）→ 不判缺口；推进后同样不判。
    expect(
      inspectState(copy: c, story: '山巅风雪大作。'),
      isEmpty,
    );
    c.currentTime = '第一天 申时';
    expect(
      inspectState(copy: c, story: '山巅风雪大作。'),
      isEmpty,
    );
  });

  group('lazyCharacterNames', () {
    test('出场且块未变的具名角色被点名；改过 / 未出场 / 单字名不算', () {
      final names = lazyCharacterNames(
        story: '林远与沈清并肩而立。',
        previousCharacterState: lastRound.characterState,
        currentCharacterState: lastRound.characterState,
      );
      expect(names, ['林远', '沈清']);

      // 沈清的块被改过 → 只剩林远。
      final c = copy();
      editSection(c, AgentStateSection.characterState, '- 位置：外门', '- 位置：主峰');
      expect(
        lazyCharacterNames(
          story: '林远与沈清并肩而立。',
          previousCharacterState: c.baseCharacterState,
          currentCharacterState: c.characterState,
        ),
        ['林远'],
      );

      // 正文没提到 → 不点名；空正文 → 一律不点名。
      expect(
        lazyCharacterNames(
          story: '山门寂然。',
          previousCharacterState: lastRound.characterState,
          currentCharacterState: lastRound.characterState,
        ),
        isEmpty,
      );
      expect(
        lazyCharacterNames(
          story: '   ',
          previousCharacterState: lastRound.characterState,
          currentCharacterState: lastRound.characterState,
        ),
        isEmpty,
      );
    });

    test('点名最多 6 个（提示不失控）', () {
      final state = List.generate(
        8,
        (i) => '## 角色$i号\n- 状态：无',
      ).join('\n');
      final story = List.generate(8, (i) => '角色$i号').join('、');
      final names = lazyCharacterNames(
        story: story,
        previousCharacterState: state,
        currentCharacterState: state,
      );
      expect(names, hasLength(8));
      expect(
        StateGap(
          kind: StateGapKind.lazyCharacters,
          names: names,
        ).uiText,
        '角色未更新：角色0号、角色1号、角色2号、角色3号、角色4号、角色5号',
      );
    });
  });
}
