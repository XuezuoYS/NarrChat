import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/services/ai_service.dart';

import 'helpers/chat_harness.dart';
import 'helpers/fakes.dart';

/// 可控失败次数的 AI：前 [failTimes] 次抛 [failKind] 类异常，之后成功。
/// [gate] 非空时，成功那次调用前等待（便于观察中间重试状态）。
class _RetryAiService extends AiService {
  _RetryAiService({
    required this.failTimes,
    this.failKind = AiExceptionKind.network,
    this.gate,
  });

  final int failTimes;
  final AiExceptionKind failKind;
  final Completer<void>? gate;
  int calls = 0;

  @override
  Future<AiCallResult> chat({
    required String apiBaseUrl,
    required String apiKey,
    required Map<String, dynamic> requestBody,
    bool stream = false,
    void Function(AiStreamChunk chunk)? onChunk,
    void Function(String requestBody)? onRequestBody,
    bool Function()? isCancelled,
  }) async {
    calls++;
    if (calls <= failTimes) {
      throw AiException('模拟失败：${failKind.name}', kind: failKind);
    }
    if (gate != null) await gate!.future;
    onChunk?.call(const AiStreamChunk(done: true));
    return const AiCallResult(
      content: '## 剧情演绎\n重试成功正文\n'
          '## 推荐行动\n\n'
          '## 当前时间\n第一天 午时\n'
          '## 世界状态\n\n'
          '## 角色状态\n\n'
          '## 记忆总结\n',
      promptTokens: 1,
      completionTokens: 1,
    );
  }
}

/// 首次调用先输出部分内容再抛网络异常，之后成功（模拟流式中途断连）。
class _StreamFailThenOkAiService extends AiService {
  int calls = 0;

  @override
  Future<AiCallResult> chat({
    required String apiBaseUrl,
    required String apiKey,
    required Map<String, dynamic> requestBody,
    bool stream = false,
    void Function(AiStreamChunk chunk)? onChunk,
    void Function(String requestBody)? onRequestBody,
    bool Function()? isCancelled,
  }) async {
    calls++;
    if (calls == 1) {
      // 第 1 次：先输出部分内容再断连。
      onChunk?.call(const AiStreamChunk(contentDelta: '半截正文'));
      throw const AiException(
        '网络请求失败：模拟断连',
        kind: AiExceptionKind.network,
      );
    }
    onChunk?.call(const AiStreamChunk(done: true));
    return const AiCallResult(
      content: '## 剧情演绎\n完整正文\n'
          '## 推荐行动\n\n'
          '## 当前时间\n第一天 午时\n'
          '## 世界状态\n\n'
          '## 角色状态\n\n'
          '## 记忆总结\n',
      promptTokens: 1,
      completionTokens: 1,
    );
  }
}

/// 对话页生成失败 / 停止 / 自动重试的状态机测试（合并自 ai_retry_test 与
/// stop_generation_test：两文件都验证「失败条目落库 + 红框 UI」，独特用例
/// 全部保留）。
void main() {
  const book = Book(id: 1, title: '测试书');

  group('自动重试', () {
    testWidgets('网络类失败自动重试：灰字「错误重连（x/3）」并最终成功', (tester) async {
      final bookDao = FakeBookDao();
      final dao = FakeRoundDao();
      final gate = Completer<void>();
      final ai = _RetryAiService(failTimes: 2, gate: gate);
      final roundProvider = await pumpChatScreen(
        tester,
        ai: ai,
        bookDao: bookDao,
        roundDao: dao,
        retryDelay: const Duration(milliseconds: 100),
      );

      final sendFuture = roundProvider.sendRound(userInput: '触发重试', book: book);
      await tester.pump();
      // 第 1 次调用失败 → 进入 1/3 重试（灰字显示在流式气泡内）。
      expect(roundProvider.retryStatus, (1, 3));
      expect(find.text('错误重连……（1/3）'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 100));
      // 第 2 次调用失败 → 2/3。
      expect(roundProvider.retryStatus, (2, 3));
      expect(find.text('错误重连……（2/3）'), findsOneWidget);
      expect(find.text('错误重连……（1/3）'), findsNothing);

      await tester.pump(const Duration(milliseconds: 100));
      // 第 3 次调用成功但被 gate 挂起：仍显示 2/3（尚未产出内容）。
      expect(ai.calls, 3);
      expect(roundProvider.retryStatus, (2, 3));

      gate.complete();
      await waitSendDone(tester, roundProvider);

      // 成功：重试提示消失、正文入库、无失败条目。
      expect(await sendFuture, isTrue);
      expect(roundProvider.retryStatus, isNull);
      expect(find.textContaining('错误重连'), findsNothing);
      expect(find.textContaining('重试成功正文'), findsOneWidget);
      expect(bookDao.failed.isEmpty, isTrue);
      expect(ai.calls, 3);
    });

    testWidgets('网络类失败重试 3 次后仍失败：进入「生成失败」红框', (tester) async {
      final bookDao = FakeBookDao();
      final dao = FakeRoundDao();
      final ai = _RetryAiService(failTimes: 999); // 永远失败
      final roundProvider = await pumpChatScreen(
        tester,
        ai: ai,
        bookDao: bookDao,
        roundDao: dao,
        retryDelay: Duration.zero,
      );

      final sendFuture = roundProvider.sendRound(userInput: '触发失败', book: book);
      await waitSendDone(tester, roundProvider);

      expect(await sendFuture, isFalse);
      // 初始 1 次 + 重试 3 次 = 4 次调用。
      expect(ai.calls, 4);
      expect(roundProvider.retryStatus, isNull);
      // 失败条目保留用户输入与原因。
      expect(bookDao.failed.userInput, '触发失败');
      expect(bookDao.failed.errorMessage, contains('模拟失败'));
      // UI：红框 + 无灰字重试文本残留。
      expect(find.text('生成失败'), findsOneWidget);
      expect(find.textContaining('错误重连'), findsNothing);
    });

    testWidgets('API 业务类失败不自动重试', (tester) async {
      final bookDao = FakeBookDao();
      final dao = FakeRoundDao();
      final ai = _RetryAiService(failTimes: 999, failKind: AiExceptionKind.api);
      final roundProvider = await pumpChatScreen(
        tester,
        ai: ai,
        bookDao: bookDao,
        roundDao: dao,
        retryDelay: Duration.zero,
      );

      final sendFuture = roundProvider.sendRound(userInput: '触发失败', book: book);
      await waitSendDone(tester, roundProvider);

      expect(await sendFuture, isFalse);
      // 仅 1 次调用，不重试。
      expect(ai.calls, 1);
      expect(roundProvider.retryStatus, isNull);
      expect(find.text('生成失败'), findsOneWidget);
    });

    testWidgets('流式中途断连：重置半截正文并重试成功', (tester) async {
      final bookDao = FakeBookDao();
      final dao = FakeRoundDao();
      final ai = _StreamFailThenOkAiService();
      final roundProvider = await pumpChatScreen(
        tester,
        ai: ai,
        bookDao: bookDao,
        roundDao: dao,
        retryDelay: const Duration(milliseconds: 100),
      );

      final sendFuture = roundProvider.sendRound(userInput: '触发断连', book: book);
      await tester.pump();
      // 第 1 次调用输出半截正文后断连：半截内容已被重置，进入 1/3 重试。
      expect(roundProvider.streamingContent, isEmpty);
      expect(roundProvider.retryStatus, (1, 3));
      expect(find.text('错误重连……（1/3）'), findsOneWidget);
      expect(find.textContaining('半截正文'), findsNothing);

      await tester.pump(const Duration(milliseconds: 100));
      // 第 2 次调用成功：重试提示消失、正文入库。
      await waitSendDone(tester, roundProvider);
      expect(await sendFuture, isTrue);
      expect(roundProvider.retryStatus, isNull);
      expect(find.textContaining('错误重连'), findsNothing);
      expect(find.textContaining('完整正文'), findsOneWidget);
      expect(ai.calls, 2);
    });
  });

  group('失败 / 停止', () {
    testWidgets('请求失败：保留用户输入并显示红色「生成失败」气泡（无消息提示）', (tester) async {
      final bookDao = FakeBookDao();
      final dao = FakeRoundDao();
      final ai = ToggleAiService()..fail = true;
      final roundProvider = await pumpChatScreen(
        tester,
        ai: ai,
        bookDao: bookDao,
        roundDao: dao,
      );

      final sendFuture = roundProvider.sendRound(userInput: '触发失败', book: book);
      await waitSendDone(tester, roundProvider);

      expect(await sendFuture, isFalse);
      // 失败条目落库：用户输入 + 失败原因；rounds 表无新增轮次。
      expect(bookDao.failed.userInput, '触发失败');
      expect(bookDao.failed.errorMessage, contains('模拟失败'));
      expect(bookDao.failed.isTruncated, isFalse);
      expect(dao.rounds.where((r) => r.roundIndex > 0), isEmpty);
      // UI：用户输入气泡 + 红框标题 + 失败原因。
      expect(find.text('触发失败'), findsOneWidget);
      expect(find.text('生成失败'), findsOneWidget);
      expect(find.text('模拟失败'), findsOneWidget);
      // 无 SnackBar 消息提示。
      expect(find.textContaining('请求失败：'), findsNothing);
    });

    testWidgets('停止生成：保留用户输入并显示红色「已截断」', (tester) async {
      final bookDao = FakeBookDao();
      final dao = FakeRoundDao();
      final ai = FakeStreamingAiService();
      final roundProvider = await pumpChatScreen(
        tester,
        ai: ai,
        bookDao: bookDao,
        roundDao: dao,
      );

      final sendFuture = roundProvider.sendRound(userInput: '请继续剧情', book: book);
      await tester.pump();
      ai.emit('部分剧情内容');
      await tester.pump();

      roundProvider.cancelGeneration();
      ai.complete();
      await waitSendDone(tester, roundProvider);

      expect(await sendFuture, isFalse);
      // 失败条目：用户输入 + 空错误信息（=已截断）。
      expect(bookDao.failed.userInput, '请继续剧情');
      expect(bookDao.failed.errorMessage, isEmpty);
      expect(bookDao.failed.isTruncated, isTrue);
      // UI：用户输入气泡 + 「已截断」红框（无「生成失败」）。
      expect(find.text('请继续剧情'), findsOneWidget);
      expect(find.text('已截断'), findsOneWidget);
      expect(find.text('生成失败'), findsNothing);
    });

    testWidgets('失败后发送新消息：清空失败条目并正常生成', (tester) async {
      final bookDao = FakeBookDao();
      final dao = FakeRoundDao();
      final ai = ToggleAiService();
      final roundProvider = await pumpChatScreen(
        tester,
        ai: ai,
        bookDao: bookDao,
        roundDao: dao,
      );

      // 第一次请求失败。
      ai.fail = true;
      var f = roundProvider.sendRound(userInput: '失败的输入', book: book);
      await waitSendDone(tester, roundProvider);
      expect(await f, isFalse);
      expect(find.text('生成失败'), findsOneWidget);

      // 发送新消息（不再失败）。
      ai.fail = false;
      f = roundProvider.sendRound(userInput: '新的输入', book: book);
      await waitSendDone(tester, roundProvider);
      expect(await f, isTrue);

      // 失败条目已清空，红框消失；新轮正常落库（编号 1）。
      expect(bookDao.failed.isEmpty, isTrue);
      expect(find.text('生成失败'), findsNothing);
      expect(find.text('新的输入'), findsOneWidget);
      expect(find.textContaining('成功正文'), findsOneWidget);
      final chat = dao.rounds.where((r) => r.roundIndex > 0).toList();
      expect(chat, hasLength(1));
      expect(chat.single.roundIndex, 1);
      expect(chat.single.aiNarrative, contains('成功正文'));
    });

    testWidgets('正常完成生成：无失败条目、无红框', (tester) async {
      final bookDao = FakeBookDao();
      final dao = FakeRoundDao();
      final roundProvider = await pumpChatScreen(
        tester,
        ai: ToggleAiService(),
        bookDao: bookDao,
        roundDao: dao,
      );

      final sendFuture = roundProvider.sendRound(userInput: '正常剧情', book: book);
      await waitSendDone(tester, roundProvider);

      expect(await sendFuture, isTrue);
      expect(bookDao.failed.isEmpty, isTrue);
      expect(find.text('已截断'), findsNothing);
      expect(find.text('生成失败'), findsNothing);
    });
  });
}
