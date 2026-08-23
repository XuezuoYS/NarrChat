import 'package:flutter/widgets.dart';

import '../config/ai_platforms.dart';
import '../models/ai_platform.dart';
import '../models/api_type.dart';
import '../providers/ai_settings_provider.dart';
import '../providers/cloud_sync_provider.dart';
import '../services/ai_request_body_builder.dart';

/// 设置页全量表单状态（API 设置 + 云同步）。
///
/// 由 [SettingsScreen] 持有并注入各面板：面板切换时表单状态不丢失，
/// 右上角「保存」按钮可任意时机统一校验并落库（类似书籍设置的机制）；
/// 保存成功后不退出设置页，仅弹出成功/失败提示。
///
/// AI 编辑采用「工作副本」：[_working] 为平台/模型列表的不可变快照，
/// 每次编辑以 `copyWith` 替换，保证输入不互相污染。平台级文本（名称/Base URL）
/// 用控制器承载，通过 [onChanged] 同步回工作副本；模型参数由各模型自己的
/// 展开编辑器（`ai_settings_form` 内的 `_ModelSettingsEditor`）就地编辑，并
/// 通过 [updateModel] 写回工作副本。API Key 单独存于控制器（不进入 [AiPlatform]）。
///
/// 本页只做「按平台 + 按模型编辑参数」，**不**在此选择对话所用的模型/平台
/// （对话目标仍由 [AiSettingsProvider.selectedPlatformId] /
/// [selectedModelId] 决定，保存时保持不变）。
class SettingsFormState extends ChangeNotifier {
  SettingsFormState({
    required AiSettingsProvider ai,
    required CloudSyncProvider sync,
  })  : _ai = ai,
        _sync = sync,
        _working = List.of(ai.platforms),
        webdavUrl = TextEditingController(text: sync.webdavUrl),
        webdavUsername = TextEditingController(text: sync.webdavUsername),
        webdavPassword = TextEditingController(text: sync.webdavPassword),
        webdavFolder = TextEditingController(text: sync.folder),
        webdavUserName = TextEditingController(text: sync.userName),
        webdavKeepVersions = TextEditingController(text: '${sync.keepVersions}'),
        autoUpload = sync.autoUpload {
    for (final p in _working) {
      _ensurePlatformControllers(p.id);
    }
  }

  final AiSettingsProvider _ai;
  final CloudSyncProvider _sync;

  // ---------------------------------------------------------------------------
  // AI 工作副本状态
  // ---------------------------------------------------------------------------
  List<AiPlatform> _working;

  // 平台级文本控制器（keyed by platform id）。
  final Map<String, TextEditingController> _platformNameCtrls = {};
  final Map<String, TextEditingController> _baseUrlCtrls = {};
  final Map<String, TextEditingController> _apiKeyCtrls = {};

  // ---------------------------------------------------------------------------
  // 云同步
  // ---------------------------------------------------------------------------
  final TextEditingController webdavUrl;
  final TextEditingController webdavUsername;
  final TextEditingController webdavPassword;
  final TextEditingController webdavFolder;
  final TextEditingController webdavUserName;
  final TextEditingController webdavKeepVersions;
  bool autoUpload;
  bool obscurePassword = true;

  // ---------------------------------------------------------------------------
  // 派生：API 设置
  // ---------------------------------------------------------------------------
  List<AiPlatform> get platforms => _working;

  /// 单张图片大小上限（MB，默认 16，可在设置中调整）。
  int get maxImageSizeMB => _ai.maxImageSizeMB;

  /// 更新单张图片大小上限（MB）并持久化。
  void setMaxImageSizeMB(int mb) => _ai.setMaxImageSizeMB(mb);

  TextEditingController nameCtrlFor(String platformId) =>
      _platformNameCtrls[platformId]!;
  TextEditingController baseUrlCtrlFor(String platformId) =>
      _baseUrlCtrls[platformId]!;
  TextEditingController apiKeyCtrlFor(String platformId) =>
      _apiKeyCtrls[platformId]!;

  // ---------------------------------------------------------------------------
  // 平台编辑
  // ---------------------------------------------------------------------------
  void setPlatformName(String id, String value) {
    _replacePlatform(id, (p) => p.copyWith(displayName: value));
  }

  void setPlatformBaseUrl(String id, String value) {
    _replacePlatform(id, (p) => p.copyWith(baseUrl: value.trim()));
  }

  /// 新增自定义平台（初始无模型，需在界面添加至少一个；保存前会校验）。
  void addPlatform({required String name, required String baseUrl}) {
    final id = 'custom_${DateTime.now().microsecondsSinceEpoch}';
    final platform = AiPlatform(
      id: id,
      displayName: name.trim(),
      apiType: ApiType.openAiCompatible,
      baseUrl: baseUrl.trim(),
      models: const [],
    );
    _working = [..._working, platform];
    _ensurePlatformControllers(id);
    notifyListeners();
  }

  /// 删除平台（内置默认平台与最后一个平台不可删）。
  void removePlatform(String id) {
    if (_working.length <= 1) return;
    if (id == AiPlatforms.defaultPlatformId) return;
    final platform = _working.firstWhere((p) => p.id == id, orElse: () => _working.first);
    if (platform.isBuiltin) return;
    _working = _working.where((p) => p.id != id).toList();
    _disposePlatformControllers(id);
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // 模型编辑（每个模型独立展开编辑）
  // ---------------------------------------------------------------------------
  /// 添加模型（内置默认平台的模型由预置固定，不可新增）。
  void addModel(String platformId, {required String id, String shortLabel = ''}) {
    if (id.trim().isEmpty) return;
    final index = _working.indexWhere((p) => p.id == platformId);
    if (index < 0) return;
    final platform = _working[index];
    if (platform.isBuiltin) return;
    if (platform.models.any((m) => m.id == id.trim())) return;
    final model = AiModel(id: id.trim(), shortLabel: shortLabel.trim());
    _working = [..._working];
    _working[index] = platform.copyWith(models: [...platform.models, model]);
    notifyListeners();
  }

  /// 删除模型（内置默认平台的模型不可删；每个平台至少保留一个模型）。
  void removeModel(String platformId, String modelId) {
    final index = _working.indexWhere((p) => p.id == platformId);
    if (index < 0) return;
    final platform = _working[index];
    if (platform.isBuiltin) return;
    if (platform.models.length <= 1) return;
    _working = [..._working];
    _working[index] = platform.copyWith(
      models: platform.models.where((m) => m.id != modelId).toList(),
    );
    notifyListeners();
  }

  /// 用编辑后的模型替换工作副本中的同名模型（用于模型展开编辑器写回）。
  void updateModel(String platformId, String modelId, AiModel model) {
    final index = _working.indexWhere((p) => p.id == platformId);
    if (index < 0) return;
    final platform = _working[index];
    final modelIndex = platform.models.indexWhere((m) => m.id == modelId);
    if (modelIndex < 0) return;
    final newModels = [...platform.models];
    newModels[modelIndex] = model;
    _working = [..._working];
    _working[index] = platform.copyWith(models: newModels);
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // 统一保存
  // ---------------------------------------------------------------------------
  Future<SettingsSaveResult> saveAll() async {
    final errors = <String>[];
    final notes = <String>[];

    // —— 校验（不落库）——
    if (_working.isEmpty) {
      errors.add('API 设置：至少需要保留一个平台');
    }
    for (var i = 0; i < _working.length; i++) {
      final p = _working[i];
      if (p.displayName.trim().isEmpty) {
        errors.add('API 设置：平台「${p.displayName}」名称不能为空');
      }
      if (p.models.isEmpty) {
        errors.add('API 设置：平台「${_displayPlatformName(p)}」至少需要一个模型');
        continue;
      }
      for (final m in p.models) {
        if (m.id.trim().isEmpty) {
          errors.add('API 设置：模型名称不能为空');
        }
        if (m.maxTokens != null && m.maxTokens! <= 0) {
          errors.add('API 设置（${_displayPlatformName(p)}/${m.id}）：最大输出 Tokens 需为正整数或留空');
        }
        final template = m.requestTemplate;
        if (template != null && template.trim().isNotEmpty) {
          try {
            AiRequestBodyBuilder.validateCustomTemplate(template);
          } on FormatException catch (e) {
            errors.add('API 设置（${_displayPlatformName(p)}/${m.id}）：${e.message}');
          }
        }
      }
    }
    if (errors.isNotEmpty) return SettingsSaveResult(errors: errors);

    final keep = int.tryParse(webdavKeepVersions.text.trim());
    if (keep == null || keep < 1 || keep > 99) {
      errors.add('云同步：保留历史版本需为 1 ~ 99 的整数');
    }
    if (errors.isNotEmpty) return SettingsSaveResult(errors: errors);

    final syncUrl = webdavUrl.text.trim();
    final syncUsername = webdavUsername.text.trim();
    final syncConfigured = syncUrl.isNotEmpty && syncUsername.isNotEmpty;

    // 组装各平台 API Key（平台 id → 控制器文本）。
    final apiKeys = <String, String>{
      for (final p in _working)
        p.id: (_apiKeyCtrls[p.id]?.text ?? '').trim(),
    };

    final results = await Future.wait([
      // 对话目标（平台/模型）不因本页改动而变化：沿用 Provider 当前选中项。
      _ai.save(
        platforms: _working,
        selectedPlatformId: _ai.selectedPlatformId,
        selectedModelId: _ai.selectedModelId,
        apiKeys: apiKeys,
      ),
      if (syncConfigured)
        _sync.save(
          webdavUrl: webdavUrl.text,
          webdavUsername: webdavUsername.text,
          webdavPassword: webdavPassword.text,
          folder: webdavFolder.text,
          keepVersions: keep!,
          autoUpload: autoUpload,
          userName: webdavUserName.text,
        ),
    ]);
    if (!results[0]) {
      errors.add('API 设置保存失败：${_ai.error ?? '未知错误'}');
    }
    if (syncConfigured) {
      if (!results[1]) {
        errors.add('云同步保存失败：${_sync.error ?? '未知错误'}');
      }
    } else {
      notes.add(
        syncUrl.isEmpty && syncUsername.isEmpty
            ? '云同步未填写'
            : '云同步填写不完整，已跳过云同步保存',
      );
    }
    return SettingsSaveResult(errors: errors, notes: notes);
  }

  // ---------------------------------------------------------------------------
  // 内部
  // ---------------------------------------------------------------------------
  void _ensurePlatformControllers(String id) {
    final existing = _working.firstWhere(
      (p) => p.id == id,
      orElse: () => AiPlatforms.defaultPlatform,
    );
    _platformNameCtrls.putIfAbsent(
      id,
      () => TextEditingController(text: existing.displayName),
    );
    _baseUrlCtrls.putIfAbsent(
      id,
      () => TextEditingController(text: existing.baseUrl),
    );
    _apiKeyCtrls.putIfAbsent(
      id,
      () => TextEditingController(text: _ai.apiKeyFor(id)),
    );
  }

  void _disposePlatformControllers(String id) {
    _platformNameCtrls.remove(id)?.dispose();
    _baseUrlCtrls.remove(id)?.dispose();
    _apiKeyCtrls.remove(id)?.dispose();
  }

  void _replacePlatform(
    String id,
    AiPlatform Function(AiPlatform) fn,
  ) {
    final index = _working.indexWhere((p) => p.id == id);
    if (index < 0) return;
    _working = [..._working];
    _working[index] = fn(_working[index]);
    notifyListeners();
  }

  String _displayPlatformName(AiPlatform p) =>
      p.displayName.trim().isEmpty ? '(未命名)' : p.displayName.trim();

  @override
  void dispose() {
    for (final c in _platformNameCtrls.values) {
      c.dispose();
    }
    for (final c in _baseUrlCtrls.values) {
      c.dispose();
    }
    for (final c in _apiKeyCtrls.values) {
      c.dispose();
    }
    webdavUrl.dispose();
    webdavUsername.dispose();
    webdavPassword.dispose();
    webdavFolder.dispose();
    webdavUserName.dispose();
    webdavKeepVersions.dispose();
    super.dispose();
  }
}

/// 设置页统一保存结果。
///
/// - [errors]：真正的保存失败原因（如 API 设置 / 云同步落库失败），非空即整体失败；
/// - [notes]：非致命提示（如「云同步未填写」），不影响 [ok] 判定。
class SettingsSaveResult {
  final List<String> errors;
  final List<String> notes;

  const SettingsSaveResult({this.errors = const [], this.notes = const []});

  bool get ok => errors.isEmpty;
}
