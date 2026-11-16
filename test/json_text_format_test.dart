import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/utils/json_text_format.dart';

/// [tryPrettyPrintJson] 的隔离测试：只验证「文本 → 格式化文本 / null」。
void main() {
  test('压缩 JSON 展开为 2 空格缩进', () {
    expect(
      tryPrettyPrintJson('{"a":1,"b":[2,3]}'),
      '{\n  "a": 1,\n  "b": [\n    2,\n    3\n  ]\n}',
    );
  });

  test('顶层数组同样格式化', () {
    expect(
      tryPrettyPrintJson('[1,"two",null,true]'),
      '[\n  1,\n  "two",\n  null,\n  true\n]',
    );
  });

  test('中文键值保持原字符，不转义', () {
    expect(tryPrettyPrintJson('{"中文":"值"}'), '{\n  "中文": "值"\n}');
  });

  test('已带缩进的文本收敛为统一 2 空格缩进', () {
    expect(tryPrettyPrintJson('{\n      "a": 1\n}'), '{\n  "a": 1\n}');
  });

  test('非法 JSON / 空文本返回 null（由调用方回退原文）', () {
    expect(tryPrettyPrintJson('{"a":'), isNull);
    expect(tryPrettyPrintJson('not json'), isNull);
    expect(tryPrettyPrintJson(''), isNull);
    expect(tryPrettyPrintJson('  \n '), isNull);
  });
}
