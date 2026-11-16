import 'package:flutter/material.dart';

import '../utils/json_syntax_highlighter.dart';

/// JSON 语法高亮配色（随亮暗主题自适应）。
///
/// 只读展示组件（`JsonView`）与编辑控制器（`JsonEditingController`）共用这一份
/// 配色，保证「看到的」和「编辑的」颜色完全一致。
///
/// 色板与编辑器 Markdown 高亮（`MarkdownSyntaxColors`）同源：深色取 One Dark Pro
/// 原值，浅色取其加深适配版；因此同一界面上两种高亮不会互相打架。
@immutable
class JsonSyntaxColors {
  /// 对象键名。
  final Color key;

  /// 字符串值。
  final Color string;

  /// 数字。
  final Color number;

  /// 字面量 `true` / `false` / `null`。
  final Color keyword;

  /// 结构标点 `{ } [ ] , :`。
  final Color punctuation;

  const JsonSyntaxColors({
    required this.key,
    required this.string,
    required this.number,
    required this.keyword,
    required this.punctuation,
  });

  /// 浅色主题（One Dark Pro 在浅色背景下的加深适配）。
  static const JsonSyntaxColors light = JsonSyntaxColors(
    key: Color(0xFF0550AE),
    string: Color(0xFF1A7F37),
    number: Color(0xFFB45309),
    keyword: Color(0xFF8250DF),
    punctuation: Color(0xFF57606A),
  );

  /// 深色主题（One Dark Pro）：蓝键名、绿字符串、橙数字、紫字面量、灰标点。
  static const JsonSyntaxColors dark = JsonSyntaxColors(
    key: Color(0xFF61AFEF),
    string: Color(0xFF98C379),
    number: Color(0xFFD19A66),
    keyword: Color(0xFFC678DD),
    punctuation: Color(0xFF7F848E),
  );

  /// 按当前主题亮度选取配色。
  static JsonSyntaxColors of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;

  /// 词法单元对应的颜色。
  Color colorOf(JsonSyntaxToken token) => switch (token) {
        JsonSyntaxToken.key => key,
        JsonSyntaxToken.string => string,
        JsonSyntaxToken.number => number,
        JsonSyntaxToken.keyword => keyword,
        JsonSyntaxToken.punctuation => punctuation,
      };

  /// 词法单元的字形样式：只改颜色，字号 / 字体 / 行高等一律继承 [base]。
  TextStyle styleFor(JsonSyntaxToken token, TextStyle base) =>
      base.copyWith(color: colorOf(token));
}
