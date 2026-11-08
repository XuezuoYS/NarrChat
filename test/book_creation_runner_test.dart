import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/config/ai_platforms.dart';
import 'package:narrchat/models/ai_platform.dart';
import 'package:narrchat/models/api_type.dart';
import 'package:narrchat/models/mod.dart';
import 'package:narrchat/services/ai_service.dart';
import 'package:narrchat/services/book_creation/book_creation_prompts.dart';
import 'package:narrchat/services/book_creation/book_creation_runner.dart';
import 'package:narrchat/services/book_creation/book_creation_step.dart';

import 'helpers/book_creation_fixtures.dart';
import 'helpers/fakes.dart';

/// 分步执行器：顺序、解析、补充轮、硬失败、取消与用量。
void main() {
  List<ScriptedAiResponse> validScripts() => completeBookCreationResponses();

  BookCreationRunner runnerWith(
    ScriptedAiService ai, {
    AiPlatform? platform,
    bool streaming = true,
    bool thinking = true,
    int maxSupplementRounds = 2,
  }) {
    final resolved = platform ?? AiPlatforms.defaultPlatform;
    return BookCreationRunner(
      aiService: ai,
      platform: resolved,
      model: resolved.defaultModel,
      apiKey: 'test-key',
      baseUrl: 'https://api.example.com',
      reasoningEffort: 'high',
      thinking: thinking,
      streaming: streaming,
      maxSupplementRounds: maxSupplementRounds,
    );
  }

  AiPlatform chatPlatform() => AiPlatforms.defaultPlatform.copyWith(
        apiType: ApiType.openAiCompatible,
        baseUrl: 'https://api.example.com',
      );

  test('五个阶段顺序执行、解析成完整草稿并累加用量', () async {
    final ai = ScriptedAiService(validScripts());
    final events = <BookCreationStepEvent>[];
    final result = await runnerWith(ai).run(
      idea: kBookCreationIdea,
      availableMods: [PresetForTest.webNovel],
      onEvent: events.add,
    );

    expect(ai.calls, 5);
    expect(ai.wires, everyElement('responses'));
    expect(result.draft.title, '妖灵事务所');
    expect(result.draft.category, '都市奇幻');
    expect(result.draft.modRefs, ['preset:web_novel_style']);
    expect(result.draft.baseSetting, contains('现代都市'));
    expect(result.draft.effectiveWorldBook, hasLength(1));
    expect(result.draft.effectiveWorldBook.single.keyword, '事务所, 委托');
    expect(result.draft.globalPrePrompt, contains('遵守设定'));
    expect(result.draft.globalPostPrompt, contains('不要写'));
    expect(result.draft.writingRequirements, contains('多用短句'));
    expect(result.draft.effectiveRoleCategories.map((c) => c.name), [
      '主角',
      'NPC',
    ]);
    expect(result.remainingProblems, isEmpty);
    expect(result.usage.promptTokens, 50);
    expect(result.usage.completionTokens, 100);
    expect(result.usage.cachedTokensIn, 25);

    // 事件：每个固定阶段都有 running / done，且顺序与 baseStages 一致。
    final doneStages = [
      for (final event in events)
        if (event.status == BookCreationStepStatus.done) event.stage,
    ];
    expect(doneStages, [
      BookCreationStage.titleCategory,
      BookCreationStage.mods,
      BookCreationStage.baseSettingWorldBook,
      BookCreationStage.prompts,
      BookCreationStage.roleCategories,
    ]);
    expect(
      events.any((event) => event.status == BookCreationStepStatus.running),
      isTrue,
    );
    // 流式文本去过标签。
    final visible = events
        .where((event) => event.visibleText.isNotEmpty)
        .map((event) => event.visibleText)
        .join('\n');
    expect(visible, contains('妖灵事务所'));
    expect(visible, isNot(contains('<title>')));
  });

  test('Chat 线路：system + user 消息，不带 instructions', () async {
    final ai = ScriptedAiService(validScripts());
    final result = await runnerWith(ai, platform: chatPlatform()).run(
      idea: kBookCreationIdea,
      availableMods: [PresetForTest.webNovel],
    );

    expect(result.remainingProblems, isEmpty);
    expect(ai.wires, everyElement('chat'));
    final first = ai.bodies.first;
    expect(first['messages'], isA<List<dynamic>>());
    final messages = first['messages'] as List<dynamic>;
    expect((messages.first as Map)['role'], 'system');
    expect((messages.first as Map)['content'], BookCreationPrompts.system);
    expect((messages.last as Map)['role'], 'user');
    expect(first.containsKey('instructions'), isFalse);
  });

  test('Responses 线路：instructions + input，不带 system 消息', () async {
    final ai = ScriptedAiService(validScripts());
    await runnerWith(ai).run(
      idea: kBookCreationIdea,
      availableMods: [PresetForTest.webNovel],
    );

    final first = ai.bodies.first;
    expect(first['instructions'], BookCreationPrompts.system);
    final input = first['input'] as List<dynamic>;
    expect(input, hasLength(1));
    expect((input.single as Map)['role'], 'user');
    expect(first.containsKey('messages'), isFalse);
  });

  test('不完整 -> 一次补充轮补全', () async {
    final scripts = [
      const ScriptedAiResponse(kBookTitleScript),
      const ScriptedAiResponse(kBookModsScript),
      // 世界书块存在但为空 -> 完整性检查报「世界书为空」。
      const ScriptedAiResponse('<baseSetting>设定</baseSetting><worldBook></worldBook>'),
      const ScriptedAiResponse(kBookPromptsScript),
      const ScriptedAiResponse(kBookRolesScript),
      // 补充轮：补齐世界书。
      const ScriptedAiResponse('''
<worldBook>
<entry>
<keyword>事务所</keyword>
<content>旧城区的妖灵事务所。</content>
</entry>
</worldBook>
'''),
    ];
    final ai = ScriptedAiService(scripts);
    final events = <BookCreationStepEvent>[];
    final result = await runnerWith(ai).run(
      idea: kBookCreationIdea,
      availableMods: [PresetForTest.webNovel],
      onEvent: events.add,
    );

    expect(ai.calls, 6);
    expect(result.remainingProblems, isEmpty);
    expect(result.draft.effectiveWorldBook, hasLength(1));
    final supplementEvents = events
        .where((event) => event.stage == BookCreationStage.supplement)
        .toList();
    expect(supplementEvents, isNotEmpty);
    expect(supplementEvents.first.attempt, 1);
    expect(supplementEvents.last.status, BookCreationStepStatus.done);
  });

  test('两次补充轮后仍不完整：返回剩余问题', () async {
    final scripts = [
      const ScriptedAiResponse(kBookTitleScript),
      const ScriptedAiResponse(kBookModsScript),
      const ScriptedAiResponse(kBookBaseScript),
      // 缺 writingRequirements。
      const ScriptedAiResponse(
        '<prePrompt>前置</prePrompt><postPrompt>后置</postPrompt>',
      ),
      const ScriptedAiResponse(kBookRolesScript),
      const ScriptedAiResponse(''), // 补充 1：什么都不给
      const ScriptedAiResponse(''), // 补充 2：什么都不给
    ];
    final ai = ScriptedAiService(scripts);
    final result = await runnerWith(ai).run(
      idea: kBookCreationIdea,
      availableMods: [PresetForTest.webNovel],
    );

    expect(ai.calls, 7);
    expect(
      result.remainingProblems,
      contains('文笔要求缺失'),
    );
  });

  test('API 失败：带阶段信息抛出，并发出 failed 事件', () async {
    final scripts = [
      const ScriptedAiResponse(kBookTitleScript),
      const ScriptedAiResponse(kBookModsScript),
      const ScriptedAiResponse('', error: AiException('模拟网络失败')),
    ];
    final ai = ScriptedAiService(scripts);
    final events = <BookCreationStepEvent>[];
    await expectLater(
      runnerWith(ai).run(
        idea: kBookCreationIdea,
        availableMods: [PresetForTest.webNovel],
        onEvent: events.add,
      ),
      throwsA(
        isA<BookCreationException>()
            .having((e) => e.stage, 'stage', BookCreationStage.baseSettingWorldBook)
            .having((e) => e.message, 'message', contains('模拟网络失败')),
      ),
    );
    expect(
      events.any(
        (event) =>
            event.stage == BookCreationStage.baseSettingWorldBook &&
            event.status == BookCreationStepStatus.failed,
      ),
      isTrue,
    );
  });

  test('输出截断：直接硬失败并提示调高最大 token', () async {
    final ai = ScriptedAiService([
      const ScriptedAiResponse(kBookTitleScript),
      const ScriptedAiResponse(kBookModsScript, incomplete: true),
    ]);
    await expectLater(
      runnerWith(ai).run(
        idea: kBookCreationIdea,
        availableMods: [PresetForTest.webNovel],
      ),
      throwsA(
        isA<BookCreationException>()
            .having((e) => e.stage, 'stage', BookCreationStage.mods)
            .having((e) => e.message, 'message', contains('截断')),
      ),
    );
  });

  test('取消：开始前就抛 AiCancelledException，不发起请求', () async {
    final ai = ScriptedAiService(validScripts());
    await expectLater(
      runnerWith(ai).run(
        idea: kBookCreationIdea,
        availableMods: [PresetForTest.webNovel],
        isCancelled: () => true,
      ),
      throwsA(isA<AiCancelledException>()),
    );
    expect(ai.calls, 0);
  });

  test('非流式：不推流式文本增量，仍能完成', () async {
    final ai = ScriptedAiService(validScripts());
    final events = <BookCreationStepEvent>[];
    final result = await runnerWith(ai, streaming: false).run(
      idea: kBookCreationIdea,
      availableMods: [PresetForTest.webNovel],
      onEvent: events.add,
    );
    expect(result.remainingProblems, isEmpty);
    expect(ai.streams, everyElement(isFalse));
    // running 事件只来自阶段开始（没有 chunk 文本）。
    expect(
      events.where(
        (event) =>
            event.status == BookCreationStepStatus.running &&
            event.visibleText.isNotEmpty,
      ),
      isEmpty,
    );
  });
}

/// 测试用预置 Mod 引用（只用于目录匹配）。
class PresetForTest {
  static const webNovel = Mod(
    presetKey: 'web_novel_style',
    name: '默认网文语感强化',
    description: '强化网文语感',
  );
}
