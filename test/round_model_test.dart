import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/round.dart';

/// `Round` 模型序列化测试：覆盖新增的 `modelName`（数据库列 `model_name`）。
void main() {
  group('Round 序列化', () {
    test('fromMap 读取 model_name，toMap 回写', () {
      final round = Round.fromMap(const {
        'id': 1,
        'book_id': 2,
        'round_index': 3,
        'tokens_in': 11,
        'tokens_out': 22,
        'model_name': 'deepseek-v4-pro',
        'created_at': '2026-08-16T00:00:00.000',
      });
      expect(round.modelName, 'deepseek-v4-pro');
      expect(round.toMap()['model_name'], 'deepseek-v4-pro');
    });

    test('缺少 model_name 时默认空字符串（兼容历史数据）', () {
      final round = Round.fromMap(const {'book_id': 1, 'round_index': 1});
      expect(round.modelName, '');
      expect(round.toMap()['model_name'], '');
    });

    test('copyWith 可更新 modelName', () {
      const round = Round(bookId: 1, roundIndex: 1);
      final updated = round.copyWith(modelName: 'deepseek-v4-flash');
      expect(updated.modelName, 'deepseek-v4-flash');
      // 未指定时保留原值。
      expect(updated.copyWith().modelName, 'deepseek-v4-flash');
    });
  });
}
