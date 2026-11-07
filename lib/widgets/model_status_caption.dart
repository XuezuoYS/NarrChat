import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'char_count_indicator.dart';

/// 模型选择器触发区的第二行：思考强度 + 实时字数。
///
/// 布局语义（对应底栏「模型名 / 强度 · 字数」两行结构）：
/// - 宽度不足时**先省略思考强度与分隔符**（[Flexible] + ellipsis）；字数宽度
///   随内容自然变化，与强度之间始终保持一个固定空格间距，并整体右对齐；
/// - 字数复用 [CharCountIndicator]：它内部监听输入控制器，只有本子树随键入重建。
///
/// 强度文案由调用方计算（是否支持思考、本轮思考开关、Agent 强制状态都在
/// Chat 页），本组件只负责显示与省略规则。
class ModelStatusCaption extends StatelessWidget {
  const ModelStatusCaption({
    super.key,
    required this.strengthLabel,
    required this.controller,
  });

  /// 模型不支持思考时的统一标注。
  static const String noThinkingLabel = '【无思考】';

  /// 支持思考、但本轮「思考」开关关闭时的统一标注。
  static const String thinkingOffLabel = '【思考off】';

  /// 思考强度文案（正常时为档位值，特殊状态为上面两个标注之一）。
  final String strengthLabel;

  /// 被统计的输入控制器（转交给 [CharCountIndicator]）。
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    final style = TextStyle(
      fontSize: 11,
      height: 1.25,
      color: colors.textSecondary,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 强度与分隔符放在同一个可伸缩文本里：空间不足时一起省略；
            // 字数紧随其后（末尾空格即固定间距），其宽度随位数自然变化。
            Flexible(
              child: Text(
                '$strengthLabel · ',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
            ),
            // 字数最多占满整行：极窄时先由强度让位，仍放不下才省略字数，
            // 但绝不会撑破所在列（非 flex 子节点默认不受 Row 宽度约束）。
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: constraints.maxWidth),
              child: CharCountIndicator(controller: controller),
            ),
          ],
        );
      },
    );
  }
}
