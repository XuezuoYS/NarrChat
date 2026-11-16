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
import 'package:narrchat/services/agent/web_tool_names.dart';
import 'package:narrchat/services/html_search_service.dart';
import 'package:narrchat/services/prompt_interface.dart';
import 'package:narrchat/services/prompt_v3_sections.dart';

/// `prompt_interface` 契约测试（当前唯一实现 = v3）。
///
/// 覆盖：绑定 / 模块顺序与空行 / 空块即删 / 多行保留 / 文风口径四处落点 /
/// 五个 system Mod 注入位与两个 user 词位 / 工具路由与 `toolNames` 一致性 /
/// `user()` 与 `stage*()` 的衔接 / 请求对象。
///
/// 逐模块正文在 `test/prompt_v3_modules_test.dart`，上下文成分与回合指令在
/// `test/prompt_v3_context_test.dart`，这里只跨模块断言「谁在谁前 / 谁不出现」。
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
    prePrompts: 'MOD 前置词',
    postPrompts: 'MOD 后置词',
    mustPrompts: 'MOD 最高优先约束',
    mustSegments: ['MOD 最高优先约束'],
    systemPrompts: 'MOD 通用约束',
    settingPrompts: 'MOD 设定',
    worldBooks: 'MOD 世界书',
    writingStylePrompts: 'MOD 文笔与参考段落',
  );

  PromptRequest requestOf(
    PromptMode mode, {
    Book target = book,
    Round? last = lastRound,
    ModsBundle? modsBundle,
    String worldBook = '青云宗是北域第一大派。',
    List<String> toolNames = const [],
  }) =>
      PromptRequest(
        book: target,
        mode: mode,
        lastRound: last,
        userInput: '我走向主殿，想要拜见掌门。',
        worldBookEntries: worldBook,
        mods: modsBundle,
        toolNames: toolNames,
      );

  AgentStateWorkingCopy copyOf() => AgentStateWorkingCopy(
        roundIndex: lastRound.roundIndex + 1,
        lastRound: lastRound,
        categoryNames: const [],
      );

  /// 工具的可比较指纹（名字 + 描述 + 参数 schema）。
  List<String> fingerprint(List<NarrAgentTool> tools) =>
      [for (final t in tools) '${t.name}|${t.description}|${t.parameters}'];

  group('绑定', () {
    test('当前唯一实现是 v3（PromptV3 聚合 + 可当 PromptInterface 用）', () {
      expect(promptInterface, isA<PromptV3>());
      expect(promptInterface, isA<PromptInterface>());
    });
  });

  group('v3 · system（8 模块拼合）', () {
    test('开篇是人设段、无 --- 分隔、模块之间只空一行', () {
      final system = promptInterface.system(requestOf(PromptMode.chat));
      expect(system, startsWith('你是一名喜爱创作，涉猎文学、艺术的作者'));
      expect(system, isNot(contains('---')), reason: 'system 侧不再画分隔线');
      expect(system, contains('\n\n'));
      // 每个模块的正文之间恰好一个空行：拼合结果 = 各模块 text 用一个空行连接。
      final sections = promptInterface.systemSections(
        requestOf(PromptMode.chat),
      );
      expect(
        system,
        sections.map((section) => section.text).join('\n\n'),
      );
    });

    test('结构标题只用一级 #；## 只出现在模型输出格式里', () {
      final system = promptInterface.system(requestOf(PromptMode.chat));
      // Chat 输出契约里的 `##` 标题链（模型输出格式）在，且不属于结构标题。
      expect(system, contains('`## 剧情演绎` → `## 推荐行动`'));
      // must / mustReverse 不带标题。
      expect(system, isNot(contains('# 必须遵循')));
      expect(system, isNot(contains('# 人设')));
    });

    test('空块即删：没有内容时不留孤立标题与占位', () {
      final system = promptInterface.system(
        requestOf(
          PromptMode.chat,
          target: minimalBook,
          last: null,
          worldBook: '',
        ),
      );
      for (final absent in const [
        '# 书籍设定和要求：',
        '# 世界书：',
        '# 角色状态栏内容：',
        '# 文笔参考范文：',
        '# 文笔要求与参考段落：',
        '# 通用约束：',
        '# 简要工具指南：',
      ]) {
        expect(system, isNot(contains(absent)), reason: absent);
      }
      expect(system, isNot(contains('（无）')));
      expect(system, isNot(contains('（未设置）')));
      // 必备模块照常在。
      for (final present in const [
        '# 当前请求协议：',
        '# 通用输出契约：',
        '# 输出区块契约：',
        '# 文风口径：',
      ]) {
        expect(system, contains(present), reason: present);
      }
    });

    test('模式差异：Chat 6 区块 / Agent 5 区块；工具契约与工具指南只跟注册走', () {
      final chat = promptInterface.system(
        requestOf(
          PromptMode.chat,
          toolNames: const ['narrchat_webSearch', 'narrchat_webFetchPage'],
        ),
      );
      final agent = promptInterface.system(
        requestOf(
          PromptMode.agentLv1,
          toolNames: const [
            'narrchat_readHistory',
            'narrchat_editHistory',
            'narrchat_webSearch',
            'narrchat_webFetchPage',
          ],
        ),
      );

      expect(chat, contains('- 当前请求协议：Chat。'));
      expect(agent, contains('- 当前请求协议：Agent。'));
      expect(chat, isNot(contains('# 状态工具契约：')));
      expect(agent, contains('# 状态工具契约：'));
      expect(agent, contains('narrchat_readHistory'));

      // 工具指南只按本轮注册的工具现生成：Chat 只有联网两条。
      expect(chat, isNot(contains('- `narrchat_readHistory`：')));
      expect(chat, contains('- `narrchat_webSearch`：'));
      expect(agent, contains('- `narrchat_editHistory`：'));
    });

    test('没有工具时指南整块消失（连标题）', () {
      final system = promptInterface.system(requestOf(PromptMode.chat));
      expect(system, isNot(contains('# 简要工具指南：')));
    });

    test('多行内容保留换行（设定 / 范文 / Mod 文案 / 世界书 / 类别格式）', () {
      const multiBook = Book(
        title: '多行书',
        baseSetting: '第一行设定\n第二行设定',
        writingRequirements: '要求一\n要求二',
        writingStyle: '范例第一行\n范例第二行',
        roleHierarchy: '主角 > NPC',
        roleCategories: [
          RoleCategory(name: '主角', format: '姓名：\n年龄：\n性别：'),
        ],
      );
      const multiMods = ModsBundle(
        mustPrompts: 'MOD 最高优先约束第一行\nMOD 最高优先约束第二行',
        mustSegments: ['MOD 最高优先约束第一行\nMOD 最高优先约束第二行'],
        systemPrompts: 'MOD 通用约束第一行\nMOD 通用约束第二行',
        settingPrompts: 'MOD 设定第一行\nMOD 设定第二行',
        writingStylePrompts: 'MOD 文笔第一行\nMOD 文笔第二行',
        worldBooks: 'MOD 世界书第一行\nMOD 世界书第二行',
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
        'MOD 最高优先约束第一行\nMOD 最高优先约束第二行',
        'MOD 通用约束第一行\nMOD 通用约束第二行',
        'MOD 设定第一行\nMOD 设定第二行',
        'MOD 文笔第一行\nMOD 文笔第二行',
        '世界书第一行\n世界书第二行',
        'MOD 世界书第一行\nMOD 世界书第二行',
        '姓名：\n年龄：\n性别：',
      ]) {
        expect(system, contains(block), reason: '换行被折叠：$block');
      }
    });
  });

  group('v3 · 文风口径的四处落点', () {
    test('标题标记 / 范文导语 / 收口句 / user 那句，且 Mod 文笔只做补充', () {
      final system = promptInterface.system(
        requestOf(PromptMode.chat, modsBundle: mods),
      );
      final user = promptInterface.user(
        requestOf(PromptMode.chat, modsBundle: mods),
      );

      // ① 文笔要求标题上的冲突标记。
      expect(system, contains(PromptV3Sections.writingRequirementsTitle));
      // ② 范文块导语（没有范文时随整块删，这一份有范文）。
      expect(system, contains(PromptV3Sections.styleReferenceLead));
      // ③ accordEnding 的收口句，排在工具指南之后。
      final closing = system.indexOf(PromptV3Sections.styleToneClosing);
      expect(closing, greaterThan(system.indexOf('# 文笔参考范文：')));
      // ④ user 消息里那句（排在两个 Mod 词位之后）。
      final priority = user.indexOf('撰写正文前须确认文风口径的优先顺序');
      expect(priority, greaterThan(user.indexOf('MOD 后置词')));
      expect(priority, lessThan(user.indexOf('# 本轮输出契约：')));
      // system 侧不再另设「文本口径」固定条目。
      expect(system, isNot(contains('文本口径')));

      // 「Mod 文笔」排在书范文之前：Mod 只做补充、不压书。
      final modWriting = system.indexOf('# 文笔要求与参考段落：');
      final reference = system.indexOf('# 文笔参考范文：');
      expect(modWriting, greaterThan(0));
      expect(modWriting, lessThan(reference));
    });
  });

  group('v3 · Mod 注入位', () {
    test('五个 system 注入位各就各位，除通用约束外不标 Mod 字样', () {
      final system = promptInterface.system(
        requestOf(PromptMode.chat, modsBundle: mods),
      );
      final mustAt = system.indexOf('MOD 最高优先约束');
      final extraAt = system.indexOf('# 通用约束：');
      final settingAt = system.indexOf('MOD 设定');
      final worldAt = system.indexOf('MOD 世界书');
      final writingAt = system.indexOf('MOD 文笔与参考段落');
      for (final at in [mustAt, extraAt, settingAt, worldAt, writingAt]) {
        expect(at, greaterThan(0));
      }
      // 最高优先约束在最前（must），通用约束在 accord 之后，设定/世界书在中段，文笔在范文之前。
      final accordAt = system.indexOf('# 当前请求协议：');
      expect(mustAt, lessThan(accordAt), reason: '最高优先约束在协议之前');
      expect(extraAt, greaterThan(accordAt), reason: '通用约束在协议之后');
      expect(settingAt, greaterThan(extraAt));
      expect(writingAt, greaterThan(worldAt));
      // Mod 内容不单独起标题、不出现「Mod」字样。
      expect(system, isNot(contains('MOD 最高优先约束：')));
      expect(system, isNot(contains('Mod')));
      expect(system, isNot(contains('mod')));
      // 最高优先约束会被逆序复述一次：system 里出现两次。
      expect('MOD 最高优先约束'.allMatches(system).length, 2);
    });

    test('前置 / 后置词进 user 消息（不进 system）', () {
      final system = promptInterface.system(
        requestOf(PromptMode.chat, modsBundle: mods),
      );
      final user = promptInterface.user(
        requestOf(PromptMode.chat, modsBundle: mods),
      );
      expect(system, isNot(contains('MOD 前置词')));
      expect(system, isNot(contains('MOD 后置词')));
      expect(user, contains('MOD 前置词'));
      expect(user, contains('MOD 后置词'));
    });
  });

  group('v3 · 工具集与 toolNames', () {
    test('工具路由：Lv.1 历史两件 + Chat 联网两件；六工具框架仍可组装', () {
      final lv1 = promptInterface.tools(
        AgentToolsRequest(level: AgentModeLevel.lv1, workingCopy: copyOf()),
      );
      expect([for (final t in lv1) t.name], [
        kReadHistoryToolName,
        kEditHistoryToolName,
      ]);
      expect(
        fingerprint(lv1),
        fingerprint(
          buildStateTools(copyOf(), sections: AgentModeProfile.lv1.toolSections),
        ),
      );

      final framework = buildStateTools(
        copyOf(),
        sections: AgentStateSection.values,
      );
      expect([for (final t in framework) t.name], kStateToolNames);

      final chatSearch = promptInterface.tools(
        AgentToolsRequest(
          level: AgentModeLevel.off,
          useSearch: true,
          search: HtmlSearchService(),
        ),
      );
      expect([for (final t in chatSearch) t.name], [
        kWebSearchToolName,
        kWebFetchPageToolName,
      ]);
    });

    test('联网工具：替身优先 / 缺抓取服务报错（不静默回落真实服务）', () {
      final web = WebSearchTool();
      final fetch = FetchPageTool();
      final tools = promptInterface.tools(AgentToolsRequest(
        level: AgentModeLevel.lv1,
        workingCopy: copyOf(),
        useSearch: true,
        webSearch: web,
        fetchPage: fetch,
      ));
      expect([for (final t in tools) t.name], [
        kReadHistoryToolName,
        kEditHistoryToolName,
        kWebSearchToolName,
        kWebFetchPageToolName,
      ]);
      expect(tools[tools.length - 2], same(web));
      expect(tools.last, same(fetch));
      expect(
        () => promptInterface.tools(
          const AgentToolsRequest(level: AgentModeLevel.off, useSearch: true),
        ),
        throwsArgumentError,
      );
    });

    test('promptToolNames 与同一轮 tools() 的名字逐一相等（四个组合）', () {
      for (final level in AgentModeLevel.values) {
        for (final useSearch in [false, true]) {
          final names = promptToolNames(level: level, useSearch: useSearch);
          if (useSearch && level == AgentModeLevel.off) {
            // Chat 联网循环：无状态工具、只有联网两件（需要替身避免真实服务）。
            continue;
          }
          final tools = promptInterface.tools(
            AgentToolsRequest(
              level: level,
              workingCopy: level.isOn ? copyOf() : null,
              useSearch: useSearch,
              search: useSearch ? HtmlSearchService() : null,
            ),
          );
          expect(
            names,
            [for (final tool in tools) tool.name],
            reason: '档位 $level / 联网 $useSearch',
          );
        }
      }
    });
  });

  group('v3 · user() / stage*() 与 system 的衔接', () {
    test('user 在本轮输出契约处收尾，契约与模式一致', () {
      final chat = promptInterface.user(requestOf(PromptMode.chat));
      final agent = promptInterface.user(requestOf(PromptMode.agentLv1));
      expect(chat, contains('# 本轮输出契约：'));
      expect(chat, contains('直接给出 6 个二级标题区块'));
      expect(agent, contains('按两步执行'));
      // user 里不重复 system 的模块化内容。
      expect(chat, isNot(contains('# 当前请求协议：')));
      expect(chat, isNot(contains('# 通用输出契约：')));
    });

    test('Agent 回合指令与 system 契约同源（工具名、区块数、第二步）', () {
      final system = promptInterface.system(
        requestOf(
          PromptMode.agentLv1,
          toolNames: const ['narrchat_readHistory', 'narrchat_editHistory'],
        ),
      );
      final prepare = promptInterface.stagePrepare(const AgentStageRequest());
      final story = promptInterface.stageStory(const AgentStageRequest());
      final state = promptInterface.stageState(const AgentStageRequest());
      for (final text in [prepare, story, state]) {
        expect(text, isNotEmpty);
      }
      expect(system, contains(kReadHistoryToolName));
      expect(prepare, contains(kReadHistoryToolName));
      expect(story, contains('5 个二级标题'));
      expect(state, contains(kEditHistoryToolName));
    });
  });

  test('PromptRequest 的默认值与模式集合', () {
    expect(PromptMode.values, [PromptMode.chat, PromptMode.agentLv1]);
    final request = requestOf(PromptMode.chat);
    expect(request.mode, PromptMode.chat);
    expect(request.toolNames, isEmpty);
    expect(request.rewrite, isNull);
    expect(request.mods, isNull);
  });
}
