import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/models/role_category.dart';
import 'package:narrchat/utils/constants.dart';

/// Constants 工具单元测试（原 widget_test.dart 拆分而来；
/// AppConfig 断言已在 ai_platform_test.dart 中覆盖）。
void main() {
  group('Constants', () {
    test('默认角色层级', () {
      expect(Constants.defaultRoleHierarchy, [
        '主角',
        '女主角',
        'NPC',
      ]);
      expect(
        Constants.joinRoleHierarchy(Constants.defaultRoleHierarchy),
        '主角 > 女主角 > NPC',
      );
    });

    test('拆分与拼接互逆', () {
      final roles = Constants.splitRoleHierarchy('主角 > 女主角 > NPC');
      expect(roles, ['主角', '女主角', 'NPC']);
      expect(Constants.joinRoleHierarchy(roles), '主角 > 女主角 > NPC');
    });

    test('空值回退默认', () {
      expect(Constants.splitRoleHierarchy(null).length, 3);
      expect(Constants.splitRoleHierarchy('').length, 3);
    });

    test('角色类别编解码互逆且保留名称与格式', () {
      final categories = Constants.defaultRoleCategories;
      final json = Constants.encodeRoleCategories(categories);
      final decoded = Constants.decodeRoleCategories(json);
      expect(decoded.length, categories.length);
      expect(decoded.first.name, '主角');
      expect(decoded.first.format, contains('- 姓名：'));
      // 自定义类别也能正确往返
      const custom = [RoleCategory(name: '男二', format: '- 姓名：\n- 身份：')];
      final decodedCustom =
          Constants.decodeRoleCategories(Constants.encodeRoleCategories(custom));
      expect(decodedCustom.single.name, '男二');
      expect(decodedCustom.single.format, '- 姓名：\n- 身份：');
    });

    test('角色类别空值或非法 JSON 回退默认', () {
      expect(Constants.decodeRoleCategories(null).length, 3);
      expect(Constants.decodeRoleCategories('').length, 3);
      expect(Constants.decodeRoleCategories('not a json').length, 3);
    });
  });
}
