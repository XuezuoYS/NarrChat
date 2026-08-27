import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/utils/uuid_utils.dart';

/// UUID v4 工具测试：格式 / 版本位 / 变体位 / 唯一性。
void main() {
  test('生成标准 UUID v4 格式（8-4-4-4-12 小写十六进制）', () {
    final uuid = UuidUtils.generateUuidV4();
    expect(
      RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
          .hasMatch(uuid),
      isTrue,
    );
  });

  test('版本位为 4、变体位为 10xx', () {
    final parts = UuidUtils.generateUuidV4().split('-');
    expect(parts[2][0], '4');
    expect('89ab'.contains(parts[3][0]), isTrue);
  });

  test('连续生成不重复（抽样 200 次去重）', () {
    final seen = <String>{};
    for (var i = 0; i < 200; i++) {
      seen.add(UuidUtils.generateUuidV4());
    }
    expect(seen.length, 200);
  });
}
