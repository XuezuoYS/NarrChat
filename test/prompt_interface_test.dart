import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/models/agent_mode_level.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/mod.dart';
import 'package:narrchat/models/role_category.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/services/agent/agent_mode_profile.dart';
import 'package:narrchat/services/agent/fetch_page_tool.dart';
import 'package:narrchat/services/agent/narr_agent_tool.dart';
import 'package:narrchat/services/agent/state/agent_state_working_copy.dart';
import 'package:narrchat/services/agent/state/state_tools.dart';
import 'package:narrchat/services/agent/web_search_tool.dart';
import 'package:narrchat/services/html_search_service.dart';
import 'package:narrchat/services/prompt_interface.dart';
import 'package:narrchat/services/prompt_v2_build.dart';

/// `prompt_interface` 契约测试（当前唯一实现 = v2）。
///
/// 覆盖：总模板区域 / `---` 分隔 / 空块即删 / 多行保留 / 模式契约差异 / Mod 注入
/// 与顺序 / 记忆合并注入 / 工具路由与替身 / 阶段帧文案 / 请求对象。
/// 提示词文案本身的断言集中在 `test/prompt_v2_*`（v2 文案真源）与本文件；
/// v1 提示词代码已删除，不再有回退路径断言。
void main() {
  const book = Book(
    uuid: 'b1',
    title: '测试书',
    category: '玄幻',
    baseSetting: '北域修仙世界，宗门林立。',
    writingRequirements: '本书文笔要求：多用对话推进。',
    writingStyle: '用户补充：多用短句。',
    globalPrePrompt: '用户前置词：保持悬念。',
    globalPostPrompt: '用户后置词：留下钩子。',
    historyRounds: 2,
    roleHierarchy: '主角 > 女主角 > NPC',
  );

  /// 只有书名、其余全空的书籍：验证「无内容即删块」。
  const minimalBook = Book(title: '空书');

  const lastRound = Round(
    id: 1,
    bookUuid: 'b1',
    roundIndex: 1,
    userInput: '我踏入青云宗。',
    aiNarrative: '山门巍峨，云雾缭绕。',
    worldState: '- 地点：青云宗\n- 天气：晴',
    characterState: '## 女主角\n### 苏清月\n- 心情：平静',
    memorySummary: '- 1 | 第一天 | 主角初入宗门。',
    currentTime: '第三天 午时',
  );

  const mods = ModsBundle(
    systemPrompts: 'MOD 系统提示词',
    prePrompts: 'MOD 前置词',
    postPrompts: 'MOD 后置词',
    worldBooks: 'MOD 世界书',
  );

  PromptRequest requestOf(
    PromptMode mode, {
    Book target = book,
    Round? last = lastRound,
    ModsBundle? modsBundle,
    String worldBook = '青云宗是北域第一大派。',
  }) =>
      PromptRequest(
        book: target,
        mode: mode,
        lastRound: last,
        userInput: '我走向主殿，想要拜见掌门。',
        worldBookEntries: worldBook,
        mods: modsBundle,
      );

  AgentStateWorkingCopy copyOf() => AgentStateWorkingCopy(
        roundIndex: lastRound.roundIndex + 1,
        lastRound: lastRound,
        categoryNames: const [],
      );

  /// 工具的可比较指纹（名字 + 描述 + 参数 schema）。
  List<String> fingerprint(List<NarrAgentTool> tools) =>
      [for (final t in tools) '${t.name}|${t.description}|${t.parameters}'];

  group('绑定与版本', () {
    test('当前唯一实现是 v2（PromptV2 聚合 = PromptV2Build 文本 + 工具清单）', () {
      expect(promptInterface, isA<PromptV2Build>());
      expect(promptInterface, isA<PromptInterface>());
    });
  });

  group('v2 · system（总模板）', () {
    test('固定行 + 一级标题区域 + --- 分隔 + 模式标记', () {
      final system = promptInterface.system(requestOf(PromptMode.chat));
      expect(system, startsWith('你是一名喜爱创作，涉猎文学、艺术的作者'));
      expect(system, contains('你的位置：你在一个名为“narrchat”的沙箱笼子里。'));
      expect(system, contains('- 当前请求协议：Chat。'));
      expect(system, contains('- 当前书籍名：测试书'));
      expect(system, contains('- 文笔要求：本书文笔要求：多用对话推进。'));
      for (final section in const [
        '# 总协议：',
        '# 书籍设定和要求：',
        '# 世界书：',
        '# 角色状态栏协议：',
        '# 角色状态完整性要求：',
        '# 文笔参考范文：',
        '# 执行惩罚和奖励：',
      ]) {
        expect(system, contains(section), reason: section);
      }
      expect(system, contains('\n\n---\n\n'), reason: '区域之间用 --- 分隔');
      expect(system, contains('角色层级排序规则：`主角 > 女主角 > NPC`'));
    });

    test('模式契约：Chat 6 区块 / Lv.1 5 区块 / Lv.2 3 小节，工具契约只进 Agent', () {
      final chat = promptInterface.system(requestOf(PromptMode.chat));
      final lv1 = promptInterface.system(requestOf(PromptMode.agentLv1));
      final lv2 = promptInterface.system(requestOf(PromptMode.agentLv2));

      expect(chat, contains('6 个二级标题'));
      expect(lv1, contains('5 个二级标题'));
      expect(lv2, contains('3 个二级标题'));

      expect(chat, isNot(contains('【状态工具契约】')));
      expect(lv1, contains('【状态工具契约】'));
      expect(lv2, contains('【状态工具契约】'));

      expect(lv1, contains('当前请求协议：Agent。'), reason: 'Agent 档位不写等级');
      expect(lv2, contains('当前请求协议：Agent。'));
      expect(lv1, isNot(contains('6 个二级标题')));
    });

    test('空块即删：只有书名时不留空的 `#` 板块', () {
      final system = promptInterface.system(
        requestOf(
          PromptMode.chat,
          target: minimalBook,
          last: null,
          worldBook: '',
        ),
      );
      expect(system, contains('# 总协议：'));
      expect(system, contains('# 角色状态完整性要求：'));
      expect(system, contains('# 执行惩罚和奖励：'));
      expect(system, isNot(contains('# 书籍设定和要求：')));
      expect(system, isNot(contains('# 世界书：')));
      expect(system, isNot(contains('# 角色状态栏协议：')));
      expect(system, isNot(contains('# 文笔参考范文：')));
      expect(system, isNot(contains('（无）')));
      expect(system, isNot(contains('（未设置）')));
      expect(system, isNot(contains('- 文笔要求：')));
    });

    test('多行内容保留换行（Mod / 书籍设定 / 世界书 / 文笔参考 / 类别格式）', () {
      const multiBook = Book(
        title: '多行书',
        category: '玄幻',
        baseSetting: '第一行设定\n第二行设定',
        writingRequirements: '要求一\n要求二',
        writingStyle: '范例第一行\n范例第二行',
        roleHierarchy: '主角 > NPC',
        roleCategories: [
          RoleCategory(name: '主角', format: '姓名：\n年龄：\n性别：'),
        ],
      );
      const multiMods = ModsBundle(
        systemPrompts: 'MOD 第一行\nMOD 第二行',
        worldBooks: 'MOD 世界书第一行\nMOD 世界书第二行',
        prePrompts: 'MOD 前置第一行\nMOD 前置第二行',
        postPrompts: 'MOD 后置第一行\nMOD 后置第二行',
      );
      const worldBook = '世界书第一行\n世界书第二行';

      final system = promptInterface.system(const PromptRequest(
        book: multiBook,
        mode: PromptMode.chat,
        worldBookEntries: worldBook,
        mods: multiMods,
      ));
      for (final block in const [
        '第一行设定\n第二行设定',
        '要求一\n要求二',
        '范例第一行\n范例第二行',
        'MOD 第一行\nMOD 第二行',
        '世界书第一行\n世界书第二行',
        'MOD 世界书第一行\nMOD 世界书第二行',
        '姓名：\n年龄：\n性别：',
      ]) {
        expect(system, contains(block), reason: '换行被折叠：$block');
      }

      final user = promptInterface.user(const PromptRequest(
        book: multiBook,
        mode: PromptMode.chat,
        userInput: '继续',
        mods: multiMods,
      ));
      expect(user, contains('MOD 前置第一行\nMOD 前置第二行'));
      expect(user, contains('MOD 后置第一行\nMOD 后置第二行'));
      expect(user, contains('【主人的输入】\n\n继续\n\n【主人的输入stop】'));
    });

    test('Mod：system 注入在总协议之前（抬升），世界书并入世界书章节', () {
      final system = promptInterface.system(
        requestOf(PromptMode.chat, modsBundle: mods),
      );
      final modAt = system.indexOf('MOD 系统提示词');
      final contractAt = system.indexOf('# 总协议：');
      expect(modAt, greaterThan(0));
      expect(modAt, lessThan(contractAt), reason: 'Mod 抬升到总协议之前');
      expect(system, contains('MOD 世界书'));
      // 世界书章节里既有书籍世界书也有 Mod 世界书
      final worldAt = system.indexOf('# 世界书：');
      expect(system.indexOf('青云宗是北域第一大派。'), greaterThan(worldAt));
    });

    test('记忆合并策略随本书档位（0 / 5）', () {
      final off = promptInterface.system(requestOf(PromptMode.chat));
      expect(off, contains('档位 0（关闭）'));

      const tier5 = Book(title: '档 5', memorySummaryRounds: 5);
      final on = promptInterface.system(
        requestOf(PromptMode.chat, target: tier5, last: null),
      );
      expect(on, contains('档位 5'));
      expect(on, contains('2 × 5'));
    });
  });

  group('v2 · user（新建轮注入）', () {
    test('轮次 / 上轮时间 / 主人的输入 / 总协议2 / 模式专属指令', () {
      final user = promptInterface.user(requestOf(PromptMode.chat));
      expect(user, startsWith('你需要按照主人的要求，创作第 2 轮：'));
      expect(user, contains('- 上轮时间：第三天 午时'));
      expect(user, contains('【主人的输入】\n\n我走向主殿，想要拜见掌门。\n\n【主人的输入stop】'));
      expect(user, contains('# 总协议2'));
      expect(user, contains('格式已经约好了，现在就动笔'));

      final lv2 = promptInterface.user(requestOf(PromptMode.agentLv2));
      expect(lv2, contains('先把三栏各读一次'));
    });

    test('前置词 / 后置词：用户 + Mod 都在，顺序正确', () {
      final user = promptInterface.user(
        requestOf(PromptMode.chat, modsBundle: mods),
      );
      final userPre = user.indexOf('用户前置词：保持悬念。');
      final modPre = user.indexOf('MOD 前置词');
      final input = user.indexOf('【主人的输入】');
      final modPost = user.indexOf('MOD 后置词');
      final userPost = user.indexOf('用户后置词：留下钩子。');
      expect(userPre, greaterThan(0));
      expect(userPre, lessThan(modPre));
      expect(modPre, lessThan(input), reason: 'Mod 前置词更靠近主人的输入');
      expect(input, lessThan(modPost));
      expect(modPost, lessThan(userPost), reason: 'Mod 后置词在用户后置词之前');
    });

    test('首轮：无上轮时间 → 该条整条不注入；空前置 / 后置词 → 整区不注入', () {
      final user = promptInterface.user(
        requestOf(PromptMode.chat, target: minimalBook, last: null),
      );
      expect(user, startsWith('你需要按照主人的要求，创作第 1 轮：'));
      expect(user, isNot(contains('上轮时间')));
      expect(user, isNot(contains('用户前置词')));
      expect(user, isNot(contains('用户后置词')));
      // 区域分隔符不因整区删除而出现连续空段
      expect(user, isNot(contains('---\n\n---')));
    });

    test('Chat：本轮记忆合并指令注入用户消息（Agent 走阶段帧，不在这里）', () {
      final memory = [
        for (var i = 1; i <= 10; i++) '- $i | 第$i天 | 事件$i。',
      ].join('\n');
      const tier5 = Book(title: '档 5', memorySummaryRounds: 5);
      final mergeRound = Round(
        id: 10,
        bookUuid: 'b1',
        roundIndex: 10,
        userInput: '上一轮输入',
        aiNarrative: '上一轮正文',
        memorySummary: memory,
        currentTime: '第十天',
      );

      final user = promptInterface.user(PromptRequest(
        book: tier5,
        mode: PromptMode.chat,
        lastRound: mergeRound,
        userInput: '继续',
      ));
      expect(user, contains('创作第 11 轮：'));
      expect(user, contains('【本轮记忆合并】'));
      expect(user, contains('第 1~5 轮'));

      // Agent 档位的合并要求走阶段帧指令，不在用户消息里
      final agentUser = promptInterface.user(PromptRequest(
        book: tier5,
        mode: PromptMode.agentLv2,
        lastRound: mergeRound,
        userInput: '继续',
      ));
      expect(agentUser, isNot(contains('【本轮记忆合并】')));
    });
  });

  group('v2 · 工具集与阶段帧', () {
    test('工具路由与 v1 一致（Lv.1 两件 / Lv.2 六件 / Chat 联网两件）', () {
      final lv1 = promptInterface.tools(
        AgentToolsRequest(level: AgentModeLevel.lv1, workingCopy: copyOf()),
      );
      expect([for (final t in lv1) t.name], [
        kReadHistoryToolName,
        kEditHistoryToolName,
      ]);

      final lv2 = promptInterface.tools(
        AgentToolsRequest(level: AgentModeLevel.lv2, workingCopy: copyOf()),
      );
      expect([for (final t in lv2) t.name], kStateToolNames);
      expect(
        fingerprint(lv2),
        fingerprint(
          buildStateTools(copyOf(), sections: AgentModeProfile.lv2.toolSections),
        ),
      );

      final chatSearch = promptInterface.tools(
        AgentToolsRequest(
          level: AgentModeLevel.off,
          useSearch: true,
          search: HtmlSearchService(),
        ),
      );
      expect([for (final t in chatSearch) t.name], [
        'narrchat_webSearch',
        'narrchat_webFetchPage',
      ]);
    });

    test('联网工具：替身优先 / 缺抓取服务报错（不静默回落真实服务）', () {
      final web = WebSearchTool();
      final fetch = FetchPageTool();
      final tools = promptInterface.tools(AgentToolsRequest(
        level: AgentModeLevel.lv2,
        workingCopy: copyOf(),
        useSearch: true,
        webSearch: web,
        fetchPage: fetch,
      ));
      expect(tools[tools.length - 2], same(web));
      expect(tools.last, same(fetch));
      expect(
        () => promptInterface.tools(
          const AgentToolsRequest(level: AgentModeLevel.off, useSearch: true),
        ),
        throwsArgumentError,
      );
    });

    test('阶段帧指令为 v2 文案（准备 / 记忆 / 正文 / 维护）', () {
      const lv1 = AgentStageRequest(level: AgentModeLevel.lv1);
      expect(promptInterface.stagePrepare(lv1), startsWith('【准备回合】'));
      expect(promptInterface.stagePrepare(lv1), contains('大纲'));
      expect(promptInterface.stageStory(lv1), startsWith('【正文回合】'));

      final copy = copyOf();
      final memory = promptInterface.stageMemory(AgentStageRequest(
        level: AgentModeLevel.lv1,
        workingCopy: copy,
        first: true,
      ));
      expect(memory, contains('【记忆回合】'));
      expect(memory, contains('op=append'));

      final lv1State = promptInterface.stageState(const AgentStageRequest(
        level: AgentModeLevel.lv1,
        problems: ['memorySummary栏目本轮既未编辑也未声明无变化'],
      ));
      expect(lv1State, startsWith('[State-maintenance turn]'));
      expect(lv1State, isNot(contains('narrchat_readWorldState')));

      final lv2State = promptInterface.stageState(const AgentStageRequest(
        level: AgentModeLevel.lv2,
        problems: ['worldState栏目本轮未更新'],
        first: false,
      ));
      expect(lv2State, contains('只修复下面列出的各项'));
      expect(lv2State, contains('- worldState栏目本轮未更新'));
    });

    test('记忆帧缺工作副本 → 显式报错', () {
      expect(
        () => promptInterface.stageMemory(
          const AgentStageRequest(level: AgentModeLevel.lv1),
        ),
        throwsArgumentError,
      );
    });
  });

  test('PromptRequest.mode 覆盖三种模式，且不再携带格式规格对象', () {
    for (final mode in PromptMode.values) {
      final request = requestOf(mode);
      expect(request.mode, same(mode));
      expect(requestOf(mode).mode, mode);
    }
  });
}
