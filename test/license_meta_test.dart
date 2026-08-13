import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/utils/license_meta.dart';

void main() {
  group('licenseSubtitle', () {
    test('取首个非空行整行（不拼接作者）', () {
      expect(
        licenseSubtitle('MIT License\n\nCopyright (c) 2024 Remi Rousselet'),
        'MIT License',
      );
    });

    test('首行为版权行时也整行返回，不向下扫描', () {
      expect(
        licenseSubtitle('Copyright (c) 2024 Tekartik. All rights reserved.'),
        'Copyright (c) 2024 Tekartik. All rights reserved.',
      );
    });

    test('不选取第二乃至第三行的内容', () {
      expect(
        licenseSubtitle(
          'Copyright (c) 2024 Foo\n\nBSD 3-Clause License\n\n'
          'Redistribution and use in source and binary forms...',
        ),
        'Copyright (c) 2024 Foo',
      );
    });

    test('跨行合并为整行的标题整行返回（Apache 2.0）', () {
      expect(
        licenseSubtitle(
          'Apache License Version 2.0, January 2004 '
          'http://www.apache.org/licenses/\n\n'
          'TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION',
        ),
        'Apache License Version 2.0, January 2004 '
            'http://www.apache.org/licenses/',
      );
    });

    test('空文本 / 全空白返回空字符串', () {
      expect(licenseSubtitle(''), '');
      expect(licenseSubtitle('   \n \t \n'), '');
    });
  });
}
