import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/mod.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/services/agent/state/agent_state_working_copy.dart';
import 'package:narrchat/services/memory_merge_planner.dart';
import 'package:narrchat/services/prompt_interface.dart';
import 'package:narrchat/services/prompt_v3_context.dart';

/// v3 **上下文侧**测试：本轮 user 消息的 8 个成分 + Agent 四份回合指令。
///
/// 文案真源是 `docs/prompt_v3_context.md`：成分顺序、区段 `---` 分隔、空成分
/// 整段删除、新建轮 / 修改轮同构（只差头部两处）、回合指令的补充句与待修清单。
/// system 侧（8 个模块）在 `test/prompt_v3_modules_test.dart`，
/// 接口层衔接在 `test/prompt_interface_test.dart`。
void main() {
  const book = Book(
    uuid: 'b1',
    title: '测试书',
    globalPrePrompt: '用户前置词',
    globalPostPrompt: '用户后置词',
    historyRounds: 2,
  );

  /// 生成基座 = 被重写轮（第 3 轮）的上一轮（第 2 轮）。
  const base = Round(
    id: 2,
    bookUuid: 'b1',
    roundIndex: 2,
    userInput: '上一轮输入',
    aiNarrative: '上一轮正文',
    worldState: '- 地点：青云宗',
    currentTime: '第二天 午时',
  );

  const opinion = '把这段写紧凑些，别拖。';

  const mods = ModsBundle(
    prePrompts: 'MOD 前置词',
    postPrompts: 'MOD 后置词',
  );

  PromptRequest newRoundRequestOf(
    PromptMode mode, {
    Book target = book,
    Round? last = base,
    ModsBundle? modsBundle,
    String userInput = '本轮输入',
  }) =>
      PromptRequest(
        book: target,
        mode: mode,
        lastRound: last,
        userInput: userInput,
        mods: modsBundle,
      );

  PromptRequest rewriteRequestOf(
    PromptMode mode, {
    String roundTime = '第三天 卯时',
    int roundIndex = 3,
    Book target = book,
    Round? last = base,
  }) =>
      PromptRequest(
        book: target,
        mode: mode,
        lastRound: last,
        userInput: opinion,
        rewrite: RewriteTarget(roundIndex: roundIndex, roundTime: roundTime),
      );

  group('本轮 user：成分顺序与区段分隔', () {
    test('8 个成分按序拼成一条消息，区段之间用 ---，成分之间空一行', () {
      final user = promptInterface.user(
        newRoundRequestOf(PromptMode.chat, modsBundle: mods),
      );

      // 1 头部 → 2 时间行
      expect(user, startsWith('你需要按照主人的要求，创作第 3 轮：'));
      expect(user, contains('- 上轮时间：第二天 午时'));
      // 3 前置词（用户 → Mod）
      final userPre = user.indexOf('用户前置词');
      final modPre = user.indexOf('MOD 前置词');
      expect(userPre, greaterThan(0));
      expect(userPre, lessThan(modPre), reason: 'Mod 前置词更贴近输入');
      // 4 主人输入（边界标记由程序给）
      final input = user.indexOf('【用户输入】');
      expect(modPre, lessThan(input));
      expect(user, contains('【用户输入】\n\n本轮输入\n\n【用户输入结束】'));
      // 5 后置词（Mod → 用户）
      final modPost = user.indexOf('MOD 后置词');
      final userPost = user.indexOf('用户后置词');
      expect(input, lessThan(modPost));
      expect(modPost, lessThan(userPost), reason: 'Mod 后置词在用户后置词之前');
      // 7 文风口径 → 8 本轮输出契约
      final priority = user.indexOf('撰写正文前须确认文风口径的优先顺序');
      final contract = user.indexOf('# 本轮输出契约：');
      expect(userPost, lessThan(priority));
      expect(priority, lessThan(contract));
      // 六段（含记忆合并时为七段）之间用 --- 分隔，且不出现连续空段。
      expect(user.split('\n\n---\n\n').length, 5, reason: '无合并时共 5 个区段');
      expect(user, isNot(contains('---\n\n---')));
    });

    test('文风口径的优先顺序在 user 侧逐字出现（恒在）', () {
      final user = promptInterface.user(newRoundRequestOf(PromptMode.chat));
      expect(
        user,
        contains('**本轮用户的指令 > 文笔参考范文 > 文笔要求 > 其他**'),
      );
      expect(user, contains('历史中 assistant 的文风与措辞不作为依据'));
    });

    test('空成分整段删除：首轮无时间、无前后置词时不留空段', () {
      final user = promptInterface.user(
        newRoundRequestOf(
          PromptMode.chat,
          target: const Book(title: '无词书'),
          last: null,
        ),
      );
      expect(user, startsWith('你需要按照主人的要求，创作第 1 轮：'));
      expect(user, isNot(contains('上轮时间')));
      expect(user, isNot(contains('用户前置词')));
      expect(user, isNot(contains('用户后置词')));
      expect(user, isNot(contains('---\n\n---')));
      expect(user.split('\n\n---\n\n').length, 3, reason: '头部 / 输入 / 口径+契约');
    });

    test('前置词区 = 用户前置词 → Mod 前置词；后置词区 = Mod → 用户', () {
      final user = promptInterface.user(
        newRoundRequestOf(PromptMode.chat, modsBundle: mods),
      );
      expect(user.indexOf('用户前置词'), lessThan(user.indexOf('MOD 前置词')));
      expect(user.indexOf('MOD 后置词'), lessThan(user.indexOf('用户后置词')));
    });
  });

  group('本轮输出契约（模式专属的本轮执行要求）', () {
    test('Chat：6 个区块一口气输出，记忆逐轮复述', () {
      final user = promptInterface.user(newRoundRequestOf(PromptMode.chat));
      final contract = user.substring(user.indexOf('# 本轮输出契约：'));
      expect(contract, contains('直接给出 6 个二级标题区块'));
      expect(contract, contains('`## 记忆总结` 须按「记忆条目格式」逐轮逐条目复述'));
      expect(contract, contains('不得复述指令、不得解释'));
    });

    test('Agent Lv.1：两步执行，第一步 5 个区块、记忆留到第二步', () {
      final user = promptInterface.user(newRoundRequestOf(PromptMode.agentLv1));
      final contract = user.substring(user.indexOf('# 本轮输出契约：'));
      expect(contract, contains('按两步执行'));
      expect(contract, contains('仅输出 5 个二级标题'));
      expect(contract, contains('第一步禁止输出 `## 记忆总结`'));
      expect(contract, contains('第二步由应用单独发起'));
      expect(contract, isNot(contains('直接给出 6 个二级标题区块')));
    });
  });

  group('修改轮（按意见重写某一轮）', () {
    test('头部两处不同：重写第 N 轮 + 此轮时间取被重写轮', () {
      final user = promptInterface.user(rewriteRequestOf(PromptMode.chat));
      expect(user, startsWith(PromptV3Context.rewriteHead(3)));
      expect(user, startsWith('上一轮输出未满足主人的要求，请重新撰写第 3 轮：'));
      expect(user, contains('- 此轮时间：第三天 卯时'));
      expect(user, contains('【用户输入】\n\n$opinion\n\n【用户输入结束】'));
      expect(user, isNot(contains('上轮时间')));
    });

    test('与新建轮逐字同构：归一化头部两处后完全相同', () {
      final normal = promptInterface.user(
        newRoundRequestOf(PromptMode.chat, userInput: opinion),
      );
      final rewritten = promptInterface.user(
        rewriteRequestOf(PromptMode.chat, roundTime: base.currentTime),
      );
      final normalized = rewritten
          .replaceFirst(
            PromptV3Context.rewriteHead(3),
            PromptV3Context.newRoundHead(3),
          )
          .replaceFirst('- 此轮时间：', '- 上轮时间：');
      expect(normalized, normal);
      expect(rewritten, isNot(normal));
    });

    test('此轮时间为空 → 时间行整条不注入', () {
      final user = promptInterface.user(
        rewriteRequestOf(PromptMode.chat, roundTime: '  '),
      );
      expect(user, startsWith('上一轮输出未满足主人的要求'));
      expect(user, isNot(contains('此轮时间')));
    });

    test('本轮契约与新建轮一致（两模式各比一次）', () {
      for (final mode in PromptMode.values) {
        final rewritten = promptInterface.user(rewriteRequestOf(mode));
        final normal = promptInterface.user(newRoundRequestOf(mode));
        String tail(String text) =>
            text.substring(text.indexOf('# 本轮输出契约：'));
        expect(tail(rewritten), tail(normal), reason: mode.name);
      }
    });
  });

  group('Chat 的记忆合并指令', () {
    MemoryMergePlan planOf() => planMemoryMerge(
          memoryText: [
            for (var i = 1; i <= 10; i++) '- $i | 第$i天 | 事件$i。',
          ].join('\n'),
          tier: 5,
          newRoundIndex: 11,
        );

    test('位置在「后置词」与「文风口径」之间，文案与区间行齐全', () {
      const tier5 = Book(title: '档 5', memorySummaryRounds: 5);
      final last = Round(
        id: 10,
        bookUuid: 'b1',
        roundIndex: 10,
        userInput: '第10轮输入',
        memorySummary: [
          for (var i = 1; i <= 10; i++) '- $i | 第$i天 | 事件$i。',
        ].join('\n'),
        currentTime: '第十天',
      );
      final user = promptInterface.user(
        newRoundRequestOf(
          PromptMode.chat,
          target: tier5,
          last: last,
          modsBundle: mods,
        ),
      );
      final mergeAt = user.indexOf('【记忆合并要求】');
      expect(mergeAt, greaterThan(user.indexOf('用户后置词')));
      expect(mergeAt, lessThan(user.indexOf('撰写正文前须确认文风口径')));
      expect(user, contains('第 1~5 轮（5 条）合并为一行'));
      expect(user, contains('本轮【用户输入】明确要求其他合并方式'));
      // 有合并动作的 Chat 消息多一个区段。
      expect(user.split('\n\n---\n\n').length, 6);
    });

    test('Agent 的合并走维护回合，不进入用户消息', () {
      final user = promptInterface.user(
        PromptRequest(
          book: const Book(title: '档 5', memorySummaryRounds: 5),
          mode: PromptMode.agentLv1,
          lastRound: Round(
            id: 10,
            bookUuid: 'b1',
            roundIndex: 10,
            userInput: '第10轮输入',
            memorySummary: [
              for (var i = 1; i <= 10; i++) '- $i | 第$i天 | 事件$i。',
            ].join('\n'),
            currentTime: '第十天',
          ),
          userInput: '继续',
        ),
      );
      expect(user, isNot(contains('【记忆合并要求】')));
      // 但合并要求出现在维护回合指令里。
      final state = promptInterface.stageState(
        AgentStageRequest(
          workingCopy: AgentStateWorkingCopy(
            roundIndex: 11,
            lastRound: null,
            categoryNames: const [],
          ),
          memoryMergePlan: planOf(),
          first: true,
        ),
      );
      expect(state, contains('第 1~5 轮（5 条）'));
    });
  });

  group('Agent 回合指令', () {
    test('调研回合：读史一次 + 文本通道零输出', () {
      final prepare = promptInterface.stagePrepare(const AgentStageRequest());
      expect(prepare, startsWith('【调研回合】'));
      expect(prepare, contains('先调用 `narrchat_readHistory` **一次**'));
      expect(prepare, contains('不得在文本通道输出任何内容'));
      expect(prepare, contains('应用将立即发起正文回合'));
      expect(prepare, isNot(contains('记忆回合')));
    });

    test('正文回合：5 区块、记忆留到第二步', () {
      final story = promptInterface.stageStory(const AgentStageRequest());
      expect(story, startsWith('【正文回合】'));
      expect(story, contains('仅输出 5 个二级标题'));
      expect(story, contains('`## 记忆总结`'));
      expect(story, contains('禁止调用历史编辑器'));
      expect(story, contains('禁止复述历史、工具结果与本指令'));
    });

    test('维护回合（主回合）：只维护记忆总结 + append 恰好一条', () {
      final state = promptInterface.stageState(const AgentStageRequest());
      expect(state, startsWith('[State-maintenance turn]'));
      expect(state, contains('**仅维护记忆总结**'));
      expect(state, contains('调用一次 `narrchat_editHistory` 的 `op=append`'));
      expect(state, contains('追加**恰好一条**本轮记忆条目'));
      expect(state, contains('历史栏不接受 `op=noChange`'));
      expect(state, isNot(contains('narrchat_readWorldState')));
    });

    test('维护回合（修复回合）：只按清单修，锚点从已有结果复制', () {
      final fix = promptInterface.stageState(
        const AgentStageRequest(
          problems: ['memorySummary栏目本轮既未编辑也未声明无变化'],
          first: false,
        ),
      );
      expect(fix, startsWith('[State-maintenance turn] 仅修复下列各项'));
      expect(fix, contains('锚点须从对话中已有的历史结果块'));
      expect(fix, contains('- memorySummary栏目本轮既未编辑也未声明无变化'));
    });

    test('历史栏已有本轮条目 → 明确提示不要重复追加', () {
      final copy = AgentStateWorkingCopy(
        roundIndex: 2,
        lastRound: base.copyWith(memorySummary: '- 2 | 第二天 午时 | 已落地的条目'),
        categoryNames: const [],
      );
      final state = promptInterface.stageState(
        AgentStageRequest(workingCopy: copy, first: true),
      );
      expect(state, contains('历史栏已包含本轮条目'));
      expect(state, contains('**不得重复追加**'));
    });

    test('待修清单按 历史 > 角色 > 世界 > 其他 排序，且至多 8 条', () {
      final problems = [
        for (var i = 0; i < 5; i++) 'worldState缺口$i',
        for (var i = 0; i < 5; i++) 'characterState缺口$i',
        for (var i = 0; i < 3; i++) 'memorySummary缺口$i',
      ];
      final state = promptInterface.stageState(
        AgentStageRequest(problems: problems, first: false),
      );
      final lines = state
          .split('\n')
          .where((line) => line.startsWith('- '))
          .toList();
      expect(lines.length, 8, reason: '清单上限 8 条');
      expect(lines.first, contains('memorySummary缺口0'), reason: '历史项排最前');
      expect(lines[2], contains('memorySummary缺口2'));
      expect(lines[3], contains('characterState缺口0'), reason: '其次角色');
      expect(lines.last, contains('characterState缺口4'), reason: '截断后只剩角色项');
    });
  });
}
