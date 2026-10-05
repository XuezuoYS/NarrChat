import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/models/agent_mode_level.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/models/round_send_intent.dart';
import 'package:narrchat/providers/ai_settings_provider.dart';
import 'package:narrchat/providers/cloud_sync_provider.dart';
import 'package:narrchat/providers/experimental_settings_provider.dart';
import 'package:narrchat/providers/round_provider.dart';
import 'package:narrchat/services/ai_service.dart';
import 'package:narrchat/services/request_frame_outline.dart';

import 'helpers/fakes.dart';

/// 「预览请求体」= 真实发送请求体的重构验收测试。
///
/// 核心断言：预览给出的**首帧**与实发（RAW 捕获 / 注入的 AI 替身收到的请求体）
/// **逐字一致**，且预览本身零副作用（不落库、不发网络、不改生成状态、不触发同步）。
///
/// 每类入口各覆盖一次：普通新一轮 / 灰条「修改并重新提问」（先删轮再发）/
/// 灰条「按意见修改」（修改轮）/ Agent Lv.1（首帧 = 准备帧，非正文帧）/
/// Agent Lv.2 / 联网工具循环。
void main() {
  const book = Book(uuid: 'b1', title: '测试书', historyRounds: 2);

  ({RoundProvider provider, FakeRoundDao dao, RecordingAiService ai}) build({
    AiSettingsProvider? settings,
    ExperimentalSettingsProvider? experimental,
    CloudSyncProvider? cloudSync,
  }) {
    final dao = FakeRoundDao();
    final ai = RecordingAiService();
    final provider = RoundProvider(
      dao: dao,
      roundStackService: FakeRoundStackService(roundDao: dao),
      bookDao: FakeBookDao(books: [book]),
      aiService: ai,
      aiSettingsProvider: settings ?? _SearchDisabledSettings(),
      experimentalSettings: experimental,
      cloudSyncProvider: cloudSync,
      retryDelay: Duration.zero,
    );
    return (provider: provider, dao: dao, ai: ai);
  }

  /// 直接预置第 1..[count] 轮（绕开生成，构造可控历史）。
  ///
  /// 输入文案刻意用「轮次N原文」这种**不会互为子串**的标记，便于断言某轮是否
  /// 真的进了请求。
  Future<List<Round>> seedRounds(
    FakeRoundDao dao,
    int count, {
    String image = '',
  }) async {
    final seeded = <Round>[];
    for (var i = 1; i <= count; i++) {
      final round = Round(
        bookUuid: book.uuid,
        roundIndex: i,
        userInput: '轮次$i原文',
        aiNarrative: '第 $i 轮正文',
        currentTime: '第 $i 天',
        userImages: image.isEmpty ? const [] : [image],
        createdAt: DateTime(2026, 1, i),
      );
      await dao.insertRound(round);
      seeded.add(round);
    }
    return seeded;
  }

  String textOfBody(Map<String, dynamic> body) => jsonEncode(body);

  group('预览 ≡ 实发（首帧逐字一致）', () {
    test('直发：首帧一致，且没有后续帧', () async {
      final env = build();
      await env.provider.loadRounds(book.uuid);

      final preview = await env.provider.previewRequestBody(
        intent: RoundSendIntent.newRound(userInput: '你好'),
        book: book,
      );
      expect(preview.hasSubsequentFrames, isFalse, reason: '直发只有一帧');
      expect(env.ai.calls, 0, reason: '预览不发起任何 AI 调用');

      expect(
        await env.provider.sendIntent(
          intent: RoundSendIntent.newRound(userInput: '你好'),
          book: book,
        ),
        isTrue,
      );
      expect(env.ai.bodies.single, preview.firstFrame, reason: '注入替身收到的首帧');
      final round = env.dao.rounds.firstWhere((r) => r.roundIndex == 1);
      expect(
        env.provider.rawExchangesFor(round.id!)!.single.requestBody,
        preview.firstFrameJson,
        reason: 'RAW 捕获的实发首帧',
      );
    });

    test('灰条「修改并重新提问」：按截断后的投影组装，首帧一致', () async {
      final env = build();
      await env.provider.loadRounds(book.uuid);
      await seedRounds(env.dao, 4);
      await env.provider.loadRounds(book.uuid);

      final intent = RoundSendIntent.reaskRound(
        targetRoundIndex: 3,
        userInput: '轮次3改后',
      );
      final preview = await env.provider.previewRequestBody(
        intent: intent,
        book: book,
      );
      final text = textOfBody(preview.firstFrame);
      expect(text, contains('轮次3改后'));
      // n = 2 → 截断到第 3 轮之后，历史 = 被重写轮之前最近 2 轮（第 1、2 轮）。
      expect(text, contains('轮次1原文'));
      expect(text, contains('轮次2原文'));
      expect(text, isNot(contains('轮次3原文')), reason: '该轮已被截断重发');
      expect(text, isNot(contains('轮次4原文')), reason: '后续轮次随截断消失');

      expect(await env.provider.sendIntent(intent: intent, book: book), isTrue);
      expect(env.ai.bodies.single, preview.firstFrame);
      // 截断真的发生了：投影停在第 3 轮（新代）。
      expect(env.provider.rounds.map((r) => r.roundIndex), [0, 1, 2, 3]);
    });

    test('灰条「按意见修改」：修改轮请求（n+1 历史 + 意见），首帧一致', () async {
      final env = build();
      await env.provider.loadRounds(book.uuid);
      final seeded = await seedRounds(env.dao, 4, image: 'img/round.png');
      await env.provider.loadRounds(book.uuid);

      final intent = RoundSendIntent.rewriteByOpinion(
        targetRoundIndex: 4,
        opinion: '把第 4 轮写紧凑些',
      );
      final preview = await env.provider.previewRequestBody(
        intent: intent,
        book: book,
      );
      final text = textOfBody(preview.firstFrame);
      expect(text, contains('把第 4 轮写紧凑些'), reason: '意见进请求');
      // n = 2 → 历史 = 被重写轮之前最近 2 轮（第 2、3 轮）+ 被重写轮自身。
      expect(text, contains('轮次2原文'));
      expect(text, contains('轮次3原文'));
      expect(text, contains('轮次4原文'));
      expect(text, isNot(contains('轮次1原文')));

      expect(await env.provider.sendIntent(intent: intent, book: book), isTrue);
      expect(env.ai.bodies.single, preview.firstFrame);
      // 新版本沿用原输入 / 原图（意见与意见附图不落库）。
      final latest = env.provider.rounds.last;
      expect(latest.roundIndex, 4);
      expect(latest.userInput, '轮次4原文');
      expect(latest.userImages, const ['img/round.png']);
      expect(seeded.length, 4);
    });

    test('Agent Lv.1：首帧 = 准备帧（含准备阶段指令），与实发首帧逐字一致', () async {
      final env = build(
        settings: AiSettingsProvider(),
        experimental: AgentModeSettings(level: AgentModeLevel.lv1),
      );
      await env.provider.loadRounds(book.uuid);

      final preview = await env.provider.previewRequestBody(
        intent: RoundSendIntent.newRound(userInput: '第一章'),
        book: book,
      );
      final input = (preview.firstFrame['input'] as List)
          .cast<Map<String, dynamic>>();
      // Lv.1 第一步是准备帧：末条不再只是用户输入，而是紧随其后的帧指令
      // （旧实现误按「正文帧」预览，与实际发出的首帧不符）。
      expect(input.last['role'], 'user');
      expect('${input.last['content']}', isNot('第一章'));
      expect(
        input.map((i) => '${i['content']}').any((c) => c.contains('第一章')),
        isTrue,
      );
      expect(
        preview.subsequentFrames.map((f) => f.label).toList(),
        ['记忆帧', '正文帧', '维护帧'],
      );
      // 后续帧只列增量：本帧追加的都是 input 条目。
      for (final frame in preview.subsequentFrames) {
        expect(frame.addedFields.keys, contains('input'));
      }

      expect(
        await env.provider.sendIntent(
          intent: RoundSendIntent.newRound(userInput: '第一章'),
          book: book,
        ),
        isTrue,
      );
      expect(env.ai.bodies.first, preview.firstFrame, reason: '实发首帧 = 预览首帧');
    });

    test('Agent Lv.2：首帧 = 正文帧，后续可用帧为维护帧', () async {
      final env = build(
        settings: AiSettingsProvider(),
        experimental: AgentModeSettings(),
      );
      await env.provider.loadRounds(book.uuid);

      final preview = await env.provider.previewRequestBody(
        intent: RoundSendIntent.newRound(userInput: '第一章'),
        book: book,
      );
      expect(
        preview.subsequentFrames.map((f) => f.label).toList(),
        ['维护帧'],
      );

      expect(
        await env.provider.sendIntent(
          intent: RoundSendIntent.newRound(userInput: '第一章'),
          book: book,
        ),
        isTrue,
      );
      expect(env.ai.bodies.first, preview.firstFrame);
    });

    test('联网工具循环：首帧一致，后续帧只含追加的消息（占位形态）', () async {
      final env = build(settings: _SearchEnabledSettings());
      await env.provider.loadRounds(book.uuid);

      final intent = RoundSendIntent.newRound(userInput: '查一下青云宗');
      final preview = await env.provider.previewRequestBody(
        intent: intent,
        book: book,
      );
      expect(
        preview.subsequentFrames.map((f) => f.label).toList(),
        ['工具循环续接帧'],
      );
      final added = preview.subsequentFrames.single.addedFields;
      final tail = added['messages']! as Map<String, dynamic>;
      expect(
        tail.keys,
        containsAll(<String>['…', '+']),
        reason: '数组字段只保留追加项（前 N 项同上一帧）',
      );
      final appended = (tail['+'] as List).cast<Map<String, dynamic>>();
      expect(
        appended.map((m) => m['role']),
        containsAll(<String>['assistant', 'tool']),
      );

      expect(await env.provider.sendIntent(intent: intent, book: book), isTrue);
      expect(env.ai.bodies.single, preview.firstFrame);
    });

    test('状态一变预览立刻变：输入 / 联网开关变化后不复用上一次的拼合结果', () async {
      final settings = _MutableSettings();
      final env = build(settings: settings);
      await env.provider.loadRounds(book.uuid);

      final before = await env.provider.previewRequestBody(
        intent: const RoundSendIntent.newRound(userInput: '甲'),
        book: book,
      );
      expect(before.hasSubsequentFrames, isFalse, reason: '前置：直发路径');
      expect(jsonEncode(before.firstFrame), contains('甲'));

      // 输入与联网开关同时变化：下一次预览必须立刻反映新状态。
      settings.search = true;
      final after = await env.provider.previewRequestBody(
        intent: const RoundSendIntent.newRound(userInput: '乙'),
        book: book,
      );
      expect(
        after.subsequentFrames.map((f) => f.label).toList(),
        ['工具循环续接帧'],
        reason: '联网开关生效 → 走工具循环',
      );
      final text = jsonEncode(after.firstFrame);
      expect(text, contains('乙'));
      expect(text, isNot(contains('甲')), reason: '不复用上一次预览的输入');
    });
  });

  group('预览零副作用', () {
    test('不落库 / 不发网络 / 不改生成状态 / 不触发同步', () async {
      final cloud = FakeCloudSyncProvider();
      final env = build(cloudSync: cloud);
      await env.provider.loadRounds(book.uuid);
      await seedRounds(env.dao, 2);
      await env.provider.loadRounds(book.uuid);
      final roundsBefore = List.of(env.dao.rounds);

      final preview = await env.provider.previewRequestBody(
        intent: RoundSendIntent.newRound(userInput: '你好'),
        book: book,
      );

      expect(preview.firstFrame, isNotEmpty);
      expect(env.ai.calls, 0, reason: '不发起任何 AI 调用');
      expect(env.dao.rounds, roundsBefore, reason: '不新增 / 不改写轮次');
      expect(env.provider.rounds.length, roundsBefore.length);
      expect(env.provider.isSending, isFalse);
      expect(env.provider.pendingUserInput, isEmpty);
      expect(env.provider.hasFailureEntry, isFalse);
      expect(env.provider.failedRawExchanges, isNull);
      expect(cloud.triggers, 0, reason: '不触发云同步');
    });

    test('灰条用途预览同样不删轮次（截断只发生在意图实发时）', () async {
      final env = build();
      await env.provider.loadRounds(book.uuid);
      await seedRounds(env.dao, 4);
      await env.provider.loadRounds(book.uuid);
      final roundsBefore = List.of(env.dao.rounds);

      await env.provider.previewRequestBody(
        intent: RoundSendIntent.rewriteByOpinion(
          targetRoundIndex: 4,
          opinion: '写紧凑些',
        ),
        book: book,
      );

      expect(env.dao.rounds, roundsBefore);
      expect(env.provider.rounds.map((r) => r.roundIndex), [0, 1, 2, 3, 4]);
    });

    test('输入为空：预览照常给出「此刻发出去会是什么」（不抛异常）', () async {
      final env = build();
      await env.provider.loadRounds(book.uuid);

      final preview = await env.provider.previewRequestBody(
        intent: const RoundSendIntent.newRound(userInput: ''),
        book: book,
      );
      final messages = (preview.firstFrame['messages'] as List)
          .cast<Map<String, dynamic>>();
      expect(messages.last['role'], 'user');
      // 如实反映：用户消息仍在（模板骨架），但【主人的输入】为空。
      final content = messages.last['content'] as String;
      expect(content, contains('【主人的输入】'));
      expect(
        content
            .split('【主人的输入】')
            .last
            .split('【主人的输入stop】')
            .first
            .trim(),
        isEmpty,
      );
    });
  });

  group('意图校验', () {
    test('目标轮次已不存在（按意见修改）：预览与实发给出同一句提示', () async {
      final env = build();
      await env.provider.loadRounds(book.uuid);
      const intent = RoundSendIntent.rewriteByOpinion(
        targetRoundIndex: 3,
        opinion: '写紧凑些',
      );

      expect(env.provider.validateSendIntent(intent), '该轮次已不存在，已退出修改');
      await expectLater(
        env.provider.previewRequestBody(intent: intent, book: book),
        throwsStateError,
      );
      expect(await env.provider.sendIntent(intent: intent, book: book), isFalse);
      expect(env.provider.error, '该轮次已不存在，已退出修改');
      expect(env.ai.calls, 0);
    });

    test('「刷新本轮」载体允许指向尚不存在的轮次（失败条目「本该产生的那一轮」）', () async {
      final env = build();
      await env.provider.loadRounds(book.uuid);
      env.ai.failWith = const AiException('模拟失败');
      await env.provider.sendRound(
        userInput: '第一章',
        book: book,
        userImages: const ['img/a.png'],
      );
      expect(env.provider.hasFailureEntry, isTrue);

      // 与 UI 同口径：失败条目现构一个「本该产生的那一轮」载体（投影里没有该轮）。
      const intent = RoundSendIntent.reaskRound(
        targetRoundIndex: 1,
        userInput: '第一章',
        images: ['img/a.png'],
      );
      expect(env.provider.validateSendIntent(intent), isNull, reason: '截断即无操作');

      final preview = await env.provider.previewRequestBody(
        intent: intent,
        book: book,
      );
      expect(
        (preview.firstFrame['messages'] as List).cast<Map<String, dynamic>>()
            .last['content'],
        contains('第一章'),
      );

      env.ai.failWith = null;
      expect(await env.provider.sendIntent(intent: intent, book: book), isTrue);
      // bodies.last：第一次实发是失败那次，成功这次才是被对拍的首帧。
      expect(env.ai.bodies.last, preview.firstFrame);
      expect(env.provider.rounds.last.roundIndex, 1);
      expect(env.provider.rounds.last.userInput, '第一章');
      expect(env.provider.rounds.last.userImages, const ['img/a.png']);
    });

    test('未选择书籍：预览抛出 StateError', () async {
      final env = build();
      await env.provider.loadRounds(book.uuid);

      await expectLater(
        env.provider.previewRequestBody(
          intent: const RoundSendIntent.newRound(userInput: '你好'),
          book: null,
        ),
        throwsStateError,
      );
    });
  });

  group('请求帧增量（纯函数）', () {
    test('数组前缀只留追加项；新增 / 省略字段各归其位', () {
      final base = <String, dynamic>{
        'model': 'm',
        'output': [
          {'role': 'system'},
          {'role': 'user'},
        ],
        'instructions': 'sys',
      };
      final next = <String, dynamic>{
        'model': 'm',
        'output': [
          {'role': 'system'},
          {'role': 'user'},
          {'role': 'assistant'},
        ],
      };

      final delta = diffFrameFields(base, next);
      expect(delta.added.keys, ['output']);
      expect(delta.added['output'], {
        '…': '前 2 项同上一帧',
        '+': [
          {'role': 'assistant'},
        ],
      });
      expect(delta.added.containsKey('model'), isFalse, reason: '同值字段不出现');
      expect(delta.removed, ['instructions'], reason: '有状态续接帧省略的字段');
    });

    test('fromOutline：首帧取第一项，其余按上一帧求增量', () {
      final preview = RoundRequestPreview.fromOutline(const [
        RequestFrameOutline(
          label: '准备帧',
          note: '第一步',
          body: {
            'input': [
              {'role': 'user', 'content': 'hi'},
            ],
          },
        ),
        RequestFrameOutline(
          label: '记忆帧',
          note: '第二步',
          body: {
            'input': [
              {'role': 'user', 'content': 'hi'},
              {'role': 'user', 'content': '阶段指令'},
            ],
          },
        ),
      ]);

      expect(preview.firstFrame['input'], hasLength(1));
      final frame = preview.subsequentFrames.single;
      expect(frame.label, '记忆帧');
      expect(frame.note, '第二步');
      expect(frame.diffJson, contains('阶段指令'));
      expect(frame.diffJson, isNot(contains('hi')), reason: '不重抄上一帧');
    });
  });
}

/// 禁用联网搜索的 AI 设置（强制走 Chat 直发路径，且不触碰本地配置文件）。
class _SearchDisabledSettings extends ChatCompatibleSettings {
  @override
  bool get lastSearch => false;
}

/// 强制开启联网搜索的 AI 设置（走 Chat Agent 工具循环；不触碰本地配置文件）。
class _SearchEnabledSettings extends ChatCompatibleSettings {
  @override
  bool get lastSearch => true;

  @override
  bool get supportsSearch => true;
}

/// 联网开关可在用例中翻转的设置（验证「预览随状态立刻变化」）。
class _MutableSettings extends ChatCompatibleSettings {
  bool search = false;

  @override
  bool get lastSearch => search;

  @override
  bool get supportsSearch => true;
}
