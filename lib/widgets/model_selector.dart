import 'package:flutter/material.dart';

import '../models/ai_platform.dart';

/// 模型选择回调。
///
/// [reasoningEffort] 非空表示「同时选中了该模型的思考强度」；为 `null` 表示
/// 该模型不支持思考（只切换模型，不改动它原本记住的强度）。
typedef ModelSelectedCallback = void Function(
  String platformId,
  String modelId,
  String? reasoningEffort,
);

/// 右下角模型选择器：上行当前模型名，下行可选小字说明（由调用方传入）。
///
/// 菜单分两层：
/// 1. **模型列表**（与旧实现一致）：平台分组 → 模型；当前模型用勾选 +
///    主题色标注，且**只有它**显示记住的思考强度；不支持思考的模型灰字标注
///    「无思考」，点击直接切换；
/// 2. **思考强度面板**：点击支持思考的模型后进入，第一行显示该模型名，下面
///    列出档位（来自模型配置或内置预置），当前档位打勾；选中后模型与强度
///    一起生效并关闭菜单（中途返回 / 点外面取消都不会改动选择）。
///
/// 每次重新打开菜单都会回到模型列表；二级面板只存在于当前一次交互内。
class ModelSelector extends StatefulWidget {
  const ModelSelector({
    super.key,
    required this.platforms,
    required this.selectedPlatformId,
    required this.selectedModelId,
    required this.reasoningEffortFor,
    required this.onSelect,
    this.thinkingEnabled = true,
    this.caption,
  });

  /// 全部平台（含模型与能力表）。
  final List<AiPlatform> platforms;

  final String selectedPlatformId;
  final String selectedModelId;

  /// 读取指定模型在 Chat 页记住的思考强度。
  final String Function(AiPlatform platform, AiModel model) reasoningEffortFor;

  /// 选中模型（以及可选的思考强度）。
  final ModelSelectedCallback onSelect;

  /// 本轮是否真的会发送思考强度（Agent 强制开启时为 true）。
  ///
  /// 只用于强度面板的说明文案——本轮思考关闭时选强度依然会记住，
  /// 下次开启思考才生效。
  final bool thinkingEnabled;

  /// 第二行小字（通常为「思考强度 · 实时字数」），随触发区一起点击。
  final Widget? caption;

  @override
  State<ModelSelector> createState() => _ModelSelectorState();
}

class _ModelSelectorState extends State<ModelSelector> {
  /// 两行文字的行高：比默认行高更紧，让模型名与下行小字贴合成一个整体。
  static const double _lineHeight = 1.25;

  /// 二级面板里模型名 / 说明的最大宽度，避免超长名字把菜单撑得过宽。
  static const double _strengthHeaderMaxWidth = 240;

  // 二级面板当前目标（存 id 而非对象，平台列表刷新后仍能重新解析）。
  String? _targetPlatformId;
  String? _targetModelId;

  AiModel? get _selectedModel {
    for (final platform in widget.platforms) {
      if (platform.id != widget.selectedPlatformId) continue;
      return platform.modelById(widget.selectedModelId);
    }
    return null;
  }

  String get _selectedLabel {
    final model = _selectedModel;
    if (model != null) return model.displayLabel;
    if (widget.platforms.isEmpty) return '';
    return widget.platforms.first.defaultModel.displayLabel;
  }

  /// 当前二级面板目标；目标已不存在（平台被删等）时返回 null，自然回落到列表。
  ({AiPlatform platform, AiModel model})? get _target {
    final platformId = _targetPlatformId;
    final modelId = _targetModelId;
    if (platformId == null || modelId == null) return null;
    for (final platform in widget.platforms) {
      if (platform.id != platformId) continue;
      final model = platform.modelById(modelId);
      if (model != null) return (platform: platform, model: model);
    }
    return null;
  }

  void _resetTarget() {
    _targetPlatformId = null;
    _targetModelId = null;
  }

  bool _isSelected(AiPlatform platform, AiModel model) =>
      platform.id == widget.selectedPlatformId &&
      model.id == widget.selectedModelId;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final gray = scheme.onSurfaceVariant;
    final target = _target;
    return MenuAnchor(
      animated: true,
      style: MenuStyle(
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      // 关闭动画结束后清掉二级目标：下次打开永远从模型列表开始，
      // 既不会在淡出过程中闪回列表，也不会让菜单停在上次的强度面板。
      onAnimationStatusChanged: (status) {
        if (status == AnimationStatus.dismissed && _targetModelId != null) {
          setState(_resetTarget);
        }
      },
      menuChildren: target == null
          ? _modelMenuItems(gray, scheme)
          : _strengthMenuItems(target.platform, target.model, gray, scheme),
      builder: (context, controller, _) {
        return InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () {
            if (controller.isOpen) {
              controller.close();
            } else {
              // 极端情况下（关闭动画尚未走完）立即重开：先复位，避免闪现二级面板。
              if (_targetModelId != null) setState(_resetTarget);
              controller.open();
            }
          },
          child: Padding(
            // 上下 4：两行文字整体高度与发送按钮（36）持平，控件行不额外长高。
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    // 右对齐：下行小字的右边界与模型名右边界严格对齐。
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        _selectedLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          height: _lineHeight,
                          color: gray,
                        ),
                      ),
                      // 无下行小字时整行不占位（null-aware 元素）。
                      ?widget.caption,
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  controller.isOpen
                      ? Icons.arrow_drop_up
                      : Icons.arrow_drop_down,
                  size: 18,
                  color: gray,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 一级菜单：平台分组标题 + 每个模型一行。
  List<Widget> _modelMenuItems(Color gray, ColorScheme scheme) {
    final items = <Widget>[];
    for (final platform in widget.platforms) {
      items.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Text(
            platform.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: gray,
            ),
          ),
        ),
      );
      for (final model in platform.models) {
        items.add(_modelMenuItem(platform, model, gray, scheme));
      }
    }
    return items;
  }

  Widget _modelMenuItem(
    AiPlatform platform,
    AiModel model,
    Color gray,
    ColorScheme scheme,
  ) {
    final selected = _isSelected(platform, model);
    final supportsThinking = model.supportsThinking;
    final effort = widget.reasoningEffortFor(platform, model);
    return MenuItemButton(
      // 支持思考：保持展开并进入强度面板；不支持：点击即选中并关闭菜单。
      closeOnActivate: !supportsThinking,
      onPressed: () {
        if (supportsThinking) {
          setState(() {
            _targetPlatformId = platform.id;
            _targetModelId = model.id;
          });
        } else {
          widget.onSelect(platform.id, model.id, null);
        }
      },
      child: Row(
        children: [
          Icon(
            selected ? Icons.check : Icons.label_outline,
            size: 16,
            color: selected ? scheme.primary : gray,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              model.displayLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                color: selected ? scheme.primary : null,
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
          if (!supportsThinking)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text('无思考', style: TextStyle(fontSize: 11, color: gray)),
            )
          else ...[
            if (selected)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 96),
                  child: Text(
                    effort,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            const SizedBox(width: 2),
            Icon(Icons.chevron_right, size: 16, color: gray),
          ],
        ],
      ),
    );
  }

  /// 二级菜单：第一行（返回 + 模型名 + 说明）+ 思考强度档位。
  List<Widget> _strengthMenuItems(
    AiPlatform platform,
    AiModel model,
    Color gray,
    ColorScheme scheme,
  ) {
    final current = widget.reasoningEffortFor(platform, model);
    // 档位去重、丢掉空值；当前值不在列表时补到首位（不静默改写用户值）。
    final seen = <String>{};
    final options = <String>[];
    for (final raw in model.effectiveReasoningEffortOptions) {
      final value = raw.trim();
      if (value.isEmpty) continue;
      if (seen.add(value)) options.add(value);
    }
    if (!seen.contains(current)) options.insert(0, current);

    return [
      MenuItemButton(
        closeOnActivate: false,
        onPressed: () => setState(_resetTarget),
        leadingIcon: Icon(Icons.arrow_back, size: 16, color: gray),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _strengthHeaderMaxWidth),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                model.displayLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                widget.thinkingEnabled ? '选择思考强度' : '本轮思考已关闭，所选强度将在开启思考后生效',
                style: TextStyle(fontSize: 11, color: gray),
              ),
            ],
          ),
        ),
      ),
      const Divider(height: 8),
      for (final effort in options)
        MenuItemButton(
          onPressed: () => widget.onSelect(platform.id, model.id, effort),
          leadingIcon: Icon(
            effort == current ? Icons.check_circle : Icons.circle_outlined,
            size: 15,
            color: effort == current ? scheme.primary : gray,
          ),
          child: Text(
            effort,
            style: TextStyle(
              fontSize: 13,
              color: effort == current ? scheme.primary : null,
              fontWeight: effort == current
                  ? FontWeight.w600
                  : FontWeight.normal,
            ),
          ),
        ),
    ];
  }
}
