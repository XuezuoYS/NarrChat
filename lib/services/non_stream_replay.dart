import 'dart:convert';

import 'ai_service.dart';

/// 非流式响应的「展示回放」器。
///
/// 非流式传输无法获得实时增量，但 Agent / 联网搜索等多轮场景下用户需要
/// 「按 AI 轮次看到每个块、工具执行过程 → 结果」的体验。本类把一次性返回的
/// [AiCallResult] 切成合成流式块（思考 → 工具调用预览 → 正文 → done），
/// 按固定节奏送达回调，驱动与流式完全相同的块时间线展示——
/// 只影响展示，不改变请求语义（请求体仍为 `stream: false`）。
class NonStreamReplayer {
  const NonStreamReplayer({
    this.tickInterval = const Duration(milliseconds: 24),
    this.charsPerTick = 6,
  });

  /// 相邻合成块之间的间隔（约 6 字符 / 24ms ≈ 250 字/秒）。
  final Duration tickInterval;

  /// 每个合成块携带的字符数（思考 / 正文按此粒度切分）。
  final int charsPerTick;

  /// 回放一次非流式响应（顺序与流式一致）：
  /// [result.reasoningContent] →（[emitToolPreviews] 时）各工具调用预览 →
  /// [result.content] → done。
  ///
  /// [emitToolPreviews] 仅在 AGENT 模式（Responses 线路）下开启——其工具
  /// 事件由流式预览 / 开始 / 完成统一承载；Chat 线路（含 Chat 协议的
  /// AGENT / 搜索循环）的工具事件由活动回调创建（非流式下仍实时发生），
  /// 开启会造成「联网搜索框 + Tool 框」双框。
  ///
  /// [isStopped] 为 true 时立即终止回放（用户取消 / 生成令牌过期），
  /// 不再发出剩余内容（调用方随后按取消语义收尾）。
  Future<void> replay(
    AiCallResult result, {
    required void Function(AiStreamChunk chunk) emit,
    required bool Function() isStopped,
    bool emitToolPreviews = false,
  }) async {
    if (isStopped()) return;
    await _replayText(
      result.reasoningContent,
      (delta) => emit(AiStreamChunk(reasoningDelta: delta)),
      isStopped,
    );
    if (isStopped()) return;
    if (emitToolPreviews) {
      for (final tc in result.toolCalls) {
        if (isStopped()) return;
        emit(AiStreamChunk(toolCallId: tc.id, toolName: tc.name));
        emit(
          AiStreamChunk(
            toolCallId: tc.id,
            toolArgsDelta: jsonEncode(tc.arguments),
          ),
        );
      }
    }
    await _replayText(
      result.content,
      (delta) => emit(AiStreamChunk(contentDelta: delta)),
      isStopped,
    );
    if (isStopped()) return;
    emit(const AiStreamChunk(done: true));
  }

  /// 把 [text] 按 [charsPerTick] 粒度切分为增量块并按节奏送达 [emit]。
  Future<void> _replayText(
    String text,
    void Function(String delta) emit,
    bool Function() isStopped,
  ) async {
    if (text.isEmpty) return;
    var offset = 0;
    while (offset < text.length) {
      if (isStopped()) return;
      final end = (offset + charsPerTick).clamp(0, text.length);
      emit(text.substring(offset, end));
      offset = end;
      if (offset < text.length && tickInterval > Duration.zero) {
        await Future<void>.delayed(tickInterval);
      }
    }
  }
}
