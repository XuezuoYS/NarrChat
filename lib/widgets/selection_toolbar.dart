import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 恒为**横排**的浮动选项条：选中文本的「复制 / 全选」、输入框的「全选 / 复制 /
/// 粘贴 / 剪切」都用它。
///
/// **为什么自绘**：框架的 `AdaptiveTextSelectionToolbar` 按平台分派——桌面
/// （Windows / Linux / macOS）走 `DesktopTextSelectionToolbar`，内部是 `Column`，
/// 即**竖排列表**（`desktop_text_selection_toolbar.dart:83`）；Android 是横排但放
/// 不下时会折叠成「⋮」+ 竖排面板；iOS 也是竖排卡片。本应用要各平台一致的横条，
/// 故自绘；定位仍复用框架的 [TextSelectionToolbarLayoutDelegate]（浮在选区上方，
/// 上方放不下翻到下方，并在屏幕边缘内收）。
class SelectionToolbar extends StatelessWidget {
  const SelectionToolbar({
    super.key,
    required this.anchors,
    required this.items,
  });

  /// 选区锚点（`SelectableRegionState.contextMenuAnchors` /
  /// `EditableTextState.contextMenuAnchors` 的原样透传）。
  final TextSelectionToolbarAnchors anchors;

  /// 选项（只取 [ContextMenuButtonItem.label] 与 `onPressed`；label 为空的项跳过）。
  final List<ContextMenuButtonItem> items;

  @override
  Widget build(BuildContext context) {
    // 卡片视觉与应用其它浮层（气泡右键菜单 / 下拉菜单，见 `NarrChatTheme`
    // 的 popupMenuTheme）同一口径：**白色卡片**（浅色主题下 `surface` 即纯白，
    // 深色主题自动转深灰）、圆角 12、阴影 3。
    final colors = context.narrColors;
    return CustomSingleChildLayout(
      delegate: TextSelectionToolbarLayoutDelegate(
        anchorAbove: anchors.primaryAnchor,
        // 无下方锚点时退回上方锚点（与框架 `AdaptiveTextSelectionToolbar` 同一口径）。
        anchorBelow: anchors.secondaryAnchor ?? anchors.primaryAnchor,
      ),
      child: Material(
        elevation: 3,
        color: colors.surface,
        borderRadius: BorderRadius.circular(NarrChatTheme.menuRadius),
        child: Padding(
          // 上下留白：横条要「微微鼓起来」，不是紧贴文字的窄条。
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final item in items)
                if (item.label != null)
                  TextButton(
                    onPressed: item.onPressed,
                    style: TextButton.styleFrom(
                      foregroundColor: colors.textPrimary,
                      // 不用 visualDensity.compact：它会把高度再压掉 8px，
                      // 与「上下留白略微放大」的诉求相反。
                      minimumSize: const Size(0, 30),
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      textStyle: const TextStyle(fontSize: 14),
                      shape: const RoundedRectangleBorder(
                        borderRadius: BorderRadius.all(Radius.circular(8)),
                      ),
                    ),
                    child: Text(item.label!),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}
