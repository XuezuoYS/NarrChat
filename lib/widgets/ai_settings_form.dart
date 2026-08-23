import 'package:flutter/material.dart';

import '../models/ai_platform.dart';
import '../models/api_type.dart';
import '../services/ai_request_body_builder.dart';
import '../utils/focus_utils.dart';
import 'app_menu.dart';
import 'settings_form_state.dart';

/// 「AI 选择」设置面板。
///
/// 结构参考 DeepSeek Harness 的 `providers[].models[]`：
/// - **平台**：内置默认（DeepSeek 开放平台，不可删）+ 用户自定义平台；
///   每个平台各自持有 API Key / Base URL / API 类型（当前仅 OpenAI 兼容）与模型列表；
/// - **模型**：每个平台下的一张模型列表，模型含简写标识 / 温度 / 推理强度 /
///   最大输出 Tokens，可选自定义请求体 JSON 模板；
///   能力表（流式 / 思考 / 联网搜索）来自平台接入协议，只读展示。
///
/// 表单值由外层 [SettingsFormState] 持有（切换面板不丢失），
/// 由设置页右上角「保存」统一校验并落库；保存后不退出设置页。
class AiSettingsForm extends StatefulWidget {
  final SettingsFormState form;

  const AiSettingsForm({super.key, required this.form});

  @override
  State<AiSettingsForm> createState() => _AiSettingsFormState();
}

class _AiSettingsFormState extends State<AiSettingsForm> {
  SettingsFormState get _form => widget.form;

  /// 已明文显示 API Key 的平台 id 集合。
  final Set<String> _revealedKeys = {};

  void _selectPlatform(String id) => setState(() => _form.selectPlatform(id));

  void _selectModel(String id) => setState(() => _form.selectModel(id));

  // ---------------------------------------------------------------------------
  // 添加 / 删除平台
  // ---------------------------------------------------------------------------
  Future<void> _addPlatform() async {
    final result = await showDialog<_AddedPlatform>(
      context: context,
      builder: (_) => const _AddPlatformDialog(),
    );
    if (result == null || !mounted) return;
    setState(() {
      _form.addPlatform(name: result.name, baseUrl: result.baseUrl);
      _form.apiKeyCtrlFor(_form.selectedPlatformId).text = result.apiKey;
    });
  }

  void _removePlatform() {
    final p = _form.selectedPlatform;
    if (p.isBuiltin) return;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除平台'),
        content: Text('确定删除平台「${p.displayName}」吗？该平台下的全部模型配置将一并删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              setState(() => _form.removePlatform(p.id));
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 添加 / 删除模型
  // ---------------------------------------------------------------------------
  Future<void> _addModel() async {
    final platform = _form.selectedPlatform;
    final result = await showDialog<_AddedModel>(
      context: context,
      builder: (_) => const _AddModelDialog(),
    );
    if (result == null || !mounted) return;
    setState(() {
      _form.addModel(platform.id, id: result.id, shortLabel: result.shortLabel);
    });
  }

  void _removeModel() {
    final platform = _form.selectedPlatform;
    final model = _form.selectedModel;
    if (platform.models.length <= 1) return;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除模型'),
        content: Text('确定删除模型「${model.displayLabel}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              setState(() => _form.removeModel(platform.id, model.id));
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 构建
  // ---------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final platform = _form.selectedPlatform;
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
            '按平台 + 模型组织：每个平台（默认 DeepSeek 开放平台或自定义平台）'
            '独立持有连接配置与自己的模型列表；模型可设置简写标识、温度、推理强度等参数。',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 20),
          _sectionTitle(context, '平台'),
          for (final p in _form.platforms) _buildPlatformTile(context, p),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _addPlatform,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('添加自定义平台'),
          ),
          const SizedBox(height: 20),
          _sectionTitle(context, '连接设置（${platform.displayName}）'),
          _buildConnectionSection(context, platform),
          const SizedBox(height: 20),
          _sectionTitle(context, '模型设置'),
          for (final m in platform.models) _buildModelTile(context, m),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _addModel,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('添加模型'),
          ),
          const SizedBox(height: 12),
          if (platform.models.isNotEmpty) _buildModelEditor(context),
          if (!platform.isBuiltin) ...[
            const SizedBox(height: 20),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _removePlatform,
                icon: Icon(
                  Icons.delete_outline,
                  size: 18,
                  color: Theme.of(context).colorScheme.error,
                ),
                label: Text(
                  '删除此平台',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ),
          ],
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

  // ---------------------------------------------------------------------------
  // 平台选择卡片
  // ---------------------------------------------------------------------------
  Widget _buildPlatformTile(BuildContext context, AiPlatform platform) {
    final selected = _form.selectedPlatformId == platform.id;
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
        onTap: () => _selectPlatform(platform.id),
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
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: platform.displayName,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurface,
                            ),
                          ),
                          TextSpan(
                            text: platform.isBuiltin
                                ? '  内置 · ${platformModelsCountLabel(platform)}'
                                : '  自定义 · ${platform.apiType.displayName}',
                            style: TextStyle(
                              fontSize: 11,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String platformModelsCountLabel(AiPlatform platform) {
    return '${platform.models.length} 个模型';
  }

  // ---------------------------------------------------------------------------
  // 连接设置
  // ---------------------------------------------------------------------------
  Widget _buildConnectionSection(BuildContext context, AiPlatform platform) {
    final apiType = _form.apiType;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppDropdown<String>(
          label: 'API 类型',
          value: apiType.id,
          items: [
            for (final t in ApiType.all)
              DropdownMenuItem(value: t.id, child: Text(t.displayName)),
          ],
          onChanged: (_) {},
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _form.baseUrlCtrlFor(platform.id),
          onTapOutside: unfocusOnTapOutside,
          decoration: const InputDecoration(
            labelText: 'Base URL',
            hintText: 'https://api.deepseek.com',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _form.apiKeyCtrlFor(platform.id),
          onTapOutside: unfocusOnTapOutside,
          obscureText: !_revealedKeys.contains(platform.id),
          enableSuggestions: false,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: 'API Key',
            hintText: 'sk-…（保存至系统安全存储）',
            border: const OutlineInputBorder(),
            isDense: true,
            suffixIcon: IconButton(
              icon: Icon(
                _revealedKeys.contains(platform.id)
                    ? Icons.visibility_off
                    : Icons.visibility,
              ),
              tooltip: _revealedKeys.contains(platform.id) ? '隐藏' : '显示',
              onPressed: () => setState(() {
                if (_revealedKeys.contains(platform.id)) {
                  _revealedKeys.remove(platform.id);
                } else {
                  _revealedKeys.add(platform.id);
                }
              }),
            ),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // 模型选择卡片
  // ---------------------------------------------------------------------------
  Widget _buildModelTile(BuildContext context, AiModel model) {
    final selected = _form.selectedModel.id == model.id;
    final hasTemplate = (model.requestTemplate ?? '').trim().isNotEmpty;
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
        onTap: () => _selectModel(model.id),
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
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: model.displayLabel,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                      TextSpan(
                        text: hasTemplate ? '  ${model.id} · 自定义请求体' : '  ${model.id}',
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              SizedBox(
                width: 32,
                height: 32,
                child: IconButton(
                  icon: Icon(
                    Icons.remove_circle_outline,
                    size: 18,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                  tooltip: '删除模型',
                  onPressed: _form.selectedPlatform.models.length <= 1
                      ? null
                      : () => _removeModelFor(context, model),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _removeModelFor(BuildContext context, AiModel model) {
    final platform = _form.selectedPlatform;
    if (platform.models.length <= 1) return;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除模型'),
        content: Text('确定删除模型「${model.displayLabel}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              setState(() => _form.removeModel(platform.id, model.id));
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 选中模型参数编辑
  // ---------------------------------------------------------------------------
  Widget _buildModelEditor(BuildContext context) {
    final platform = _form.selectedPlatform;
    final model = _form.selectedModel;
    final apiType = _form.apiType;
    final outline = Theme.of(context).colorScheme.outline;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '${model.displayLabel} · 参数',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ),
            if (platform.models.isNotEmpty)
              IconButton(
                icon: Icon(
                  Icons.remove_circle_outline,
                  size: 20,
                  color: Theme.of(context).colorScheme.error,
                ),
                tooltip: '删除模型',
                onPressed: platform.models.length <= 1
                    ? null
                    : () => _removeModel(),
              ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _form.shortLabelCtrl,
          onTapOutside: unfocusOnTapOutside,
          onChanged: (v) => setState(() => _form.setModelShortLabel(v)),
          decoration: const InputDecoration(
            labelText: '简写标识（对话框显示，留空用模型名）',
            hintText: '如 V4F',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '用于你在对话框内便捷识别；为空时显示模型名（${model.id}）。',
          style: TextStyle(fontSize: 11, color: outline),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            const Text('温度', style: TextStyle(fontSize: 14)),
            const SizedBox(width: 8),
            Text(
              _form.temperature.toStringAsFixed(1),
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            if (apiType.temperatureNote != null) ...[
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  apiType.temperatureNote!,
                  textAlign: TextAlign.end,
                  style: TextStyle(fontSize: 11, color: outline),
                ),
              ),
            ],
          ],
        ),
        Slider(
          value: _form.temperature,
          min: 0,
          max: 2,
          divisions: 20,
          label: _form.temperature.toStringAsFixed(1),
          onChanged: (v) => setState(() => _form.setModelTemperature(v)),
        ),
        const SizedBox(height: 4),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppDropdown<String>(
              label: '推理强度（reasoning_effort）',
              value: _form.reasoningEffort,
              items: [
                for (final e in const ['low', 'high', 'max'])
                  DropdownMenuItem(value: e, child: Text(e)),
              ],
              onChanged: (v) => setState(() {
                if (v != null) _form.setModelReasoningEffort(v);
              }),
            ),
            if (apiType.reasoningEffortNote != null)
              Padding(
                padding: const EdgeInsets.only(top: 4, left: 4),
                child: Text(
                  apiType.reasoningEffortNote!,
                  style: TextStyle(fontSize: 11, color: outline),
                ),
              ),
          ],
        ),
        const SizedBox(height: 16),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _form.maxTokensCtrl,
              onTapOutside: unfocusOnTapOutside,
              keyboardType: TextInputType.number,
              onChanged: (v) => setState(() => _form.setModelMaxTokens(v)),
              decoration: const InputDecoration(
                labelText: '最大输出 Tokens（留空自动）',
                hintText: '如 4096',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            if (apiType.maxTokensNote != null)
              Padding(
                padding: const EdgeInsets.only(top: 4, left: 4),
                child: Text(
                  apiType.maxTokensNote!,
                  style: TextStyle(fontSize: 11, color: outline),
                ),
              ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: Text(
                '自定义请求体（可选，OpenAI 兼容 JSON）',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ),
            TextButton(
              onPressed: () => setState(() {
                _form.setModelRequestTemplate(
                  AiRequestBodyBuilder.defaultCustomRequestBody,
                );
              }),
              child: const Text('插入默认模板'),
            ),
          ],
        ),
        TextField(
          controller: _form.requestTemplateCtrl,
          onTapOutside: unfocusOnTapOutside,
          onChanged: (v) => setState(() => _form.setModelRequestTemplate(v)),
          minLines: 8,
          maxLines: 16,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            height: 1.5,
          ),
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            isDense: true,
            alignLabelWithHint: true,
            hintText: '留空使用平台默认规则；非空按此模板直发',
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
      ],
    );
  }
}

/// 新增自定义平台对话框的返回数据。
class _AddedPlatform {
  final String name;
  final String baseUrl;
  final String apiKey;

  const _AddedPlatform({
    required this.name,
    required this.baseUrl,
    required this.apiKey,
  });
}

/// 新增自定义平台对话框：平台名 + Base URL + API 类型（仅 OpenAI 兼容一项）+ API Key。
class _AddPlatformDialog extends StatefulWidget {
  const _AddPlatformDialog();

  @override
  State<_AddPlatformDialog> createState() => _AddPlatformDialogState();
}

class _AddPlatformDialogState extends State<_AddPlatformDialog> {
  final _nameCtrl = TextEditingController();
  final _baseUrlCtrl = TextEditingController();
  final _apiKeyCtrl = TextEditingController();
  String _apiType = ApiType.openAiCompatibleId;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _baseUrlCtrl.dispose();
    _apiKeyCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _nameCtrl.text.trim();
    final baseUrl = _baseUrlCtrl.text.trim();
    if (name.isEmpty || baseUrl.isEmpty) return;
    Navigator.of(context).pop(
      _AddedPlatform(name: name, baseUrl: baseUrl, apiKey: _apiKeyCtrl.text),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('添加自定义平台'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _nameCtrl,
              autofocus: true,
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                labelText: '平台名称',
                hintText: '如 我的网关',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            AppDropdown<String>(
              label: 'API 类型',
              value: _apiType,
              items: [
                for (final t in ApiType.all)
                  DropdownMenuItem(value: t.id, child: Text(t.displayName)),
              ],
              onChanged: (v) =>
                  setState(() => _apiType = v ?? ApiType.openAiCompatibleId),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _baseUrlCtrl,
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                labelText: 'Base URL',
                hintText: 'https://…/v1',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _apiKeyCtrl,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'API Key',
                hintText: 'sk-…（保存至系统安全存储）',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('添加'),
        ),
      ],
    );
  }
}

/// 新增模型对话框的返回数据。
class _AddedModel {
  final String id;
  final String shortLabel;

  const _AddedModel({required this.id, required this.shortLabel});
}

/// 新增模型对话框：模型名（发往 API）+ 简写标识（可选）。
class _AddModelDialog extends StatefulWidget {
  const _AddModelDialog();

  @override
  State<_AddModelDialog> createState() => _AddModelDialogState();
}

class _AddModelDialogState extends State<_AddModelDialog> {
  final _idCtrl = TextEditingController();
  final _labelCtrl = TextEditingController();

  @override
  void dispose() {
    _idCtrl.dispose();
    _labelCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final id = _idCtrl.text.trim();
    if (id.isEmpty) return;
    Navigator.of(
      context,
    ).pop(_AddedModel(id: id, shortLabel: _labelCtrl.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('添加模型'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _idCtrl,
              autofocus: true,
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                labelText: '模型名（发往 API）',
                hintText: '如 gpt-4o-mini',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _labelCtrl,
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                labelText: '简写标识（可选）',
                hintText: '留空用模型名',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('添加'),
        ),
      ],
    );
  }
}
