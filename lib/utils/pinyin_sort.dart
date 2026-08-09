import 'package:pinyin/pinyin.dart';

/// 按拼音 a~z 排序的辅助函数。
///
/// 使用 `pinyin` 包将汉字转为无调拼音作排序键：
/// - 汉字（U+4E00–U+9FFF）→ 小写无调拼音；
/// - 非汉字字符（字母、数字、符号）原样保留并转为小写。
class PinyinSort {
  PinyinSort._();

  /// 生成用于拼音排序的键（小写、不带声调）。
  static String key(String text) {
    final buf = StringBuffer();
    for (final rune in text.toLowerCase().runes) {
      if (rune >= 0x4E00 && rune <= 0x9FFF) {
        final ch = String.fromCharCode(rune);
        buf.write(
          PinyinHelper.getPinyinE(
            ch,
            separator: '',
            format: PinyinFormat.WITHOUT_TONE,
          ),
        );
      } else {
        buf.writeCharCode(rune);
      }
    }
    return buf.toString();
  }

  /// 按拼音 a~z 比较两个字符串。
  static int compare(String a, String b) {
    return key(a).compareTo(key(b));
  }
}
