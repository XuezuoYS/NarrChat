import 'package:flutter/widgets.dart';

/// 文本统计工具（字数统计等）。
///
/// 统计口径：按 Unicode 字素簇计数——中文字、英文字母、标点、空格、换行、
/// 表情均各计 1 个字符；表情（含 ZWJ 组合、带变体选择符、旗帜等）不会被
/// 拆成多个码位/码元，符合「所见即一个字符」的直觉。
///
/// 纯逻辑、无副作用：输入卡实时字数、后续的其它字数展示均复用此处，
/// 避免各页面各写一套计数规则。
class TextStats {
  TextStats._();

  /// 字符数（空串为 0）。
  static int charCount(String text) => text.characters.length;

  /// 千分位分组（`1234567` → `1,234,567`），长文本读数更直观。
  static String groupThousands(int value) => value.toString().replaceAllMapped(
    RegExp(r'(\d)(?=(\d{3})+$)'),
    (match) => '${match[1]},',
  );
}
