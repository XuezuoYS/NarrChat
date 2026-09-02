import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/ai_service.dart';
import 'package:narrchat/services/non_stream_replay.dart';

/// NonStreamReplayer：非流式响应 → 合成流式块（思考 → 工具预览 → 正文 → done）。
void main() {
  const result = AiCallResult(
    content: '## 剧情演绎\n正文',
    reasoningContent: '先想一想',
    toolCalls: [
      AiToolCall(id: 'fc_1', name: 'narrchat_webSearch', arguments: {
        'query': '洛天依',
      }),
    ],
    promptTokens: 1,
    completionTokens: 1,
  );

  test('回放顺序：思考 → 工具预览 → 正文 → done，内容逐块拼接无丢失', () async {
    final replayer = const NonStreamReplayer(
      tickInterval: Duration.zero,
      charsPerTick: 2,
    );
    final chunks = <AiStreamChunk>[];
    await replayer.replay(
      result,
      emit: chunks.add,
      isStopped: () => false,
      emitToolPreviews: true,
    );

    expect(chunks.last.done, isTrue);
    expect(chunks.where((c) => !c.done), hasLength(greaterThan(4)));

    // 思考块：先于工具与正文到达，内容完整拼接。
    var reasoning = '';
    for (final c in chunks) {
      reasoning += c.reasoningDelta;
    }
    expect(reasoning, result.reasoningContent);

    // 工具预览块：同一个 callId 生成「创建 + 参数」两块。
    final previews = chunks
        .where((c) => c.toolCallId == 'fc_1')
        .toList();
    expect(previews, hasLength(2));
    expect(previews.first.toolName, 'narrchat_webSearch');
    expect(previews.last.toolArgsDelta, contains('洛天依'));

    // 正文块：内容完整拼接。
    var content = '';
    for (final c in chunks) {
      content += c.contentDelta;
    }
    expect(content, result.content);

    // 顺序：思考最先，done 最后。
    final firstIdx = chunks.indexWhere((c) => c.reasoningDelta.isNotEmpty);
    final toolIdx = chunks.indexWhere((c) => c.toolCallId != null);
    final contentIdx = chunks.indexWhere((c) => c.contentDelta.isNotEmpty);
    expect(firstIdx, 0);
    expect(toolIdx, lessThan(contentIdx));
  });

  test('回放工具预览关闭：不发出工具块（Chat 搜索循环由活动回调承载）', () async {
    final replayer = const NonStreamReplayer(
      tickInterval: Duration.zero,
      charsPerTick: 100,
    );
    final chunks = <AiStreamChunk>[];
    await replayer.replay(
      result,
      emit: chunks.add,
      isStopped: () => false,
      emitToolPreviews: false,
    );
    expect(chunks.where((c) => c.toolCallId != null), isEmpty);
    expect(chunks.where((c) => c.reasoningDelta.isNotEmpty), hasLength(1));
    expect(chunks.last.done, isTrue);
  });

  test('回放中途停止：立即终止，不再发出 done', () async {
    final replayer = NonStreamReplayer(
      tickInterval: const Duration(milliseconds: 10),
      charsPerTick: 1,
    );
    final chunks = <AiStreamChunk>[];
    var stops = 0;
    await replayer.replay(
      result,
      emit: chunks.add,
      isStopped: () => ++stops > 2,
    );
    expect(chunks, isNotEmpty);
    expect(chunks.length, lessThan(10), reason: '应在若干 tick 后停止');
    expect(chunks.any((c) => c.done), isFalse, reason: '停止后不得发出 done');
  });

  test('空响应：仅发出 done', () async {
    final replayer = const NonStreamReplayer();
    final chunks = <AiStreamChunk>[];
    await replayer.replay(
      const AiCallResult(content: '', promptTokens: 0, completionTokens: 0),
      emit: chunks.add,
      isStopped: () => false,
    );
    expect(chunks, hasLength(1));
    expect(chunks.single.done, isTrue);
  });
}
