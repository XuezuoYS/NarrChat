import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/utils/memory_entry_format.dart';

/// 记忆条目格式真源（`lib/utils/memory_entry_format.dart`）单元测试。
///
/// 覆盖：新格式 `- {轮次} | {时间} | {记忆内容}` 与旧格式
/// `- 第N轮｜日期：xxx｜概括内容` 的兼容解析，以及「每轮恰好一条」的计数依据。
void main() {
  group('parseMemoryEntries', () {
    test('新格式：裸数字轮次 + 时间 + 内容（三者绑定）', () {
      const text = '- 1 | 2026年10月1日03:32:31 | 主角初入宗门。\n'
          '- 2 | 2026年10月3日12:00:00 | 主角获胜。';
      final entries = parseMemoryEntries(text);
      expect(entries, hasLength(2));
      expect(entries[0].round, 1);
      expect(entries[0].time, '2026年10月1日03:32:31');
      expect(entries[0].content, '主角初入宗门。');
      expect(entries[1].round, 2);
      expect(entries[1].time, '2026年10月3日12:00:00');
      expect(entries[1].content, '主角获胜。');
    });

    test('新格式：时间允许自定历法、允许漏写列表符、内容内可含分隔符', () {
      final entries = parseMemoryEntries(
        '- 3 | 丙戊年三月二十日 | 主角夜探藏经阁 | 被巡夜人撞见\n'
        '4 | 第四天 清晨 | 主角闭关。',
      );
      expect(entries, hasLength(2));
      expect(entries[0].round, 3);
      expect(entries[0].time, '丙戊年三月二十日');
      expect(entries[0].content, '主角夜探藏经阁 | 被巡夜人撞见');
      expect(entries[1].round, 4);
      expect(entries[1].time, '第四天 清晨');
      expect(entries[1].content, '主角闭关。');
    });

    test('旧格式：`- 第N轮｜日期：xxx｜概括内容` 继续解析（兼容渲染依据）', () {
      const text = '- 第1轮｜日期：第一天 清晨｜主角初入宗门。\n'
          '- 第2轮｜时间：第三天 午时｜主角获胜。';
      final entries = parseMemoryEntries(text);
      expect(entries, hasLength(2));
      expect(entries[0].round, 1);
      expect(entries[0].time, '第一天 清晨');
      expect(entries[0].content, '主角初入宗门。');
      expect(entries[1].round, 2);
      expect(entries[1].time, '第三天 午时');
      expect(entries[1].content, '主角获胜。');
    });

    test('旧格式：容忍半角分隔符 / 冒号、`*` 列表符与省略时间标签', () {
      const text = '* 第1轮 | 日期: 第一天 | 遇到苏清月｜结伴同行\n'
          '- 第2轮｜第三天 午时｜主角获胜。';
      final entries = parseMemoryEntries(text);
      expect(entries, hasLength(2));
      expect(entries[0].round, 1);
      expect(entries[0].time, '第一天');
      expect(entries[0].content, '遇到苏清月｜结伴同行');
      expect(entries[1].round, 2);
      expect(entries[1].time, '第三天 午时');
      expect(entries[1].content, '主角获胜。');
    });

    test('新旧混排：两种格式一并在同一次解析中命中', () {
      const text = '- 第1轮｜日期：第一天 清晨｜主角初入宗门。\n'
          '- 2 | 第三天 午时 | 主角获胜。';
      final entries = parseMemoryEntries(text);
      expect(entries, hasLength(2));
      expect(entries[0].round, 1);
      expect(entries[0].time, '第一天 清晨');
      expect(entries[1].round, 2);
      expect(entries[1].time, '第三天 午时');
    });

    test('无法解析的行被忽略（返回空列表）', () {
      expect(parseMemoryEntries('主角初入宗门。'), isEmpty);
      expect(parseMemoryEntries(''), isEmpty);
      expect(parseMemoryEntries('第1轮 第一天 内容'), isEmpty);
      // 只有时间没有轮次的行不是条目（不能只写其中一项）。
      expect(parseMemoryEntries('丙戊年三月二十日 | 无轮次'), isEmpty);
    });
  });

  group('memoryEntryCount', () {
    test('新格式：本轮恰好一条 / 0 条 / 多条', () {
      const one = '- 1 | 第一天 清晨 | 主角初入宗门。\n'
          '- 2 | 第三天 午时 | 主角获胜。';
      expect(memoryEntryCount(one, 2), 1);
      expect(memoryEntryCount(one, 3), 0);
      expect(memoryEntryCount(one, 1), 1);

      const two = '- 2 | 第三天 午时 | 主角获胜。\n'
          '- 2 | 第三天 夜 | 重复条目。';
      expect(memoryEntryCount(two, 2), 2);
    });

    test('新格式：漏写列表符的行同样计入', () {
      expect(memoryEntryCount('2 | 第三天 午时 | 主角获胜。', 2), 1);
    });

    test('旧格式：仍然计入（旧书继续可用）', () {
      const text = '- 第1轮｜日期：第一天 午时｜初入宗门\n'
          '- 第2轮｜日期：第二天 申时｜主角见到掌门';
      expect(memoryEntryCount(text, 2), 1);
      expect(memoryEntryCount(text, 1), 1);
      expect(memoryEntryCount(text, 3), 0);
    });

    test('新旧混排：只数轮次命中的条目', () {
      const text = '- 第1轮｜日期：第一天 午时｜初入宗门\n'
          '- 2 | 第二天 申时 | 主角见到掌门';
      expect(memoryEntryCount(text, 1), 1);
      expect(memoryEntryCount(text, 2), 1);
    });

    test('内容里提到「第N轮」不再被误计（旧实现会重复计数）', () {
      const text = '- 1 | 第一天 午时 | 他提到第2轮会发生大事。';
      expect(memoryEntryCount(text, 2), 0);
      expect(memoryEntryCount(text, 1), 1);
    });
  });
}
