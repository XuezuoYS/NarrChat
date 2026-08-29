import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/sync/sync_models.dart';

/// `SyncConfig`（云端 sync_config.json 模型）单元测试：
/// 解析容错（非法 / 越界 / 缺失）、序列化往返、校验文案。
void main() {
  group('SyncConfig.tryParse', () {
    test('null / 空串 / 非法 JSON / 非 Map → null（视为未配置）', () {
      expect(SyncConfig.tryParse(null), isNull);
      expect(SyncConfig.tryParse(''), isNull);
      expect(SyncConfig.tryParse('not json'), isNull);
      expect(SyncConfig.tryParse('[]'), isNull);
      expect(SyncConfig.tryParse('"x"'), isNull);
    });

    test('合法 JSON → 解析出份数', () {
      expect(
        SyncConfig.tryParse('{"keepVersions":7}')?.keepVersions,
        7,
      );
    });

    test('缺失 / 非法字段 → 回落默认 5', () {
      expect(SyncConfig.tryParse('{}')?.keepVersions, 5);
      expect(SyncConfig.tryParse('{"keepVersions":"abc"}')?.keepVersions, 5);
      expect(SyncConfig.tryParse('{"keepVersions":null}')?.keepVersions, 5);
    });

    test('越界 clamp：0 → 1，999 → 99（手改云端文件也不清空全部快照）', () {
      expect(SyncConfig.tryParse('{"keepVersions":0}')?.keepVersions, 1);
      expect(SyncConfig.tryParse('{"keepVersions":999}')?.keepVersions, 99);
      expect(SyncConfig.tryParse('{"keepVersions":-3}')?.keepVersions, 1);
    });
  });

  test('toJsonString 往返：缺省与显式值', () {
    expect(
      SyncConfig.tryParse(const SyncConfig().toJsonString())?.keepVersions,
      SyncConfig.defaultKeepVersions,
    );
    expect(
      SyncConfig.tryParse(const SyncConfig(keepVersions: 42).toJsonString())
          ?.keepVersions,
      42,
    );
  });

  group('SyncConfig.validateKeepVersions', () {
    test('null（非整数）→ 「请输入整数」', () {
      expect(SyncConfig.validateKeepVersions(null), '请输入整数');
    });

    test('边界外 → 「需为 1 ~ 99 的整数」', () {
      expect(SyncConfig.validateKeepVersions(0), '需为 1 ~ 99 的整数');
      expect(SyncConfig.validateKeepVersions(100), '需为 1 ~ 99 的整数');
    });

    test('边界内 → 通过', () {
      expect(SyncConfig.validateKeepVersions(1), isNull);
      expect(SyncConfig.validateKeepVersions(99), isNull);
      expect(SyncConfig.validateKeepVersions(5), isNull);
    });
  });
}
