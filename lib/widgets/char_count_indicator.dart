import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../utils/text_stats.dart';

/// 字数指示器的字号：比模型名（12）小一号，形成「模型名 > 字数」的层级。
const double _kCharCountIndicatorFontSize = 11;

/// 行高：与模型选择器的两行文字同款紧行高，贴合上行模型名。
const double _kCharCountIndicatorLineHeight = 1.25;

/// 输入框实时字数指示器（中英文字 / 标点 / 空格 / 表情各计 1）。
///
/// 用法：由 `ModelStatusCaption` 组合成模型选择器触发区的**第二行**——
/// 左侧为思考强度、右侧为本组件；两者贴合成一个整体，且整行属于选择器热区
/// （点字数即可展开模型菜单）。宽度不足时强度先省略，字数完整显示。
///
/// 设计要点：
/// - **常驻显示**：空输入显示 `0 字`（弱化为占位色），让「有字数统计」这件事
///   可被发现；有输入后转为次级文字色，形成轻微的强调变化。
/// - **宽度随内容 + 右对齐 + 等宽数字**：与左侧强度保持固定的小间距；
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
        return Text(
          '${TextStats.groupThousands(count)} 字',
          textAlign: TextAlign.right,
          maxLines: 1,
          // 极长文本（7 位以上）超出可用宽度时省略，绝不撑破所在列。
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: _kCharCountIndicatorFontSize,
            height: _kCharCountIndicatorLineHeight,
            color: count == 0 ? colors.placeholder : colors.textSecondary,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        );
      },
    );
  }
}
