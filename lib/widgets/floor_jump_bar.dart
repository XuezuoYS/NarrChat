import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../utils/focus_utils.dart';

/// 楼层跳转悬浮条：横向长条，分三段——左箭头（上一轮起点）、
/// 中间数字（当前屏幕中的轮次，点击可输入）、右箭头（下一轮起点）。
///
/// - 中间数字未编辑时随 [currentRound] 自动同步；聚焦输入后不再覆盖，
///   回车（或输入法 done）触发 [onJumpTo]，随后失焦并回写当前轮次；
/// - 左箭头在无可跳转的上一轮时禁用（[canPrev] 为 false）；
/// - 右箭头始终可用：最后一轮时由调用方滚动到列表末尾。
class FloorJumpBar extends StatefulWidget {
  /// 当前屏幕中的轮次。
  final int currentRound;

  /// 允许输入的最大轮次（最后一轮的 roundIndex）。
  final int maxRound;

  /// 是否存在可跳转的上一轮（非第 1 轮且未处于第 1 轮起点）。
  final bool canPrev;

  final VoidCallback onPrev;
  final VoidCallback onNext;
  final ValueChanged<int> onJumpTo;

  const FloorJumpBar({
    super.key,
    required this.currentRound,
    required this.maxRound,
    required this.canPrev,
    required this.onPrev,
    required this.onNext,
    required this.onJumpTo,
  });

  @override
  State<FloorJumpBar> createState() => _FloorJumpBarState();
}

class _FloorJumpBarState extends State<FloorJumpBar> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  /// 用户是否正在编辑（聚焦且有输入/光标）；编辑期间不覆盖文本。
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    _controller.text = '${widget.currentRound}';
    _focusNode.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(covariant FloorJumpBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 外部轮次变化（滚动/跳转）时同步显示；用户编辑中不打断输入。
    if (!_editing && widget.currentRound != oldWidget.currentRound) {
      _controller.text = '${widget.currentRound}';
    }
  }

  void _onFocusChanged() {
    // 失焦（回车/点外部）结束编辑态并回写当前轮次。
    if (!_focusNode.hasFocus && _editing) {
      _editing = false;
      _controller.text = '${widget.currentRound}';
    }
  }

  void _onSubmitted(String value) {
    final n = int.tryParse(value.trim());
    if (n != null) {
      final target = n.clamp(1, widget.maxRound);
      // 立即回写目标轮次，避免检测完成前短暂显示旧值。
      _controller.text = '$target';
      widget.onJumpTo(target);
    } else {
      _controller.text = '${widget.currentRound}';
    }
    // 收起键盘/输入法焦点（触发 _onFocusChanged 同步）。
    _focusNode.unfocus();
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      elevation: 3,
      shadowColor: Colors.black.withValues(alpha: 0.18),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: context.narrColors.divider),
      ),
      child: SizedBox(
        height: 36,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              onPressed: widget.canPrev ? widget.onPrev : null,
              icon: Icon(
                Icons.chevron_left,
                size: 20,
                color: widget.canPrev
                    ? scheme.onSurfaceVariant
                    : scheme.outlineVariant,
              ),
              tooltip: '上一轮起点',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            ),
            SizedBox(
              width: 46,
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                textAlign: TextAlign.center,
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.done,
                onTapOutside: unfocusOnTapOutside,
                onChanged: (_) {
                  if (_focusNode.hasFocus) _editing = true;
                },
                onSubmitted: _onSubmitted,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: context.narrColors.textPrimary,
                ),
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(vertical: 8),
                ),
              ),
            ),
            IconButton(
              onPressed: widget.onNext,
              icon: Icon(
                Icons.chevron_right,
                size: 20,
                color: scheme.onSurfaceVariant,
              ),
              tooltip: '下一轮起点',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            ),
          ],
        ),
      ),
    );
  }
}
