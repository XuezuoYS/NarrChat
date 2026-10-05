import 'dart:convert';

/// 一帧「会发出 / 可能发出」的请求骨架。
///
/// 由各执行器给出（[AgentRunner.outlineFrames] / [AgentRoundRunner.outlineFrames]）：
/// **首帧与实发逐字节一致**（同一条组装路径），后续帧是「可能发出」的候选，
/// 是否真的发出取决于模型响应与工具返回，故只作为参考列出。
class RequestFrameOutline {
  const RequestFrameOutline({
    required this.label,
    required this.note,
    required this.body,
  });

  /// 稳定名标（如「准备帧」「工具循环续接帧」）；用于展示与排序。
  final String label;

  /// 何时会发出这一帧 / 内容依赖什么（一行说明）。
  final String note;

  /// 完整请求体。
  final Map<String, dynamic> body;
}

/// 预览里的一个「后续可用帧」：只保留**相对上一帧的增量**。
class PlannedFrame {
  const PlannedFrame({
    required this.label,
    required this.note,
    required this.addedFields,
    this.removedFields = const [],
  });

  /// 稳定名标（同 [RequestFrameOutline.label]）。
  final String label;

  /// 何时会发出这一帧（同 [RequestFrameOutline.note]）。
  final String note;

  /// 本帧相对上一帧**新增 / 变化**的字段。
  ///
  /// 数组字段（`messages` / `input`）若满足「上一帧是它的前缀」（会话累积的常态），
  /// 只保留追加的那几项，表示为 `{"…": "前 N 项同上一帧", "+": [追加项…]}`——
  /// 否则每个后续帧都会把整段历史重抄一遍。
  final Map<String, dynamic> addedFields;

  /// 本帧相对上一帧**省略**的字段名（有状态续接帧不再重发 `instructions` / `tools`）。
  final List<String> removedFields;

  /// 展示文本：`{"追加": …, "省略": […]}`（省略为空时不出现 `省略`）。
  String get diffJson => const JsonEncoder.withIndent('  ').convert({
        '追加': addedFields,
        if (removedFields.isNotEmpty) '省略': removedFields,
      });
}

/// 一次「若此刻点击发送」的请求预演结果。
///
/// [firstFrame] = 实发首帧请求体（与真实发出的报文逐字节一致）；
/// [subsequentFrames] = 后续**可能**发出的帧（仅增量字段，可能一帧不发）。
class RoundRequestPreview {
  const RoundRequestPreview({
    required this.firstFrame,
    this.subsequentFrames = const [],
  });

  /// 只有一帧的路径（直发：chat / responses，无工具循环）。
  const RoundRequestPreview.single({required Map<String, dynamic> firstFrame})
      : this(firstFrame: firstFrame);

  /// 由执行器给出的帧骨架序列构造（首帧必须是真实首帧）。
  factory RoundRequestPreview.fromOutline(List<RequestFrameOutline> frames) {
    if (frames.isEmpty) {
      throw ArgumentError('帧骨架序列不能为空');
    }
    final subsequent = <PlannedFrame>[];
    for (var i = 1; i < frames.length; i++) {
      final delta = diffFrameFields(frames[i - 1].body, frames[i].body);
      subsequent.add(
        PlannedFrame(
          label: frames[i].label,
          note: frames[i].note,
          addedFields: delta.added,
          removedFields: delta.removed,
        ),
      );
    }
    return RoundRequestPreview(
      firstFrame: frames.first.body,
      subsequentFrames: subsequent,
    );
  }

  /// 实发首帧请求体。
  final Map<String, dynamic> firstFrame;

  /// 后续可用帧（可能为空 = 本轮只有一帧）。
  final List<PlannedFrame> subsequentFrames;

  /// 首帧 JSON 文本（与 RAW 记录同款 pretty 格式）。
  String get firstFrameJson => const JsonEncoder.withIndent('  ').convert(
        firstFrame,
      );

  /// 是否有后续帧可展示。
  bool get hasSubsequentFrames => subsequentFrames.isNotEmpty;
}

/// 求 [next] 相对 [base] 的增量：新增 / 变化的字段 + 被省略的字段名。
///
/// - 值完全相同的字段不进 [added]（后续帧只展示「本帧追加的字段」）；
/// - 数组字段满足「[base] 的值是它的前缀」时，只保留追加项，值形态为
///   `{"…": "前 N 项同上一帧", "+": [追加项…]}`。
({Map<String, dynamic> added, List<String> removed}) diffFrameFields(
  Map<String, dynamic> base,
  Map<String, dynamic> next,
) {
  final added = <String, dynamic>{};
  for (final entry in next.entries) {
    if (!base.containsKey(entry.key)) {
      added[entry.key] = entry.value;
      continue;
    }
    final previous = base[entry.key];
    if (_deepEquals(previous, entry.value)) continue;
    added[entry.key] = _listTail(previous, entry.value) ?? entry.value;
  }
  final removed = [
    for (final key in base.keys)
      if (!next.containsKey(key)) key,
  ];
  return (added: added, removed: removed);
}

/// 数组前缀差：`previous` 是 `next` 的前缀时返回追加项的展示形态，否则 null。
Object? _listTail(Object? previous, Object? next) {
  if (previous is! List || next is! List || previous.length > next.length) {
    return null;
  }
  for (var i = 0; i < previous.length; i++) {
    if (!_deepEquals(previous[i], next[i])) return null;
  }
  if (previous.isEmpty) return null;
  return {
    '…': '前 ${previous.length} 项同上一帧',
    '+': next.sublist(previous.length),
  };
}

/// 深比较（Map / List / 标量）；JSON 兼容取值，够用且无外部依赖。
bool _deepEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || !_deepEquals(a[key], b[key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_deepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}
