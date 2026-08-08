import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config/app_config.dart';
import '../providers/ai_settings_provider.dart';
import '../theme/app_theme.dart';
import 'app_menu.dart';

/// AI 接口设置表单（可嵌入全窗口设置页）。
///
/// 配置项（参数遵循 DeepSeek 官方文档）：
/// - API Key（保存到安全存储 flutter_secure_storage）
/// - Base URL
/// - 模型名称（内置 deepseek-v4-pro / deepseek-v4-flash，支持自定义）
/// - 温度（0.0 ~ 2.0 滑块，仅非思考模式生效）
/// - 思考模式（开关）与推理强度（low / high / max）
/// - 最大输出 Tokens（可选）
/// - 流式输出（开关）
class ApiSettingsForm extends StatefulWidget {
  const ApiSettingsForm({super.key});

  @override
  State<ApiSettingsForm> createState() => _ApiSettingsFormState();
}

class _ApiSettingsFormState extends State<ApiSettingsForm> {
  late final TextEditingController _apiKey;
  late final TextEditingController _baseUrl;
  late final TextEditingController _customModel;
  late final TextEditingController _maxTokens;
  late String _model;
  late double _temperature;
  late bool _thinking;
  late String _reasoningEffort;
  late bool _streaming;
  late bool _customModelMode;
  bool _obscureKey = true;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    final settings = context.read<AiSettingsProvider>();
    _apiKey = TextEditingController(text: settings.apiKey);
    _baseUrl = TextEditingController(text: settings.baseUrl);
    _model = settings.model;
    _customModelMode = !AppConfig.supportedModels.contains(settings.model);
    _customModel = TextEditingController(
      text: _customModelMode ? settings.model : '',
    );
    _temperature = settings.temperature;
    _thinking = settings.thinking;
    _reasoningEffort = settings.reasoningEffort;
    _maxTokens = TextEditingController(
      text: settings.maxTokens?.toString() ?? '',
    );
    _streaming = settings.streaming;
  }

  @override
  void dispose() {
    _apiKey.dispose();
    _baseUrl.dispose();
    _customModel.dispose();
    _maxTokens.dispose();
    super.dispose();
  }

  String get _effectiveModel =>
      _customModelMode ? _customModel.text.trim() : _model;

  int? get _effectiveMaxTokens {
    final text = _maxTokens.text.trim();
    if (text.isEmpty) return null;
    return int.tryParse(text);
  }

  Future<void> _save() async {
    final model = _effectiveModel;
    if (model.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('模型名称不能为空')),
      );
      return;
    }
    final maxTokens = _effectiveMaxTokens;
    if (maxTokens != null && maxTokens <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('最大输出 Tokens 需为正整数或留空')),
      );
      return;
    }
    setState(() => _isSaving = true);
    final provider = context.read<AiSettingsProvider>();
    final ok = await provider.save(
      apiKey: _apiKey.text,
      baseUrl: _baseUrl.text,
      model: model,
      temperature: _temperature,
      thinking: _thinking,
      reasoningEffort: _reasoningEffort,
      maxTokens: maxTokens,
      streaming: _streaming,
    );
    if (!mounted) return;
    setState(() => _isSaving = false);
    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已保存'), duration: Duration(seconds: 1)),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败：${provider.error ?? '未知错误'}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'API 设置',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: NarrChatTheme.textPrimary,
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          '配置大模型接口参数，遵循 DeepSeek 官方格式（OpenAI 兼容）。',
          style: TextStyle(fontSize: 12, color: NarrChatTheme.textSecondary),
        ),
        const SizedBox(height: 20),
        // API Key（安全存储）
        TextField(
          controller: _apiKey,
          obscureText: _obscureKey,
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
        // Base URL
        TextField(
          controller: _baseUrl,
          decoration: const InputDecoration(
            labelText: 'Base URL',
            hintText: 'https://api.deepseek.com',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 12),
        // 模型
        AppDropdown<String>(
          label: '模型名称',
          value: _customModelMode ? '__custom__' : _model,
          items: [
            for (final m in AppConfig.supportedModels)
              DropdownMenuItem(value: m, child: Text(m)),
            const DropdownMenuItem(
              value: '__custom__',
              child: Text('自定义…'),
            ),
          ],
          onChanged: (v) => setState(() {
            _customModelMode = v == '__custom__';
            _model = _customModelMode ? _model : (v ?? _model);
          }),
        ),
        if (_customModelMode) ...[
          const SizedBox(height: 8),
          TextField(
            controller: _customModel,
            decoration: const InputDecoration(
              labelText: '自定义模型名称',
              hintText: '如 deepseek-v4-pro',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ],
        const SizedBox(height: 12),
        // 温度（思考模式下官方不支持）
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
                    color: _thinking
                        ? Theme.of(context).colorScheme.outline
                        : Theme.of(context).colorScheme.primary,
                  ),
                ),
                if (_thinking) ...[
                  const SizedBox(width: 8),
                  Text(
                    '（思考模式下不生效）',
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                ],
              ],
            ),
            Slider(
              value: _temperature,
              min: AppConfig.minTemperature,
              max: AppConfig.maxTemperature,
              divisions: 20,
              label: _temperature.toStringAsFixed(1),
              onChanged: _thinking
                  ? null
                  : (v) => setState(() => _temperature = v),
            ),
          ],
        ),
        const SizedBox(height: 4),
        // 最大输出 Tokens
        TextField(
          controller: _maxTokens,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: '最大输出 Tokens（留空自动）',
            hintText: '如 4096',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const Divider(),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('思考模式'),
          subtitle: const Text('官方默认开启；思考模式下 temperature 不生效'),
          value: _thinking,
          onChanged: (v) => setState(() => _thinking = v),
        ),
        if (_thinking) ...[
          const SizedBox(height: 4),
          AppDropdown<String>(
            label: '推理强度（reasoning_effort）',
            value: _reasoningEffort,
            items: [
              for (final e in AppConfig.reasoningEffortOptions)
                DropdownMenuItem(value: e, child: Text(e)),
            ],
            onChanged: (v) => setState(() {
              _reasoningEffort = v ?? _reasoningEffort;
            }),
          ),
        ],
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('流式输出'),
          subtitle: const Text('以 SSE 流式实时显示 AI 生成内容'),
          value: _streaming,
          onChanged: (v) => setState(() => _streaming = v),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            onPressed: _isSaving ? null : _save,
            icon: const Icon(Icons.save_outlined, size: 18),
            label: Text(_isSaving ? '保存中…' : '保存'),
          ),
        ),
      ],
    );
  }
}
