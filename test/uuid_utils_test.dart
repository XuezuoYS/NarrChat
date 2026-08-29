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

  group('notificationIdForUuid（uuid → 通知槽 id 派生）', () {
    test('结果等于 FNV-1a 32 位哈希的低 31 位（外部标准锚定）', () {
      // FNV-1a 32（offset basis 0x811c9dc5、prime 0x01000193，逐 UTF-16 码元）
      // 对下列 uuid 的独立计算值：
      expect(
        notificationIdForUuid('f3a1b7c2-1d2e-4a5b-9c8d-1e2f3a4b5c61'),
        1886216055,
      );
      expect(
        notificationIdForUuid('c7d5e3f1-6a7b-4c8d-9e0f-a1b2c3d4e5f6'),
        2102549214,
      );
    });

    test('同一 uuid 两次调用结果相同（纯函数，重启后仍可 cancel）', () {
      const uuid = 'f3a1b7c2-1d2e-4a5b-9c8d-1e2f3a4b5c61';
      expect(notificationIdForUuid(uuid), notificationIdForUuid(uuid));
      // 新生成的 uuid 同样稳定：不依赖任何内存 / 持久状态。
      final fresh = UuidUtils.generateUuidV4();
      expect(notificationIdForUuid(fresh), notificationIdForUuid(fresh));
    });

    test('非空 uuid 恒返回正整数（抽样 200 个 v4）', () {
      for (var i = 0; i < 200; i++) {
        final id = notificationIdForUuid(UuidUtils.generateUuidV4());
        expect(id, greaterThan(0));
        // 取低 31 位：不会越过通知 id 的非负上界。
        expect(id, lessThanOrEqualTo(0x7FFFFFFF));
      }
    });

    test('不同 uuid 各自得到不同槽位 id（抽样 200 个 v4 去重）', () {
      final ids = <int>{};
      for (var i = 0; i < 200; i++) {
        ids.add(notificationIdForUuid(UuidUtils.generateUuidV4()));
      }
      expect(ids.length, 200, reason: '槽位冲突会让两本书的通知互相覆盖');
    });

    test('空串返回 0（未落库草稿没有通知槽）', () {
      expect(notificationIdForUuid(''), 0);
    });
  });
}
