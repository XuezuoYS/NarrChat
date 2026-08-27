import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

/// 只读 UUID 展示行（标签 + 等宽值 + 一键复制）。
///
/// - 标签与 UUID 内容**第一行水平对齐**（同字号、同行高、无不对称内边距）；
/// - [uuid] 为空时显示 [hint]（如「保存后自动生成」），不渲染复制按钮；
/// - 预置 Mod 等无 uuid 的实体由调用方决定是否渲染。
class UuidDisplay extends StatelessWidget {
  final String label;
  final String uuid;
  final String hint;

  const UuidDisplay({
    super.key,
    required this.label,
    required this.uuid,
    this.hint = '保存后自动生成',
  });

  static const double _labelWidth = 92;

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: uuid));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('已复制 UUID')));
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    final hasUuid = uuid.trim().isNotEmpty;
    const baseStyle = TextStyle(fontSize: 12, height: 1.4);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: _labelWidth,
          child: Text(
            label,
            style: baseStyle.copyWith(color: colors.textSecondary),
          ),
        ),
        Expanded(
          child: hasUuid
              ? SelectableText(
                  uuid,
                  style: baseStyle.copyWith(fontFamily: 'monospace'),
                )
              : Text(
                  hint,
                  style: baseStyle.copyWith(color: colors.textSecondary),
                ),
        ),
        if (hasUuid)
          IconButton(
            icon: const Icon(Icons.copy_outlined, size: 16),
            tooltip: '复制 UUID',
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(
              minWidth: 24,
              minHeight: 24,
            ),
            onPressed: () => _copy(context),
          ),
      ],
    );
  }
}
