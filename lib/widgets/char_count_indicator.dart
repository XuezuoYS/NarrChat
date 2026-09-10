import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../utils/text_stats.dart';

/// 字数指示器的固定占位宽度（px）：位数变化时右对齐边不抖动，
/// 极窄场景由父级约束夹取，不会撑破底部控件行。
const double _kCharCountIndicatorWidth = 56;

/// 字数指示器的字号：比模型名（12）小一号，形成「模型名 > 字数」的层级。
const double _kCharCountIndicatorFontSize = 11;

/// 行高：与模型选择器的两行文字同款紧行高，贴合上行模型名。
const double _kCharCountIndicatorLineHeight = 1.25;

/// 输入框实时字数指示器（中英文字 / 标点 / 空格 / 表情各计 1）。
///
/// 用法：作为模型选择器触发区的**第二行小字**（与模型名同列右对齐）——两行
/// 贴合成一个整体，让底部控件行不再单薄；同时也让字数成为选择器热区的一部分，
/// 点字数即可展开模型菜单。字数不参与横向争抢，模型名宽度不受其位数影响。
///
/// 设计要点：
/// - **常驻显示**：空输入显示 `0 字`（弱化为占位色），让「有字数统计」这件事
///   可被发现；有输入后转为次级文字色，形成轻微的强调变化。
/// - **固定占位 + 右对齐 + 等宽数字**：位数增长不推动相邻控件，
///   等宽数字避免 `1` 与 `8` 宽度差造成的逐位抖动。
/// - **仅本子树随键入重建**：内部监听控制器，调用方无需为每次键入重建整行。
class CharCountIndicator extends StatelessWidget {
  const CharCountIndicator({super.key, required this.controller});

  /// 被统计的输入控制器。
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final count = TextStats.charCount(value.text);
        return Tooltip(
          message: '字数统计：中英文字、标点、空格、表情各计 1（点击可切换模型）',
          child: SizedBox(
            width: _kCharCountIndicatorWidth,
            child: Text(
              '${TextStats.groupThousands(count)} 字',
              textAlign: TextAlign.right,
              maxLines: 1,
              // 极长文本（7 位以上）超出占位时省略，绝不撑破所在列。
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: _kCharCountIndicatorFontSize,
                height: _kCharCountIndicatorLineHeight,
                color: count == 0 ? colors.placeholder : colors.textSecondary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        );
      },
    );
  }
}
