import 'package:flutter/material.dart';

import '../models/round_send_intent.dart';
import '../providers/round_provider.dart';
import '../theme/app_theme.dart';

/// 输入卡「临时用途」的意图工厂（按发送键 / Ctrl+Enter 提交时调用）。
///
/// - [text]：提交瞬间的主输入框文本（已 trim，非空）；
/// - [images]：提交瞬间的待发送图片（相对路径，只读副本）；
/// - 返回**发送意图**（[RoundSendIntent]）：用途自己只描述「这次要做什么」，
///   请求体一律由 `RoundProvider` 按当前状态现算——**实发与「预览请求体」共用
///   同一份意图**，因此灰条用途不会出现「预览拼的是一套、实发拼的是另一套」。
///
/// 约定：灰条用途**一律直接上屏、不弹二次确认**——用户「进入用途 + 填写 + 按发送」
/// 已是明确意图（需要确认的破坏性入口不经输入框，如「刷新本轮」）。
/// 新增用途请沿用本约定，别在提交动作里再加确认框。
typedef ComposerIntentBuilder =
    RoundSendIntent Function({
      required String text,
      required List<String> images,
    });

/// 输入卡「临时用途」的有效性检查（提交 / 预览前调用）。
///
/// 返回提示文案 = 用途已失效（如目标轮次或失败条目已被删除）：调用方收起灰条并
/// 提示，不发出请求。**预览请求体与实发共用同一检查**，两边判定不会漂移。
typedef ComposerIntentGuard = String? Function(RoundProvider roundProvider);

/// 底部输入卡的一次「临时用途」（灰条形态，对齐 DeepSeek APP 的「修改输入」）。
///
/// 形态：输入卡顶部一条浅灰横条，左侧写明这次输入要干什么、右侧一个删除键
/// 退出；正文区仍是同一个主输入框——Markdown 高亮、图片条、粘贴 / 拖拽 /
/// 快捷键全部复用——按发送键才执行本次用途，而不是发出新一轮。
///
/// **新增一个用途（如后续的「按要求修改」）只需三步**：
/// 1. 构造本对象：给出灰条文案 [label] 与意图工厂 [buildIntent]
///    （用途自身已失效的场景可另给 [guard]）；
/// 2. 调用 `_ChatScreenState._enterInputMode(mode, text:, images:)`，
///    把已有内容载入输入框并亮出灰条；
/// 3. 在气泡菜单 / 悬浮按钮等处挂入口（退出统一由 [ComposerInputModeBar]
///    的删除键触发，无需自己实现）。
@immutable
class ComposerInputMode {
  const ComposerInputMode({
    required this.label,
    required this.buildIntent,
    this.guard,
  });

  /// 灰条左侧文案（如「修改并重新提问（第 3 轮）」）。
  final String label;

  /// 意图工厂：把「本次输入」翻译成发送意图（见 [ComposerIntentBuilder]）。
  final ComposerIntentBuilder buildIntent;

  /// 用途有效性检查（可空 = 由 Provider 的意图校验兜底）。
  final ComposerIntentGuard? guard;
}

/// 输入卡顶部的「临时用途」灰条：左侧文案 + 右侧删除键。
///
/// 全宽铺满输入卡顶部（卡片圆角由外层裁剪），与下方输入区以一条细线分隔。
class ComposerInputModeBar extends StatelessWidget {
  /// 灰条本体（测试定位）。
  static const Key barKey = Key('composer_input_mode_bar');

  /// 右侧删除键（测试定位）。
  static const Key cancelKey = Key('composer_input_mode_cancel');

  /// 灰条左侧文案。
  final String label;

  /// 删除键回调：退出本次临时用途。
  final VoidCallback onCancel;

  const ComposerInputModeBar({
    super.key,
    required this.label,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: barKey,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        border: Border(bottom: BorderSide(color: context.narrColors.divider)),
      ),
      padding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                color: context.narrColors.textSecondary,
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            key: cancelKey,
            onPressed: onCancel,
            tooltip: '退出',
            iconSize: 16,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 28, height: 28),
            style: IconButton.styleFrom(
              backgroundColor: scheme.surface,
              foregroundColor: scheme.onSurfaceVariant,
            ),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }
}
