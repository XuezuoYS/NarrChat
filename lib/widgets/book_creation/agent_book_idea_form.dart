import 'package:flutter/material.dart';

import '../../providers/ai_settings_provider.dart';
import '../../theme/app_theme.dart';
import '../../utils/focus_utils.dart';
import '../model_selector.dart';
import '../settings/settings_kit.dart';

/// 「Agent 创建新书」输入态的界面：满宽 Markdown 输入框 + 生成模型 + 开始按钮。
///
/// 纯展示组件：文字控制器、模型选择状态、二次确认与流程编排都在页面里，
/// 这样在「创建态 → 返回编辑」时输入内容不会随子组件销毁而丢失。
class AgentBookIdeaForm extends StatelessWidget {
  const AgentBookIdeaForm({
    super.key,
    required this.controller,
    required this.settings,
    required this.platformId,
    required this.modelId,
    required this.reasoningEffort,
    required this.onModelSelected,
    required this.onStart,
  });

  /// 创意输入框控制器（由页面持有，跨阶段保留内容）。
  final TextEditingController controller;

  /// AI 设置（模型列表 / 记忆的思考强度）。
  final AiSettingsProvider settings;

  /// 当前选中的平台与模型（页面本地状态，不写回全局）。
  final String platformId;
  final String modelId;

  /// 本次本地选择的思考强度；null = 沿用 `settings.reasoningEffortFor`。
  final String? reasoningEffort;

  /// 选择模型 / 思考强度。
  final void Function(
    String platformId,
    String modelId,
    String? reasoningEffort,
  ) onModelSelected;

  /// 开始创建（页面负责二次确认）；空输入时传 null 禁用按钮。
  final VoidCallback? onStart;

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    final scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SettingsPageHeader(
            title: '用一句话描述你想创建的书',
            description: 'AI 会据此生成书名、分类、Mod、基础设定、世界书、'
                '前后置词、文笔要求与角色类别，创建完成后仍可在书籍设置里修改。',
          ),
          SettingsCard(
            padding: const EdgeInsets.all(14),
            child: TextField(
              key: const ValueKey('agent_book_idea_field'),
              controller: controller,
              maxLines: null,
              minLines: 10,
              keyboardType: TextInputType.multiline,
              textAlignVertical: TextAlignVertical.top,
              onTapOutside: unfocusOnTapOutside,
              style: TextStyle(
                fontSize: 14,
                height: 1.65,
                color: colors.textPrimary,
              ),
              decoration: InputDecoration(
                border: InputBorder.none,
                isDense: true,
                hintText: '例如：一个现代都市里隐藏的妖灵事务所，'
                    '主角白天是普通大学生，夜里替妖怪处理委托。\n\n'
                    '输入内容不会被保存',
                hintStyle: TextStyle(
                  fontSize: 14,
                  height: 1.65,
                  color: colors.placeholder,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.lock_outline, size: 14, color: colors.textSecondary),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  '输入内容不会被保存，只用于本次生成',
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          LayoutBuilder(
            builder: (context, constraints) {
              final modelBlock = Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '生成模型',
                    style: TextStyle(
                      fontSize: 13,
                      color: colors.textSecondary,
                    ),
                  ),
                  const SizedBox(width: 6),
                  ModelSelector(
                    platforms: settings.platforms,
                    selectedPlatformId: platformId,
                    selectedModelId: modelId,
                    reasoningEffortFor: (platform, model) {
                      if (platform.id == platformId &&
                          model.id == modelId &&
                          reasoningEffort != null &&
                          reasoningEffort!.isNotEmpty) {
                        return reasoningEffort!;
                      }
                      return settings.reasoningEffortFor(platform, model);
                    },
                    onSelect: onModelSelected,
                  ),
                ],
              );
              final start = FilledButton.icon(
                key: const ValueKey('agent_book_start_button'),
                onPressed: onStart,
                icon: const Icon(Icons.auto_awesome, size: 18),
                label: const Text('开始创建'),
              );
              if (constraints.maxWidth < 560) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(alignment: Alignment.centerLeft, child: modelBlock),
                    const SizedBox(height: 14),
                    SizedBox(width: double.infinity, child: start),
                  ],
                );
              }
              return Row(
                children: [
                  modelBlock,
                  const Spacer(),
                  start,
                ],
              );
            },
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(NarrChatTheme.controlRadius),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.info_outline,
                  size: 15,
                  color: colors.textSecondary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '创建会按步骤调用 AI（约 5 次）；内容不完整时会自动补充 1~2 次。'
                    '过程可能失败并产生 Token 消耗，失败后会回到本页，输入内容仍然保留。',
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.5,
                      color: colors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
