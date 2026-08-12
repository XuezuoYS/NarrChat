import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config/model_presets.dart';
import '../models/model_preset.dart';
import '../providers/ai_settings_provider.dart';
import '../services/ai_request_body_builder.dart';
import '../utils/focus_utils.dart';
import 'app_menu.dart';

/// 「AI 选择」设置面板（原「API 设置」）。
///
/// - **模型预设**：内置预设（只读，各自定义能力表与请求体规则）+ 自定义模型
///   （OpenAI 兼容格式，请求体由用户自定义）；
/// - **参数始终可调**，特殊情况以次级文本说明
///   （如「思考模式下不发送该参数」「非思考模式下无效」）；
/// - **API 连接**：仅 API Key / Base URL（模型与选项由预设决定，不在此调整）。
class AiSettingsForm extends StatefulWidget {
  const AiSettingsForm({super.key});

  @override
  State<AiSettingsForm> createState() => _AiSettingsFormState();
}

class _AiSettingsFormState extends State<AiSettingsForm> {
  late final TextEditingController _apiKey;
  late final TextEditingController _baseUrl;
  late final TextEditingController _customModelName;
  late final TextEditingController _customRequestBody;
  late final TextEditingController _maxTokens;
  late String _selectedPresetId;
  late double _temperature;
  late String _reasoningEffort;
  bool _obscureKey = true;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    final settings = context.read<AiSettingsProvider>();
    _apiKey = TextEditingController(text: settings.apiKey);
    _baseUrl = TextEditingController(text: settings.baseUrl);
    _customModelName = TextEditingController(text: settings.customModelName);
    _customRequestBody = TextEditingController(
      text: settings.customRequestBody,
    );
    _selectedPresetId = settings.selectedPresetId;
    _temperature = settings.temperature;
    _reasoningEffort = settings.reasoningEffort;
    _maxTokens = TextEditingController(
      text: settings.maxTokens?.toString() ?? '',
    );
  }

  @override
  void dispose() {
    _apiKey.dispose();
    _baseUrl.dispose();
    _customModelName.dispose();
    _customRequestBody.dispose();
    _maxTokens.dispose();
    super.dispose();
  }

  int? get _effectiveMaxTokens {
    final text = _maxTokens.text.trim();
    if (text.isEmpty) return null;
    return int.tryParse(text);
  }

  bool get _isCustom => _selectedPresetId == ModelPresets.customId;

  /// 切换预设：载入该预设记忆的参数（无记忆则用预设默认值）。
  void _selectPreset(String id) {
    final settings = context.read<AiSettingsProvider>();
    setState(() {
      _selectedPresetId = id;
      final preset = ModelPresets.byId(id);
      final memory = settings.presetParams[id];
      _temperature = memory?.temperature ?? preset.defaultTemperature;
      _reasoningEffort =
          memory?.reasoningEffort ?? preset.defaultReasoningEffort;
      final max = memory?.maxTokens ?? preset.defaultMaxTokens;
      _maxTokens.text = max?.toString() ?? '';
    });
  }

  Future<void> _save() async {
    final maxTokens = _effectiveMaxTokens;
    if (maxTokens != null && maxTokens <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('最大输出 Tokens 需为正整数或留空')),
      );
      return;
    }
    if (_isCustom) {
      final name = _customModelName.text.trim();
      if (name.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('自定义模型名称不能为空')),
        );
        return;
      }
      try {
        AiRequestBodyBuilder.validateCustomTemplate(_customRequestBody.text);
      } on FormatException catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message)),
        );
        return;
      }
    }

    setState(() => _isSaving = true);
    final provider = context.read<AiSettingsProvider>();
    final ok = await provider.save(
      apiKey: _apiKey.text,
      baseUrl: _baseUrl.text,
      selectedPresetId: _selectedPresetId,
      temperature: _temperature,
      reasoningEffort: _reasoningEffort,
      maxTokens: maxTokens,
      customModelName: _customModelName.text,
      customRequestBody: _customRequestBody.text,
    );
    if (!mounted) return;
    setState(() => _isSaving = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? '已保存' : '保存失败：${provider.error ?? '未知错误'}'),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 构建
  // ---------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final preset = ModelPresets.byId(_selectedPresetId);
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'AI 选择',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            '选择模型预设：各预设定义模型能力与请求参数规则；参数始终可调，'
            '特殊情况见次级说明。自定义模型仅支持 OpenAI 兼容 API 格式。',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 20),
          _sectionTitle(context, 'API 连接'),
          TextField(
            controller: _apiKey,
            onTapOutside: unfocusOnTapOutside,
            obscureText: _obscureKey,
            enableSuggestions: false,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: 'API Key',
              hintText: 'sk-…（保存至系统安全存储）',
              border: const OutlineInputBorder(),
              isDense: true,
              suffixIcon: IconButton(
                icon: Icon(_obscureKey ? Icons.visibility_off : Icons.visibility),
                tooltip: _obscureKey ? '显示' : '隐藏',
                onPressed: () => setState(() => _obscureKey = !_obscureKey),
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _baseUrl,
            onTapOutside: unfocusOnTapOutside,
            decoration: const InputDecoration(
              labelText: 'Base URL',
              hintText: 'https://api.deepseek.com',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 20),
          _sectionTitle(context, '模型预设'),
          for (final p in ModelPresets.builtins) _buildPresetTile(p),
          _buildPresetTile(ModelPresets.customPreset),
          const SizedBox(height: 12),
          if (_isCustom)
            _buildCustomSection(context)
          else
            _buildParamSection(context, preset),
          const SizedBox(height: 20),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: _isSaving ? null : _save,
              icon: const Icon(Icons.save_outlined, size: 18),
              label: Text(_isSaving ? '保存中…' : '保存'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }

  /// 预设选择卡片（内置只读 / 自定义）。
  Widget _buildPresetTile(ModelPreset preset) {
    final selected = _selectedPresetId == preset.id;
    final isCustom = preset.id == ModelPresets.customId;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: selected
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.outlineVariant,
          width: selected ? 1.6 : 1,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _selectPreset(preset.id),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Row(
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 20,
                color: selected
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.outline,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      preset.displayName,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      isCustom
                          ? 'OpenAI 兼容格式 · 请求体自定义'
                          : preset.modelId,
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (!isCustom) ...[
                      const SizedBox(height: 4),
                      _buildCapabilityBadges(preset),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCapabilityBadges(ModelPreset preset) {
    Widget badge(String text, bool on) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: on
              ? Theme.of(context).colorScheme.primaryContainer
              : Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 10,
            color: on
                ? Theme.of(context).colorScheme.onPrimaryContainer
                : Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        badge('流式', preset.supportsStreaming),
        const SizedBox(width: 4),
        badge('思考', preset.supportsThinking),
        const SizedBox(width: 4),
        badge('联网搜索', preset.supportsSearch),
      ],
    );
  }

  /// 参数区：始终可调，特殊情况以次级文本说明。
  Widget _buildParamSection(BuildContext context, ModelPreset preset) {
    final outline = Theme.of(context).colorScheme.outline;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 温度（始终可调；思考模式下不发送）
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('温度', style: TextStyle(fontSize: 14)),
                const SizedBox(width: 8),
                Text(
                  _temperature.toStringAsFixed(1),
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                if (preset.temperatureNote != null) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      preset.temperatureNote!,
                      textAlign: TextAlign.end,
                      style: TextStyle(fontSize: 11, color: outline),
                    ),
                  ),
                ],
              ],
            ),
            Slider(
              value: _temperature,
              min: 0,
              max: 2,
              divisions: 20,
              label: _temperature.toStringAsFixed(1),
              onChanged: (v) => setState(() => _temperature = v),
            ),
          ],
        ),
        const SizedBox(height: 4),
        // 推理强度（始终可调；非思考模式下无效）
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppDropdown<String>(
              label: '推理强度（reasoning_effort）',
              value: _reasoningEffort,
              items: [
                for (final e in const ['low', 'high', 'max'])
                  DropdownMenuItem(value: e, child: Text(e)),
              ],
              onChanged: (v) => setState(() {
                _reasoningEffort = v ?? _reasoningEffort;
              }),
            ),
            if (preset.reasoningEffortNote != null)
              Padding(
                padding: const EdgeInsets.only(top: 4, left: 4),
                child: Text(
                  preset.reasoningEffortNote!,
                  style: TextStyle(fontSize: 11, color: outline),
                ),
              ),
          ],
        ),
        const SizedBox(height: 16),
        // 最大输出 Tokens（始终可调）
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _maxTokens,
              onTapOutside: unfocusOnTapOutside,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '最大输出 Tokens（留空自动）',
                hintText: '如 4096',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            if (preset.maxTokensNote != null)
              Padding(
                padding: const EdgeInsets.only(top: 4, left: 4),
                child: Text(
                  preset.maxTokensNote!,
                  style: TextStyle(fontSize: 11, color: outline),
                ),
              ),
          ],
        ),
      ],
    );
  }

  /// 自定义模型区：模型名 + 请求体 JSON 编辑器（占位符说明）。
  Widget _buildCustomSection(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _customModelName,
          onTapOutside: unfocusOnTapOutside,
          decoration: const InputDecoration(
            labelText: '自定义模型名称',
            hintText: '如 my-model',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Text(
                '请求体（OpenAI 兼容 JSON，支持占位符）',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ),
            TextButton(
              onPressed: () => setState(() {
                _customRequestBody.text = ModelPresets.defaultCustomRequestBody;
              }),
              child: const Text('恢复默认模板'),
            ),
          ],
        ),
        TextField(
          controller: _customRequestBody,
          onTapOutside: unfocusOnTapOutside,
          minLines: 10,
          maxLines: 18,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            height: 1.5,
          ),
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            isDense: true,
            alignLabelWithHint: true,
            hintText: '{\n  "model": {{model}},\n  "messages": {{messages}},\n  "stream": {{stream}}\n}',
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 12,
          runSpacing: 4,
          children: [
            for (final p in AiRequestBodyBuilder.allPlaceholders)
              Text(
                p,
                style: TextStyle(
                  fontSize: 10,
                  fontFamily: 'monospace',
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '占位符代表 JSON 编码后的值（无需引号）：{{model}} 模型名 · '
          '{{messages}} 消息数组 · {{stream}} true/false · '
          '{{temperature}} 温度 · {{thinking_type}} enabled/disabled · '
          '{{reasoning_effort}} 推理强度 · {{max_tokens}} 数字或 null · '
          '{{tools}} 工具数组（未开启为空数组）',
          style: TextStyle(
            fontSize: 11,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
