import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/ai_platforms.dart';
import '../models/ai_platform.dart';
import '../models/api_type.dart';
import '../utils/focus_utils.dart';
import 'app_menu.dart';
import 'settings_form_state.dart';

/// 「API 设置」设置面板。
///
/// 以「平台 → 模型」两级可展开树组织（参考 DeepSeek Harness 的
/// `providers[].models[]`）：
///
/// ```
/// 当前为软件内置预置配置（未自定义模型）
/// 默认API（DeepSeek 开放平台）          内置默认   ▸
/// | 连接设置（名称 / API Key / Base URL / API 类型）
/// | 模型1                                       ▸
/// | | 模型1 的简写标识 / 温度 / 推理强度 / ...
/// | 添加模型 / 删除此平台 / 重置为内置预置
/// 自定义API1                              自定义     ▸
/// | ...
/// ```
///
/// - 每个【平台】是一个可展开条目，展开后显示该平台的连接设置与模型列表；
/// - 每个【模型】是其下面的一个可展开条目，展开后显示该模型的参数设置；
/// - 软件内置预置平台（`AiPlatforms.presetFor(id) != null`）可自由编辑，未改动时
///   标注「内置默认」、改动后标注「已自定义」并出现「重置为内置预置」（二次确认，
///   只还原该平台，自添加平台不受影响）；被删除的预置平台可一键恢复；
/// - 任何平台都可增删模型、改名、改连接设置（每个平台至少保留一个模型）。
///
/// 本面板只做「按平台 + 按模型编辑参数」，不在此选择对话所用的模型/平台。
///
/// 表单值由外层 [SettingsFormState] 持有（切换面板不丢失），
/// 由设置页右上角「保存」统一校验并落库；保存后不退出设置页。
/// 重置同样只作用于编辑态，落盘仍由「保存」完成。
class AiSettingsForm extends StatefulWidget {
  final SettingsFormState form;

  const AiSettingsForm({super.key, required this.form});

  @override
  State<AiSettingsForm> createState() => _AiSettingsFormState();
}

class _AiSettingsFormState extends State<AiSettingsForm> {
  SettingsFormState get _form => widget.form;

  // ---------------------------------------------------------------------------
  // 添加自定义平台
  // ---------------------------------------------------------------------------
  Future<void> _addPlatform() async {
    final result = await showDialog<_AddedPlatform>(
      context: context,
      builder: (_) => const _AddPlatformDialog(),
    );
    if (result == null || !mounted) return;
    _form.addPlatform(
      name: result.name,
      baseUrl: result.baseUrl,
      apiTypeId: result.apiTypeId,
    );
    // 把对话框里输入的 API Key 写入新平台（列表末尾）的控制器。
    _form.apiKeyCtrlFor(_form.platforms.last.id).text = result.apiKey;
  }

  /// 恢复被删除的内置预置平台（二次确认后写回工作副本，保存时落盘）。
  Future<void> _confirmRestorePresetPlatform(AiPlatform preset) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('恢复内置平台'),
        content: Text(
          '确定恢复软件内置预置平台「${preset.displayName}」吗？'
          '其连接设置与模型列表为该平台的预置值，其它平台不受影响。\n\n'
          '恢复为编辑态，点击右上角「保存」后写入配置文件。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    _form.restorePresetPlatform(preset.id);
  }

  // ---------------------------------------------------------------------------
  // 构建
  // ---------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    // 监听表单状态：平台/模型编辑写回（addModel / removeModel / updateModel /
    // setPlatformName / setPlatformBaseUrl 等）触发 _form 通知，这里重建以刷新。
    return ListenableBuilder(
      listenable: _form,
      builder: (context, _) {
        final platforms = _form.platforms;
        final missingPresets = _form.missingPresetPlatforms;
        final onSurfaceVariant = Theme.of(context).colorScheme.onSurfaceVariant;
        return SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'API 设置',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                '按「平台 → 模型」组织：展开平台查看其连接设置与模型列表；'
                '软件内置预置的平台标注「内置默认」，可整平台重置为预置'
                '（自定义平台不受影响）。本页不选择对话所用的模型。',
                style: TextStyle(fontSize: 12, color: onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              Text(
                '图片设置',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '单张图片大小上限（超过将提示文件过大）',
                      style: TextStyle(fontSize: 14),
                    ),
                  ),
                  SizedBox(
                    width: 96,
                    child: TextFormField(
                      initialValue: '${_form.maxImageSizeMB}',
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                      ],
                      onChanged: (v) {
                        final n = int.tryParse(v);
                        if (n != null) _form.setMaxImageSizeMB(n);
                      },
                      decoration: const InputDecoration(
                        hintText: '16',
                        border: OutlineInputBorder(),
                        isDense: true,
                        suffixText: 'MB',
                        counterText: '',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text(
                  '自动将 .jpg 转换为 .jpeg',
                  style: TextStyle(fontSize: 14),
                ),
                subtitle: Text(
                  '部分识图模型不支持 jpg，因此提供此选项进行格式转换',
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                value: _form.convertJpgToJpeg,
                onChanged: _form.setConvertJpgToJpeg,
              ),
              const SizedBox(height: 20),
              Text(
                '模型设置',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
              const SizedBox(height: 6),
              // 预置分层状态：默认态明确提示"当前为内置预置"，自定义态提示可重置。
              Row(
                children: [
                  Icon(
                    _form.usesBuiltinPlatforms
                        ? Icons.verified_outlined
                        : Icons.edit_outlined,
                    size: 15,
                    color: onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _form.usesBuiltinPlatforms
                          ? '当前为软件内置预置配置（未自定义模型）'
                          : '已自定义模型配置：内置预置平台可整平台重置为预置',
                      style: TextStyle(fontSize: 12, color: onSurfaceVariant),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              for (var i = 0; i < platforms.length; i++)
                _PlatformExpandableItem(
                  key: ValueKey('platform-${platforms[i].id}'),
                  form: _form,
                  platform: platforms[i],
                  // 默认展开第一个平台（通常为内置预置），便于直接看到其设置。
                  initiallyExpanded: i == 0,
                ),
              const SizedBox(height: 12),
              // 被删除的内置预置平台：一键恢复（二次确认）。
              for (final preset in missingPresets) ...[
                OutlinedButton.icon(
                  onPressed: () => _confirmRestorePresetPlatform(preset),
                  icon: const Icon(Icons.restore, size: 18),
                  label: Text('恢复内置平台「${preset.displayName}」'),
                ),
                const SizedBox(height: 8),
              ],
              OutlinedButton.icon(
                onPressed: _addPlatform,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('添加自定义平台'),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// 通用可展开卡片：模型名/平台名 header + 展开箭头 + 可展开内容（带左侧竖线引导）
// ---------------------------------------------------------------------------
class ExpandableCard extends StatefulWidget {
  final Widget title;

  /// 展开后显示的内容。
  final Widget child;

  /// 是否默认展开。
  final bool initiallyExpanded;

  const ExpandableCard({
    super.key,
    required this.title,
    required this.child,
    this.initiallyExpanded = false,
  });

  @override
  State<ExpandableCard> createState() => _ExpandableCardState();
}

class _ExpandableCardState extends State<ExpandableCard> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final outlineVariant = Theme.of(context).colorScheme.outlineVariant;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: outlineVariant),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
              child: Row(
                children: [
                  Expanded(child: widget.title),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Container(
              // 左侧竖线引导，模拟「| 设置项……」的缩进层级。
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(color: outlineVariant, width: 2),
                ),
              ),
              padding: const EdgeInsets.fromLTRB(16, 8, 12, 12),
              child: widget.child,
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 平台可展开条目：连接设置 + 模型列表（增删模型 / 删平台 / 重置为内置预置）
// ---------------------------------------------------------------------------
class _PlatformExpandableItem extends StatelessWidget {
  final SettingsFormState form;
  final AiPlatform platform;
  final bool initiallyExpanded;

  const _PlatformExpandableItem({
    super.key,
    required this.form,
    required this.platform,
    this.initiallyExpanded = false,
  });

  /// 是否为软件内置预置平台（按预置注册表判定，不看配置里的任何标记）。
  bool get _isPreset => AiPlatforms.isPresetId(platform.id);

  /// 是否是最后一个平台（删除入口禁用，保证至少保留一个平台）。
  bool get _canRemove => form.platforms.length > 1;

  /// 平台卡片右上角的状态标注。
  String get _badge {
    if (!_isPreset) return '自定义';
    return form.platformUnchanged(platform) ? '内置默认' : '已自定义';
  }

  @override
  Widget build(BuildContext context) {
    final onSurfaceVariant = Theme.of(context).colorScheme.onSurfaceVariant;
    // 仅「预置平台且已被改动」时才提供重置入口（其余情况无可重置内容）。
    final canReset = _isPreset && !form.platformUnchanged(platform);
    return ExpandableCard(
      initiallyExpanded: initiallyExpanded,
      title: Row(
        children: [
          Expanded(
            child: Text(
              platform.displayName,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
          Text(
            _badge,
            style: TextStyle(fontSize: 11, color: onSurfaceVariant),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          _PlatformSettings(form: form, platform: platform),
          const SizedBox(height: 16),
          const Text(
            '模型',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          if (platform.models.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                '暂无模型，点击下方「添加模型」。',
                style: TextStyle(fontSize: 12, color: onSurfaceVariant),
              ),
            )
          else
            for (final m in platform.models)
              _ModelExpandableItem(
                key: ValueKey('model-${platform.id}-${m.id}'),
                form: form,
                platform: platform,
                model: m,
              ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => _openAddModel(context),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('添加模型'),
          ),
          if (canReset) ...[
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => _confirmResetPlatform(context),
                icon: const Icon(Icons.restore, size: 18),
                label: const Text('重置为内置预置'),
              ),
            ),
          ],
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _canRemove ? () => _confirmRemovePlatform(context) : null,
              icon: Icon(
                Icons.delete_outline,
                size: 18,
                color: _canRemove
                    ? Theme.of(context).colorScheme.error
                    : Theme.of(context).disabledColor,
              ),
              label: Text(
                '删除此平台',
                style: TextStyle(
                  color: _canRemove
                      ? Theme.of(context).colorScheme.error
                      : Theme.of(context).disabledColor,
                ),
              ),
            ),
          ),
          if (!_canRemove)
            Text(
              '至少需要保留一个平台。',
              style: TextStyle(fontSize: 11, color: onSurfaceVariant),
            ),
        ],
      ),
    );
  }

  Future<void> _openAddModel(BuildContext context) async {
    final result = await showDialog<_AddedModel>(
      context: context,
      builder: (_) => const _AddModelDialog(),
    );
    if (result == null) return;
    form.addModel(platform.id, id: result.id, shortLabel: result.shortLabel);
  }

  /// 重置为内置预置（二次确认）：只影响当前平台，API Key 与其它平台不受影响。
  Future<void> _confirmResetPlatform(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重置为内置预置'),
        content: Text(
          '确定把平台「${platform.displayName}」恢复为软件内置预置吗？'
          '该平台的连接设置、模型列表与全部参数都将还原；'
          'API Key 与其它平台不受影响。\n\n'
          '重置为编辑态，点击右上角「保存」后写入配置文件。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              form.resetPlatform(platform.id);
            },
            child: const Text('重置'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmRemovePlatform(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除平台'),
        content: Text('确定删除平台「${platform.displayName}」吗？该平台下的全部模型配置将一并删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              form.removePlatform(platform.id);
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 平台的连接设置：API 类型 + Base URL + API Key（自定义平台额外含平台名）
// ---------------------------------------------------------------------------
class _PlatformSettings extends StatelessWidget {
  final SettingsFormState form;
  final AiPlatform platform;

  const _PlatformSettings({required this.form, required this.platform});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: form.nameCtrlFor(platform.id),
          onTapOutside: unfocusOnTapOutside,
          onChanged: (v) => form.setPlatformName(platform.id, v),
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
          value: platform.apiType.id,
          items: [
            for (final t in ApiType.all)
              DropdownMenuItem(value: t.id, child: Text(t.displayName)),
          ],
          onChanged: (v) {
            if (v != null && v != platform.apiType.id) {
              form.setPlatformApiType(platform.id, v);
            }
          },
        ),
        const SizedBox(height: 12),
        TextField(
          controller: form.baseUrlCtrlFor(platform.id),
          onTapOutside: unfocusOnTapOutside,
          onChanged: (v) => form.setPlatformBaseUrl(platform.id, v),
          decoration: const InputDecoration(
            labelText: 'Base URL',
            hintText: 'https://api.deepseek.com',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 12),
        _ApiKeyField(controller: form.apiKeyCtrlFor(platform.id)),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// API Key 输入框（自行管理明文/隐藏，独立可复用）
// ---------------------------------------------------------------------------
class _ApiKeyField extends StatefulWidget {
  final TextEditingController controller;

  const _ApiKeyField({required this.controller});

  @override
  State<_ApiKeyField> createState() => _ApiKeyFieldState();
}

class _ApiKeyFieldState extends State<_ApiKeyField> {
  bool _obscured = true;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: widget.controller,
      onTapOutside: unfocusOnTapOutside,
      obscureText: _obscured,
      enableSuggestions: false,
      autocorrect: false,
      decoration: InputDecoration(
        labelText: 'API Key',
        hintText: 'sk-…（保存至系统安全存储）',
        border: const OutlineInputBorder(),
        isDense: true,
        suffixIcon: IconButton(
          icon: Icon(_obscured ? Icons.visibility_off : Icons.visibility),
          tooltip: _obscured ? '显示' : '隐藏',
          onPressed: () => setState(() => _obscured = !_obscured),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 模型可展开条目：模型名 + 删除按钮（自定义平台）→ 缩进展示该模型设置
// ---------------------------------------------------------------------------
class _ModelExpandableItem extends StatelessWidget {
  final SettingsFormState form;
  final AiPlatform platform;
  final AiModel model;

  const _ModelExpandableItem({
    super.key,
    required this.form,
    required this.platform,
    required this.model,
  });

  @override
  Widget build(BuildContext context) {
    // 每个平台至少保留一个模型；预置平台上用户自建的模型同样可删。
    final canDelete = platform.models.length > 1;
    return ExpandableCard(
      title: Row(
        children: [
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
                    text: '  ${model.id}',
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
          if (canDelete)
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
                onPressed: () => _confirmRemoveModel(context),
              ),
            ),
        ],
      ),
      child: _ModelSettingsEditor(
        // 平台重置后按 key 重建：模型编辑器自带文本控制器，需重建以丢弃旧文本
        // （卡片自身的展开状态由 ExpandableCard 持有，不受影响）。
        key: ValueKey(
          'model-editor-${platform.id}-${model.id}-${form.resetRevision}',
        ),
        form: form,
        platformId: platform.id,
        model: model,
        apiType: platform.apiType,
      ),
    );
  }

  Future<void> _confirmRemoveModel(BuildContext context) async {
    await showDialog<void>(
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
              form.removeModel(platform.id, model.id);
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 单个模型的设置编辑器（每个模型各自展开，独立编辑自己的参数）
// ---------------------------------------------------------------------------
class _ModelSettingsEditor extends StatefulWidget {
  final SettingsFormState form;
  final String platformId;
  final AiModel model;
  final ApiType apiType;

  const _ModelSettingsEditor({
    super.key,
    required this.form,
    required this.platformId,
    required this.model,
    required this.apiType,
  });

  @override
  State<_ModelSettingsEditor> createState() => _ModelSettingsEditorState();
}

class _ModelSettingsEditorState extends State<_ModelSettingsEditor> {
  late final TextEditingController _shortLabelCtrl;
  late final TextEditingController _maxTokensCtrl;

  @override
  void initState() {
    super.initState();
    _shortLabelCtrl = TextEditingController(text: widget.model.shortLabel);
    _maxTokensCtrl = TextEditingController(
      text: widget.model.maxTokens?.toString() ?? '',
    );
  }

  @override
  void dispose() {
    _shortLabelCtrl.dispose();
    _maxTokensCtrl.dispose();
    super.dispose();
  }

  /// 从工作副本取当前模型，避免连续编辑时基于旧快照丢更新。
  AiModel? _currentModel() {
    for (final p in widget.form.platforms) {
      if (p.id != widget.platformId) continue;
      return p.modelById(widget.model.id);
    }
    return null;
  }

  void _update(AiModel Function(AiModel) fn) {
    final current = _currentModel();
    if (current == null) return;
    widget.form.updateModel(widget.platformId, widget.model.id, fn(current));
  }

  /// 可调配功能的开关行（预置模型同样可自由调整，改动后可整平台重置）。
  Widget _capabilitySwitch(String label, bool value, ValueChanged<bool> onChanged) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(label, style: const TextStyle(fontSize: 14)),
      value: value,
      onChanged: onChanged,
    );
  }

  @override
  Widget build(BuildContext context) {
    final outline = Theme.of(context).colorScheme.outline;
    final apiType = widget.apiType;
    final model = _currentModel() ?? widget.model;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _shortLabelCtrl,
          onTapOutside: unfocusOnTapOutside,
          onChanged: (v) => _update((m) => m.copyWith(shortLabel: v)),
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
        Text(
          '可调配功能（Chat 页对话框内可选）',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 4),
        _capabilitySwitch(
          '流式',
          model.supportsStreaming,
          (v) => _update((m) => m.copyWith(supportsStreaming: v)),
        ),
        _capabilitySwitch(
          '思考',
          model.supportsThinking,
          (v) => _update((m) => m.copyWith(supportsThinking: v)),
        ),
        _capabilitySwitch(
          '联网搜索',
          model.supportsSearch,
          (v) => _update((m) => m.copyWith(supportsSearch: v)),
        ),
        _capabilitySwitch(
          '识图',
          model.supportsVision,
          (v) => _update((m) => m.copyWith(supportsVision: v)),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            const Text('温度', style: TextStyle(fontSize: 14)),
            const SizedBox(width: 8),
            Text(
              model.temperature.toStringAsFixed(1),
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
          value: model.temperature,
          min: 0,
          max: 2,
          divisions: 20,
          label: model.temperature.toStringAsFixed(1),
          onChanged: (v) => _update((m) => m.copyWith(temperature: v)),
        ),
        const SizedBox(height: 4),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppDropdown<String>(
              label: '推理强度（reasoning_effort）',
              value: model.reasoningEffort,
              items: [
                for (final e in const ['low', 'high', 'max'])
                  DropdownMenuItem(value: e, child: Text(e)),
              ],
              onChanged: (v) {
                if (v != null) _update((m) => m.copyWith(reasoningEffort: v));
              },
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
              controller: _maxTokensCtrl,
              onTapOutside: unfocusOnTapOutside,
              keyboardType: TextInputType.number,
              onChanged: (v) => _update(
                (m) => m.copyWith(maxTokens: int.tryParse(v.trim())),
              ),
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
      ],
    );
  }
}

/// 新增自定义平台对话框的返回数据。
class _AddedPlatform {
  final String name;
  final String baseUrl;
  final String apiTypeId;
  final String apiKey;

  const _AddedPlatform({
    required this.name,
    required this.baseUrl,
    required this.apiTypeId,
    required this.apiKey,
  });
}

/// 新增自定义平台对话框：平台名 + Base URL + API 类型（Response / Chat 兼容）+ API Key。
class _AddPlatformDialog extends StatefulWidget {
  const _AddPlatformDialog();

  @override
  State<_AddPlatformDialog> createState() => _AddPlatformDialogState();
}

class _AddPlatformDialogState extends State<_AddPlatformDialog> {
  final _nameCtrl = TextEditingController();
  final _baseUrlCtrl = TextEditingController();
  final _apiKeyCtrl = TextEditingController();
  String _apiType = ApiType.openAiResponsesId;

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
      _AddedPlatform(
        name: name,
        baseUrl: baseUrl,
        apiTypeId: _apiType,
        apiKey: _apiKeyCtrl.text,
      ),
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
