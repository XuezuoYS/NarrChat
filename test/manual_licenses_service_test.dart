import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/services/manual_licenses_service.dart';

void main() {
  group('ManualLicensesService.parse', () {
    test('合法 JSON：解析出条目并保留多行许可证', () {
      const raw = '''
{
  "licenses": [
    {
      "name": "FooLib",
      "license": "MIT License\\n\\nCopyright (c) 2024 Foo\\n\\nPermission is hereby granted..."
    },
    {
      "name": "BarLib",
      "license": "Apache-2.0"
    }
  ]
}
''';
      final list = ManualLicensesService.parse(raw);
      expect(list, hasLength(2));
      expect(list[0].name, 'FooLib');
      expect(list[0].license, contains('MIT License'));
      expect(list[0].license, contains('Copyright (c) 2024 Foo'));
      expect(list[1].name, 'BarLib');
      expect(list[1].license, 'Apache-2.0');
    });

    test('字段缺失 / 空白：name、license 回退为空并被过滤', () {
      const raw = '''
{
  "licenses": [
    {"name": "OnlyName"},
    {"license": "OnlyLicense"},
    {},
    {"name": "  ", "license": "   "}
  ]
}
''';
      expect(ManualLicensesService.parse(raw), isEmpty);
    });

    test('非法 JSON：抛出 FormatException', () {
      expect(
        () => ManualLicensesService.parse('{ not json'),
        throwsFormatException,
      );
    });

    test('顶层非对象 / 缺 licenses 数组：抛出 FormatException', () {
      expect(
        () => ManualLicensesService.parse('[1, 2, 3]'),
        throwsFormatException,
      );
      expect(
        () => ManualLicensesService.parse('{"foo": 1}'),
        throwsFormatException,
      );
    });
  });

  group('ManualLicensesService.load', () {
    test('注入合法原始文本：返回条目列表', () async {
      final list = await ManualLicensesService.load(
        raw: '{"licenses": [{"name": "X", "license": "MIT"}]}',
      );
      expect(list, hasLength(1));
      expect(list.single.name, 'X');
      expect(list.single.license, 'MIT');
    });

    test('注入非法文本：兜底返回空列表而不崩溃', () async {
      final list = await ManualLicensesService.load(raw: '{bad json');
      expect(list, isEmpty);
    });
  });
}
