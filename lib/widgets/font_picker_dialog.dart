import 'package:flutter/material.dart';

import '../services/system_fonts_service.dart';

/// 系统字体选择对话框：列出全部可用字体（以对应字体渲染名称预览）。
///
/// 返回值为选中的字体族名：空字符串表示「系统默认」，`null` 表示取消。
/// 供「字体设置」二级页与「UI 设置」表单共用（同一交互，避免两份复制）。
class FontPickerDialog extends StatelessWidget {
  /// 当前字体族名（空字符串表示系统默认）。
  final String current;

  const FontPickerDialog({super.key, required this.current});

  @override
  Widget build(BuildContext context) {
    final fonts = SystemFontsService.instance.fonts;
    return AlertDialog(
      title: const Text('选择全局字体'),
      content: SizedBox(
        width: 380,
        height: 440,
        child: ListView.builder(
          itemCount: fonts.length + 1,
          itemBuilder: (context, index) {
            if (index == 0) {
              return ListTile(
                dense: true,
                selected: current.isEmpty,
                title: const Text('系统默认'),
                onTap: () => Navigator.of(context).pop(''),
              );
            }
            final font = fonts[index - 1];
            // 中文字体优先显示中文名（如 微软雅黑），附英文族名作副标题。
            final showEn = font.displayName != font.familyName;
            return ListTile(
              dense: true,
              selected: current == font.familyName,
              title: Text(
                font.displayName,
                style: TextStyle(fontFamily: font.familyName),
              ),
              subtitle: showEn ? Text(font.familyName) : null,
              onTap: () => Navigator.of(context).pop(font.familyName),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
    );
  }
}
