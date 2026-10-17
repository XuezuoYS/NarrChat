import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/ai_platform.dart';
import '../models/api_type.dart';

/// 「获取可用模型」读到的单个候选模型（尚未写入配置）。
///
/// 只有接口真的返回了某项能力信息时对应字段才非空；null 表示
/// 「接口没说」，导入时由 [toAiModel] 回落到内置默认值。
class DiscoveredModel {
  /// 发往 API 的模型名（列表内唯一）。
  final String id;

  /// 接口给出的展示名；缺省回退 [id]。
  final String name;

  /// 最大输出 Tokens（接口未提供时为 null）。
  final int? maxTokens;

  /// 是否支持思考（接口未提供时为 null）。
  final bool? supportsThinking;

  /// 是否支持识图 / 图片传入（接口未提供时为 null）。
  final bool? supportsVision;

  /// 推理强度可选档位（接口未提供时为 null）。
  final List<String>? reasoningEffortOptions;

  const DiscoveredModel({
    required this.id,
    this.name = '',
    this.maxTokens,
    this.supportsThinking,
    this.supportsVision,
    this.reasoningEffortOptions,
  });

  /// 转为可写入配置的模型：接口未提供的字段一律走 [AiModel] 的默认值。
  AiModel toAiModel() => AiModel(
    id: id,
    maxTokens: maxTokens,
    supportsThinking: supportsThinking ?? true,
    supportsVision: supportsVision ?? false,
    reasoningEffortOptions: reasoningEffortOptions ?? const [],
  );
}

/// 「获取可用模型」失败的类别（决定提示文案的组织方式）。
enum ModelDiscoveryErrorKind {
  /// 网络不可达 / 超时。
  network,

  /// 接口返回非 2xx 状态码。
  httpStatus,

  /// 响应体不是 JSON。
  notJson,

  /// 响应体不是可识别的模型列表形态。
  unexpectedShape,

  /// 列表为空（或全部条目都缺模型名）。
  empty,

  /// 响应体超过大小上限。
  tooLarge,

  /// 当前接入协议不支持查询模型列表。
  unsupported,
}

/// 「获取可用模型」失败：携带失败码（HTTP 状态码 / 类别）与响应体，
/// 供悬浮通知完整展示与复制反馈。
class ModelDiscoveryException implements Exception {
  final ModelDiscoveryErrorKind kind;

  /// 面向用户的简短说明（不含响应体）。
  final String message;

  /// HTTP 状态码（仅 [ModelDiscoveryErrorKind.httpStatus] 时非空）。
  final int? statusCode;

  /// 响应体（已按 [ModelDiscoveryService.noticeBodyLimit] 截断）；无响应体时为 null。
  final String? body;

  const ModelDiscoveryException(
    this.kind,
    this.message, {
    this.statusCode,
    this.body,
  });

  /// 悬浮通知文案：失败码 + 说明 + 响应体。
  String describe() {
    final buffer = StringBuffer('获取可用模型失败');
    final code = statusCode;
    if (code != null) {
      buffer.write('（HTTP $code）');
    } else {
      buffer.write('（$_kindLabel）');
    }
    buffer.write('：$message');
    final raw = body?.trim();
    if (raw != null && raw.isNotEmpty) {
      buffer.write('\n响应：$raw');
    }
    return buffer.toString();
  }

  String get _kindLabel => switch (kind) {
    ModelDiscoveryErrorKind.network => '网络错误',
    ModelDiscoveryErrorKind.httpStatus => 'HTTP 错误',
    ModelDiscoveryErrorKind.notJson => '响应不是 JSON',
    ModelDiscoveryErrorKind.unexpectedShape => '响应格式无法识别',
    ModelDiscoveryErrorKind.empty => '没有可用模型',
    ModelDiscoveryErrorKind.tooLarge => '响应过大',
    ModelDiscoveryErrorKind.unsupported => '协议不支持',
  };

  @override
  String toString() => describe();
}

/// 「获取可用模型」服务：`GET {baseUrl}/models` 读取平台公开的模型列表。
///
/// 参考 DeepSeek Harness 的模型发现（`dsh-llm-pi-ai/discovery`）：
/// - OpenAI 系协议以 `Authorization: Bearer <key>` 查询 `{baseUrl}/models`，
///   地址按前缀拼接（`baseUrl` 自带的路径段原样保留）；
/// - 成功响应可为标准 `{"data": [...]}`，也兼容网关增强的 `{"models": {...}}`
///   （以对象键作为模型名）；
/// - 缺模型名的单条记录直接跳过，不因一行坏数据丢掉整份列表；
/// - 接口给出的能力字段（思考 / 识图 / 强度档位 / 最大 Tokens）按需读取，
///   没有就留空，导入时回落默认值。
class ModelDiscoveryService {
  ModelDiscoveryService({http.Client? client, Duration? timeout})
    : _client = client ?? http.Client(),
      _timeout = timeout ?? const Duration(seconds: 30);

  final http.Client _client;
  final Duration _timeout;

  /// 响应体大小上限：模型列表通常只有几十 KB，超过该值直接判失败。
  static const int maxResponseBytes = 4 * 1024 * 1024;

  /// 悬浮通知里响应体的截断长度（超长 body 只显示开头，避免撑爆提示）。
  static const int noticeBodyLimit = 800;

  /// 查询 [baseUrl] 平台的可用模型（按接口返回顺序、按模型名去重）。
  ///
  /// [apiKey] 为空时不带鉴权头（允许探测无需鉴权的网关）。
  Future<List<DiscoveredModel>> fetchModels({
    required String baseUrl,
    required ApiType apiType,
    String apiKey = '',
  }) async {
    if (!apiType.supportsModelListing) {
      throw const ModelDiscoveryException(
        ModelDiscoveryErrorKind.unsupported,
        '当前接入协议不支持查询模型列表，请手动添加模型',
      );
    }
    final base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (base.isEmpty) {
      throw ArgumentError.value(baseUrl, 'baseUrl', '接口地址（Base URL）不能为空');
    }
    final url = '$base/models';
    final headers = <String, String>{'accept': 'application/json'};
    final key = apiKey.trim();
    if (key.isNotEmpty) headers['authorization'] = 'Bearer $key';

    final http.Response response;
    try {
      response = await _client
          .get(Uri.parse(url), headers: headers)
          .timeout(_timeout);
    } on TimeoutException {
      throw ModelDiscoveryException(
        ModelDiscoveryErrorKind.network,
        '$url 请求超时（${_timeout.inSeconds} 秒）',
      );
    } on http.ClientException catch (e) {
      throw ModelDiscoveryException(
        ModelDiscoveryErrorKind.network,
        '无法连接 $url：${e.message}',
      );
    } on Exception catch (e) {
      throw ModelDiscoveryException(
        ModelDiscoveryErrorKind.network,
        '无法访问 $url：$e',
      );
    }

    final text = _readBody(url, response);
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      throw ModelDiscoveryException(
        ModelDiscoveryErrorKind.notJson,
        '$url 返回的内容不是 JSON',
        body: _clip(text),
      );
    }
    final models = parseModelListing(json);
    if (models.isEmpty) {
      throw ModelDiscoveryException(
        ModelDiscoveryErrorKind.empty,
        '$url 没有返回可用的模型',
        body: _clip(text),
      );
    }
    return models;
  }

  /// 校验状态码与大小，返回解码后的响应文本（按 UTF-8 解码，兼容中文模型名）。
  String _readBody(String url, http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ModelDiscoveryException(
        ModelDiscoveryErrorKind.httpStatus,
        '$url 返回 HTTP ${response.statusCode}'
            '${response.statusCode == 401 || response.statusCode == 403 ? '（请检查 API Key）' : ''}',
        statusCode: response.statusCode,
        body: _clip(_decode(response)),
      );
    }
    if (response.bodyBytes.length > maxResponseBytes) {
      throw ModelDiscoveryException(
        ModelDiscoveryErrorKind.tooLarge,
        '$url 的响应超过 ${maxResponseBytes ~/ (1024 * 1024)} MB',
      );
    }
    return _decode(response);
  }

  static String _decode(http.Response response) {
    try {
      return utf8.decode(response.bodyBytes);
    } on FormatException {
      return response.body; // 非 UTF-8 时退回 http 自带的解码结果
    }
  }

  String? _clip(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.length <= noticeBodyLimit) return trimmed;
    return '${trimmed.substring(0, noticeBodyLimit)}…（已截断）';
  }

  /// 解析模型列表响应：`data` 数组优先，其次兼容 `models` 映射（对象形态的
  /// 网关增强列表，键即模型名）；无法识别的形态抛 [ModelDiscoveryException]。
  static List<DiscoveredModel> parseModelListing(Object? json) {
    final map = json is Map ? json : null;
    if (map == null) {
      throw const ModelDiscoveryException(
        ModelDiscoveryErrorKind.unexpectedShape,
        '响应既不是 data 数组，也不是 models 对象',
      );
    }
    final models = <DiscoveredModel>[];
    final seen = <String>{};
    void add(String? rawId, Map entry) {
      final modelId = rawId?.trim() ?? '';
      if (modelId.isEmpty || !seen.add(modelId)) return;
      models.add(
        DiscoveredModel(
          id: modelId,
          name:
              _stringOf(entry, const ['name', 'display_name', 'displayName']) ??
              modelId,
          maxTokens: _maxTokensOf(entry),
          supportsThinking: _thinkingOf(entry),
          supportsVision: _visionOf(entry),
          reasoningEffortOptions: _reasoningEffortsOf(entry),
        ),
      );
    }

    final data = map['data'];
    if (data is List) {
      for (final item in data) {
        if (item is! Map) continue;
        add(_stringOf(item, const ['id']), item);
      }
    } else {
      final enriched = map['models'];
      if (enriched is! Map) {
        throw const ModelDiscoveryException(
          ModelDiscoveryErrorKind.unexpectedShape,
          '响应既不是 data 数组，也不是 models 对象',
        );
      }
      for (final entry in enriched.entries) {
        final value = entry.value;
        if (value is! Map) continue; // 目录元数据等非模型条目
        final key = entry.key;
        add(
          key is String ? key : _stringOf(value, const ['id']),
          value,
        );
      }
    }
    return models;
  }

  /// 读取字符串字段（去首尾空白；空串视为未提供）。
  static String? _stringOf(Map entry, List<String> keys) {
    for (final key in keys) {
      final value = entry[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
    }
    return null;
  }

  /// 正整数（整数或整数值的浮点数），其余视为未提供。
  static int? _positiveInt(Object? value) {
    if (value is int && value > 0) return value;
    if (value is double && value > 0 && value == value.truncateToDouble()) {
      return value.toInt();
    }
    return null;
  }

  /// 最大输出 Tokens：兼容 OpenAI / OpenRouter / 常见网关的几种拼法。
  static int? _maxTokensOf(Map entry) {
    final limit = entry['limit'];
    final topProvider = entry['top_provider'];
    final candidates = <Object?>[
      entry['maxOutputTokens'],
      entry['max_output_tokens'],
      entry['maxTokens'],
      entry['max_tokens'],
      if (limit is Map) limit['output'],
      if (topProvider is Map) topProvider['max_completion_tokens'],
    ];
    for (final candidate in candidates) {
      final value = _positiveInt(candidate);
      if (value != null) return value;
    }
    return null;
  }

  /// 是否支持思考：优先读显式布尔字段；否则看 `supported_parameters`
  /// 是否列出思考相关参数（OpenRouter 风格）；都没有则视为「未提供」。
  static bool? _thinkingOf(Map entry) {
    for (final key in const ['supports_thinking', 'supportsThinking']) {
      final value = entry[key];
      if (value is bool) return value;
    }
    final supported = entry['supported_parameters'];
    if (supported is List) {
      return supported.whereType<String>().any(_isThinkingParam);
    }
    final reasoning = entry['reasoning'];
    if (reasoning is Map) {
      final flag = reasoning['supported'];
      if (flag is bool) return flag;
      final efforts = reasoning['efforts'];
      if (efforts is List && efforts.isNotEmpty) return true;
    }
    return null;
  }

  static bool _isThinkingParam(String name) {
    final lower = name.toLowerCase();
    return lower == 'reasoning' ||
        lower == 'reasoning_effort' ||
        lower == 'include_reasoning' ||
        lower == 'thinking';
  }

  /// 是否支持图片传入：优先读显式布尔字段；否则看输入模态里有没有 image。
  static bool? _visionOf(Map entry) {
    for (final key in const ['supports_vision', 'supportsVision']) {
      final value = entry[key];
      if (value is bool) return value;
    }
    // OpenRouter：architecture.input_modalities；部分网关：input_modalities。
    final architecture = entry['architecture'];
    final modalities = entry['modalities'];
    final candidates = <Object?>[
      if (architecture is Map) architecture['input_modalities'],
      entry['input_modalities'],
      entry['inputModalities'],
      if (modalities is Map) modalities['input'],
    ];
    for (final candidate in candidates) {
      if (candidate is! List) continue;
      final names = candidate
          .whereType<String>()
          .map((name) => name.toLowerCase())
          .toList();
      if (names.isEmpty) continue;
      return names.contains('image');
    }
    return null;
  }

  /// 推理强度档位：支持 `reasoning_effort_options` 数组与目录形态的
  /// `reasoning.efforts`（字符串数组或 `{id: ...}` 数组）。
  static List<String>? _reasoningEffortsOf(Map entry) {
    final reasoning = entry['reasoning'];
    final candidates = <Object?>[
      entry['reasoning_effort_options'],
      entry['reasoningEffortOptions'],
      if (reasoning is Map) reasoning['efforts'],
      if (reasoning is Map) reasoning['effort_options'],
    ];
    for (final candidate in candidates) {
      if (candidate is! List || candidate.isEmpty) continue;
      final values = <String>[];
      for (final item in candidate) {
        if (item is String) {
          values.add(item);
        } else if (item is Map) {
          final id = item['id'];
          if (id is String) values.add(id);
        }
      }
      final parsed = AiModel.parseReasoningEffortOptions(values.join(','));
      if (parsed.isNotEmpty) return parsed;
    }
    return null;
  }
}
