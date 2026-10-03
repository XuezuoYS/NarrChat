import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/models/agent_mode_level.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/services/agent/agent_stage_directives.dart';
import 'package:narrchat/services/agent/state/agent_state_working_copy.dart';
import 'package:narrchat/services/memory_merge_planner.dart';

/// `AgentStageDirectives`（Agent 阶段帧指令的唯一真源）行为测试。
///
/// 该构建器由 `AgentRoundRunner`（执行器）与 `prompt_interface`（接口层）共用，
/// 因此这里锁的是「帧指令内容」本身：记忆帧的阶段说明与合并指令、维护帧的
/// 档位文案 / 清单排序 / 条数上限 / 空清单兜底。文案逐字搬迁自执行器旧实现，
/// 断言按行为与关键片段写，避免与实现常量自比。
void main() {
  const directives = AgentStageDirectives();

  Round lastRound({String memory = ''}) => Round(
        id: 1,
        bookUuid: 'b1',
        roundIndex: 1,
        userInput: '我踏入青云宗。',
        aiNarrative: '山门巍峨。',
        memorySummary: memory,
      );

  AgentStateWorkingCopy copyOf({int roundIndex = 2, String memory = ''}) =>
      AgentStateWorkingCopy(
        roundIndex: roundIndex,
        lastRound: lastRound(memory: memory),
        categoryNames: const [],
      );

  String contentOf(Map<String, dynamic> message) => message['content'] as String;

  group('记忆阶段帧（仅 Lv.1）', () {
    test('主帧：说明本轮大纲已就位，并带上记忆阶段正文', () {
      final content = contentOf(directives.memoryDirective(
        first: true,
        workingCopy: copyOf(),
      ));
      expect(content, startsWith('[History entry · before the story]'));
      expect(content, contains('本轮大纲已在上方。'));
      expect(content, contains('【记忆阶段】'));
      expect(content, contains('op=append'));
      expect(content, contains('恰好一条'));
    });

    test('重试帧（本轮条目仍缺失）：指名历史栏还没有那一条', () {
      final content = contentOf(directives.memoryDirective(
        first: false,
        workingCopy: copyOf(),
      ));
      expect(content, startsWith('[History entry · still missing]'));
      expect(content, contains('历史栏仍没有本轮那一条。'));
    });

    test('重试帧（条目已落地、合并未落地）：只追合并', () {
      final copy = copyOf(roundIndex: 2, memory: '- 1 | 第一天 | 入门。');
      final applied = copy.applyEdits(AgentStateSection.memorySummary, [
        const AgentLineEdit(op: 'append', newLine: '- 2 | 第二天 | 初入宗门。'),
      ]);
      expect(applied.applied, isTrue, reason: applied.message);

      final content = contentOf(directives.memoryDirective(
        first: false,
        workingCopy: copy,
      ));
      expect(content, startsWith('[History entry · merge still missing]'));
      expect(content, contains('上面要求的合并还没完成。'));
    });

    test('合并未落地 → 追加合并指令行；已落地 → 不再要求', () {
      final memory = [
        for (var i = 1; i <= 10; i++) '- $i | 第$i天 | 事件$i。',
      ].join('\n');
      final plan = planMemoryMerge(
        memoryText: memory,
        tier: 5,
        newRoundIndex: 11,
      );
      expect(plan.hasAction, isTrue, reason: '前置：10 条未合并条目应触发 T=5 合并');

      final pending = contentOf(directives.memoryDirective(
        first: false,
        workingCopy: copyOf(roundIndex: 11, memory: memory),
        memoryMergePlan: plan,
      ));
      expect(pending, contains('[Memory merge · tools]'));
      expect(pending, contains('op=set'));

      final merged = '- 1 - 5 | 第1天 ~ 第5天 | 前五天。\n'
          '${[for (var i = 6; i <= 10; i++) '- $i | 第$i天 | 事件$i。'].join('\n')}';
      final appliedCopy = copyOf(roundIndex: 11, memory: merged);
      expect(isMemoryMergeApplied(merged, plan), isTrue, reason: '前置：区间已落地');
      final done = contentOf(directives.memoryDirective(
        first: false,
        workingCopy: appliedCopy,
        memoryMergePlan: plan,
      ));
      expect(done, isNot(contains('[Memory merge · tools]')));
    });

    test('无合并动作时 pendingMemoryMergeLines 为空', () {
      expect(
        directives.pendingMemoryMergeLines(
          workingCopy: copyOf(),
          memoryMergePlan: null,
        ),
        isEmpty,
      );
    });
  });

  group('维护 / 修复帧', () {
    test('Lv.1：只点名历史一对，且明确世界 / 角色不得改动', () {
      final content = contentOf(directives.stateDirective(
        problems: const ['memorySummary栏目本轮既未编辑也未声明无变化'],
        first: true,
        level: AgentModeLevel.lv1,
      ));
      expect(content, startsWith('[State-maintenance turn]'));
      expect(content, contains('narrchat_readHistory'));
      expect(content, contains('narrchat_editHistory'));
      expect(content, isNot(contains('narrchat_readWorldState')));
      expect(content, contains('**不要**改动世界状态 / 角色状态'));
      expect(content, contains('- memorySummary栏目本轮既未编辑也未声明无变化'));
    });

    test('Lv.1 修复帧：只修复清单内各项', () {
      final content = contentOf(directives.stateDirective(
        problems: const ['memorySummary栏目本轮既未编辑也未声明无变化'],
        first: false,
        level: AgentModeLevel.lv1,
      ));
      expect(content, startsWith('[State-maintenance turn · fix]'));
      expect(content, contains('只修复下列各项'));
    });

    test('Lv.2：点名三栏读取器与编辑器（按栏目顺序成串）', () {
      final content = contentOf(directives.stateDirective(
        problems: const [],
        first: true,
        level: AgentModeLevel.lv2,
      ));
      expect(
        content,
        contains(
          'narrchat_readWorldState / narrchat_readCharacterState / '
          'narrchat_readHistory',
        ),
      );
      expect(
        content,
        contains(
          'narrchat_editWorldState / narrchat_editCharacterState / '
          'narrchat_editHistory',
        ),
      );
      // 空清单只发指令头：不出现空的清单条目
      expect(content, isNot(contains('\n')));
    });

    test('清单按 记忆 → 角色 → 世界 → 其他 排序', () {
      final content = contentOf(directives.stateDirective(
        problems: const [
          'worldState-问题',
          '其他-问题',
          'characterState-问题',
          'memorySummary-问题',
        ],
        first: true,
        level: AgentModeLevel.lv2,
      ));
      final memory = content.indexOf('memorySummary-问题');
      final character = content.indexOf('characterState-问题');
      final world = content.indexOf('worldState-问题');
      final other = content.indexOf('其他-问题');
      expect(memory, greaterThan(0));
      expect(memory, lessThan(character));
      expect(character, lessThan(world));
      expect(world, lessThan(other));
    });

    test('清单一帧至多 ${AgentStageDirectives.maxStateProblems} 条', () {
      final problems = [
        for (var i = 0; i < 12; i++) 'worldState-问题$i',
      ];
      final content = contentOf(directives.stateDirective(
        problems: problems,
        first: true,
        level: AgentModeLevel.lv2,
      ));
      final items =
          content.split('\n').where((line) => line.startsWith('- ')).length;
      expect(items, AgentStageDirectives.maxStateProblems);
    });

    test('指令头单独成段（清单为空时没有尾随清单符）', () {
      final content = contentOf(directives.stateDirective(
        problems: const [],
        first: true,
        level: AgentModeLevel.lv2,
      ));
      expect(content.endsWith('- '), isFalse);
      expect(content.startsWith('[State-maintenance turn]'), isTrue);
    });
  });
}
