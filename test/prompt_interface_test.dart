import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/models/agent_mode_level.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/services/agent/agent_mode_profile.dart';
import 'package:narrchat/services/agent/agent_stage_directives.dart';
import 'package:narrchat/services/agent/fetch_page_tool.dart';
import 'package:narrchat/services/agent/narr_agent_tool.dart';
import 'package:narrchat/services/agent/state/agent_state_working_copy.dart';
import 'package:narrchat/services/agent/state/state_tools.dart';
import 'package:narrchat/services/agent/web_search_tool.dart';
import 'package:narrchat/services/html_search_service.dart';
import 'package:narrchat/services/prompt_builder.dart';
import 'package:narrchat/services/prompt_formats.dart';
import 'package:narrchat/services/prompt_interface.dart';
import 'package:narrchat/services/prompt_interface_v1.dart';
import 'package:narrchat/services/prompt_sections.dart';

/// `prompt_interface` 契约与 v1 转发层的**锁定测试**。
///
/// 目的：接口是将来替换 v2 提示词的唯一替换点，接入前必须证明「接口输出 ==
/// 线上现有输出」——
/// - system / user 逐字节等于线上 `PromptBuilder` 的产物（三个模式）；
/// - 工具集与档位栏目、注入替身、缺依赖报错的语义与现有一致；
/// - 阶段帧指令与 `AgentStageDirectives` / `AgentLv1PromptFormat` 同源。
/// 提示词文案本身的断言留在 `prompt_builder_test.dart` / `prompt_formats_test.dart`，
/// 本文件只锁「取用路由」。
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

  PromptRequest requestOf(PromptMode mode) => PromptRequest(
        book: book,
        mode: mode,
        lastRound: lastRound,
        userInput: '我走向主殿，想要拜见掌门。',
        worldBookEntries: '青云宗是北域第一大派。',
      );

  AgentStateWorkingCopy copyOf() => AgentStateWorkingCopy(
        roundIndex: lastRound.roundIndex + 1,
        lastRound: lastRound,
        categoryNames: const [],
      );

  /// 工具的可比较指纹（名字 + 描述 + 参数 schema）。
  List<String> fingerprint(List<NarrAgentTool> tools) =>
      [for (final t in tools) '${t.name}|${t.description}|${t.parameters}'];

  test('绑定：当前唯一实现是 v1 转发层', () {
    expect(promptInterface, isA<PromptInterfaceV1>());
  });

  group('PromptInterface · system / user（逐字节等于线上 PromptBuilder）', () {
    for (final mode in PromptMode.values) {
      test('${mode.name}：system、user 与 PromptBuilder 完全一致', () {
        final request = requestOf(mode);
        final online = const PromptBuilder().build(
          book: book,
          lastRound: lastRound,
          userInput: request.userInput,
          worldBookEntries: request.worldBookEntries,
          mode: mode,
        );

        expect(promptInterface.system(request), online.systemPrompt);
        expect(promptInterface.user(request), online.userPrompt);

        // 内容锚点：确认不是空串 / 没有漏拼关键段。
        expect(
          promptInterface.system(request),
          contains('当前模式：${mode.format.modeLabel}'),
        );
        expect(promptInterface.system(request), contains('测试书'));
        expect(promptInterface.user(request), contains('我走向主殿，想要拜见掌门。'));
        expect(promptInterface.user(request), contains('【上轮时间】'));
      });
    }

    test('Chat：system 含 6 个二级标题契约，Lv.1 只含 5 个（无记忆总结）', () {
      final chat = promptInterface.system(requestOf(PromptMode.chat));
      expect(chat, contains('6 个二级标题'));
      expect(chat, contains('  - `## 记忆总结`'));

      final lv1 = promptInterface.system(requestOf(PromptMode.agentLv1));
      expect(lv1, contains('5 个二级标题'));
      // Lv.1 只在「禁止输出」规则里提到记忆总结，不在允许输出的区块清单里。
      expect(lv1, isNot(contains('  - `## 记忆总结`')));
      expect(lv1, contains('  - `## 角色状态`'));
    });
  });

  group('PromptInterface · 工具集路由', () {
    test('Lv.1 = 历史一读一写（与 buildStateTools 同源）', () {
      final tools = promptInterface.tools(
        AgentToolsRequest(level: AgentModeLevel.lv1, workingCopy: copyOf()),
      );
      expect([for (final t in tools) t.name], [
        kReadHistoryToolName,
        kEditHistoryToolName,
      ]);
      expect(
        fingerprint(tools),
        fingerprint(
          buildStateTools(copyOf(), sections: AgentModeProfile.lv1.toolSections),
        ),
      );
    });

    test('Lv.2 = 六个状态工具（读取器在前、编辑器在后）', () {
      final tools = promptInterface.tools(
        AgentToolsRequest(level: AgentModeLevel.lv2, workingCopy: copyOf()),
      );
      expect([for (final t in tools) t.name], kStateToolNames);
      expect(
        fingerprint(tools),
        fingerprint(
          buildStateTools(copyOf(), sections: AgentModeProfile.lv2.toolSections),
        ),
      );
    });

    test('Chat 联网循环 = 搜索 + 打开页（无工作副本 → 无状态工具）', () {
      final tools = promptInterface.tools(
        AgentToolsRequest(
          level: AgentModeLevel.off,
          useSearch: true,
          search: HtmlSearchService(),
        ),
      );
      expect([for (final t in tools) t.name], [
        'narrchat_webSearch',
        'narrchat_webFetchPage',
      ]);
    });

    test('Lv.2 + 联网 = 六工具 + 两个联网工具（顺序稳定）', () {
      final tools = promptInterface.tools(
        AgentToolsRequest(
          level: AgentModeLevel.lv2,
          workingCopy: copyOf(),
          useSearch: true,
          search: HtmlSearchService(),
        ),
      );
      expect(tools.length, kStateToolNames.length + 2);
      expect([for (final t in tools) t.name], [
        ...kStateToolNames,
        'narrchat_webSearch',
        'narrchat_webFetchPage',
      ]);
    });

    test('注入的联网工具替身原样使用（same 实例）', () {
      final web = WebSearchTool();
      final fetch = FetchPageTool();
      final tools = promptInterface.tools(
        AgentToolsRequest(
          level: AgentModeLevel.lv2,
          workingCopy: copyOf(),
          useSearch: true,
          webSearch: web,
          fetchPage: fetch,
        ),
      );
      expect(tools[tools.length - 2], same(web));
      expect(tools.last, same(fetch));
    });

    test('启用联网却没有抓取服务 → 显式报错（不静默回落真实服务）', () {
      expect(
        () => promptInterface.tools(
          const AgentToolsRequest(level: AgentModeLevel.off, useSearch: true),
        ),
        throwsArgumentError,
      );
    });

    test('不启用联网时只有状态工具', () {
      final tools = promptInterface.tools(
        AgentToolsRequest(level: AgentModeLevel.lv2, workingCopy: copyOf()),
      );
      expect(
        [for (final t in tools) t.name].where((n) => n.contains('web')),
        isEmpty,
      );
    });
  });

  group('PromptInterface · 阶段帧指令（与执行器同一真源）', () {
    const lv1 = AgentStageRequest(level: AgentModeLevel.lv1);

    test('准备 / 正文帧 = AgentLv1PromptFormat 的同一份文案', () {
      expect(
        promptInterface.stagePrepare(lv1),
        const AgentLv1PromptFormat().prepareNote().join('\n'),
      );
      expect(
        promptInterface.stageStory(lv1),
        const AgentLv1PromptFormat().storyNote().join('\n'),
      );
      expect(promptInterface.stagePrepare(lv1), contains('narrchat_readHistory'));
      expect(promptInterface.stagePrepare(lv1), contains('大纲'));
      expect(promptInterface.stageStory(lv1), contains('`## 世界状态`'));
    });

    test('记忆帧 = AgentStageDirectives 的同一份文案（缺工作副本报错）', () {
      final copy = copyOf();
      final request = AgentStageRequest(
        level: AgentModeLevel.lv1,
        workingCopy: copy,
        first: true,
      );
      expect(
        promptInterface.stageMemory(request),
        AgentStageDirectives()
            .memoryDirective(first: true, workingCopy: copy)['content'] as String,
      );
      expect(promptInterface.stageMemory(request), contains('【记忆阶段】'));
      expect(
        () => promptInterface.stageMemory(lv1),
        throwsArgumentError,
      );
    });

    test('维护帧 = AgentStageDirectives 的同一份文案', () {
      const problems = ['memorySummary栏目本轮既未编辑也未声明无变化'];
      const request = AgentStageRequest(
        level: AgentModeLevel.lv2,
        problems: problems,
      );
      final content = promptInterface.stageState(request);
      expect(
        content,
        AgentStageDirectives()
            .stateDirective(
              problems: problems,
              first: true,
              level: AgentModeLevel.lv2,
            )['content'] as String,
      );
      expect(content, startsWith('[State-maintenance turn]'));
      expect(content, contains('- memorySummary栏目本轮既未编辑也未声明无变化'));
    });
  });

  test('PromptRequest.format 由 mode 派生（与 PromptMode.format 同源）', () {
    for (final mode in PromptMode.values) {
      final request = requestOf(mode);
      expect(request.format, same(mode.format));
      expect(request.format, isA<PromptFormatSpec>());
    }
  });

  test('未设置的 worldBookEntries / mods 不影响接口调用（空值可跑通）', () {
    const request = PromptRequest(book: book, mode: PromptMode.chat);
    expect(promptInterface.system(request), contains('当前模式：Chat'));
    expect(promptInterface.user(request), isNotEmpty);
    // 与显式传空值等价
    expect(
      promptInterface.system(request),
      const PromptSections().buildSystemPrompt(
        book: book,
        worldBookEntries: '',
        mods: null,
        format: PromptMode.chat.format,
      ),
    );
  });
}
