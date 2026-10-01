import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/memory_merge_planner.dart';
import 'package:narrchat/utils/memory_entry_format.dart';

/// 「记忆总结轮次合并」策略单元测试（纯逻辑）。
///
/// 规则：档位 T > 0 时，未合并条目达到 `2T` 就把**最旧的 T 条**压成一条区间条目，
/// 并重复到剩余未合并条目 `< 2T`（积压可一轮补齐）；已合并条目冻结、
/// 本轮新增条目不并入区间、尾部未合并片段末条必须是上一轮。
void main() {
  /// 单轮条目行。
  String entry(int round, [String? time]) =>
      '- $round | ${time ?? 't$round'} | 第$round轮事件。';

  /// 合并区间条目行（模型面向形态）。
  String merged(int a, int b) => '- $a - $b | t$a ~ t$b | 第$a-$b轮事件。';

  /// 某轮生成**之前**的记忆总结：1-7 已合并，其后逐轮散条目。
  String memoryWithMergedHead(int lastRound) => [
        merged(1, 7),
        for (var r = 8; r <= lastRound; r++) entry(r),
      ].join('\n');

  MemoryMergePlan plan(String text, int tier, int newRound) => planMemoryMerge(
        memoryText: text,
        tier: tier,
        newRoundIndex: newRound,
      );

  group('触发规则', () {
    test('用户例子：1-7 已合并 + 散条目 8,9,10 → 第 17 轮才合并 8-12', () {
      for (var newRound = 11; newRound <= 16; newRound++) {
        final p = plan(memoryWithMergedHead(newRound - 1), 5, newRound);
        expect(p.hasAction, isFalse, reason: '第 $newRound 轮还没到 2T=10 条');
        expect(p.looseCount, newRound - 8 + 1, reason: '未合并条目数（含本轮新增）');
      }

      final p = plan(memoryWithMergedHead(16), 5, 17);
      expect(p.hasAction, isTrue);
      expect(p.looseCount, 10, reason: '8..17 共 10 条 = 2T');
      expect(p.ranges, hasLength(1));
      final r = p.ranges.single;
      expect(r.startRound, 8);
      expect(r.endRound, 12);
      expect(r.roundCount, 5);
      expect(r.label, '8-12');
      expect(r.startTime, 't8', reason: '时间取自区间首条原文');
      expect(r.endTime, 't12', reason: '时间取自区间末条原文');
    });

    test('档位 10：17 条不动作、20 条时合并最旧 10 条', () {
      final text17 = [
        merged(1, 7),
        for (var r = 8; r <= 17; r++) entry(r),
      ].join('\n');
      expect(plan(text17, 10, 18).hasAction, isFalse,
          reason: '8..18 共 11 条 < 2T=20');

      final text26 = [
        merged(1, 7),
        for (var r = 8; r <= 26; r++) entry(r),
      ].join('\n');
      final p = plan(text26, 10, 27);
      expect(p.looseCount, 20, reason: '8..27 共 20 条 = 2T');
      expect(p.ranges.single.startRound, 8);
      expect(p.ranges.single.endRound, 17);
    });

    test('档位 0：永不动作（无论积压多少）', () {
      final text = [
        for (var r = 1; r <= 200; r++) entry(r),
      ].join('\n');
      final p = plan(text, 0, 201);
      expect(p.tier, 0);
      expect(p.hasAction, isFalse);
      expect(p.ranges, isEmpty);
    });

    test('积压：一轮内连续合并直到剩余未合并条目 < 2T，本轮条目不并入', () {
      final text = [
        merged(1, 7),
        for (var r = 8; r <= 57; r++) entry(r),
      ].join('\n');
      final p = plan(text, 5, 58);
      expect(p.ranges.map((r) => r.label).toList(), [
        '8-12',
        '13-17',
        '18-22',
        '23-27',
        '28-32',
        '33-37',
        '38-42',
        '43-47',
        '48-52',
      ]);
      // 剩余 6 条（53..57 + 本轮 58）< 10。
      expect(p.looseCount, 51);
      expect(p.ranges.last.endRound, lessThan(58),
          reason: '本轮新增条目永不落入合并区间');
    });

    test('从零开始（无已合并条目）：第 10 轮合并 1-5', () {
      final text = [
        for (var r = 1; r <= 9; r++) entry(r),
      ].join('\n');
      final p = plan(text, 5, 10);
      expect(p.ranges.single.startRound, 1);
      expect(p.ranges.single.endRound, 5);
    });

    test('档位中途调大：既有散条目不足新 2T 时不动作', () {
      final text = [
        merged(1, 7),
        for (var r = 8; r <= 20; r++) entry(r),
      ].join('\n');
      expect(plan(text, 10, 21).hasAction, isFalse, reason: '13 条 < 20');
      expect(plan(text, 5, 21).hasAction, isTrue,
          reason: '同一个库在档位 5 下已超 2T → 收敛');
    });
  });

  group('边界与不变量', () {
    test('空文本 / 无条目 → 无动作', () {
      expect(plan('', 5, 1).hasAction, isFalse);
      expect(plan('随便一段不是条目的文字', 5, 1).hasAction, isFalse);
      expect(plan('', 5, 12).looseCount, 0);
    });

    test('首轮（无上一轮）→ 无动作', () {
      expect(plan('', 5, 2).hasAction, isFalse);
      expect(plan(entry(1), 5, 2).hasAction, isFalse, reason: 'count = 2 < 10');
    });

    test('尾部未合并片段末条不是上一轮（历史缺口 / 乱序）→ 不动作', () {
      final text = [merged(1, 7), entry(8), entry(9), entry(10)].join('\n');
      // 上一轮是 14（11~14 缺条目）：不在有缺口的库上冒险合并。
      final p = plan(text, 5, 15);
      expect(p.hasAction, isFalse);
      expect(p.ranges, isEmpty);
    });

    test('中间插入的已合并区间不改写：只吃尾部连续散条目', () {
      final text = [
        merged(1, 7),
        entry(8),
        entry(9),
        merged(10, 15),
        for (var r = 16; r <= 25; r++) entry(r),
      ].join('\n');
      final p = plan(text, 5, 26);
      expect(p.hasAction, isTrue);
      expect(p.ranges.single.startRound, 16,
          reason: '尾部片段是 16..25（10 条）→ 合并 16-20');
      expect(p.ranges.single.endRound, 20);
      final covered = {for (final r in p.ranges) ...{r.startRound, r.endRound}};
      expect(covered.contains(10), isFalse, reason: '已合并条目不动');
      expect(covered.contains(15), isFalse);
    });

    test('重复轮号（异常数据）截断尾部片段，不误合并', () {
      final text = [entry(8), entry(8), entry(9)].join('\n');
      final p = plan(text, 3, 10);
      // 尾部片段 = 9（8 与 9 之间因重复而断开），count = 2 < 6 → 不动作。
      expect(p.hasAction, isFalse);
    });

    test('uiText 列出应合并的区间', () {
      final p = plan(memoryWithMergedHead(16), 5, 17);
      expect(p.uiText, contains('5'));
      expect(p.uiText, contains('8-12'));
    });
  });

  group('isMemoryMergeApplied', () {
    MemoryMergePlan duePlan() => plan(memoryWithMergedHead(16), 5, 17);

    test('未合并 / 只合并了别的区间 → false', () {
      expect(isMemoryMergeApplied(memoryWithMergedHead(16), duePlan()), isFalse);
      final other = [
        merged(1, 7),
        merged(8, 13),
        for (var r = 14; r <= 17; r++) entry(r),
      ].join('\n');
      expect(isMemoryMergeApplied(other, duePlan()), isFalse,
          reason: '区间两端必须与计划一致');
    });

    test('已合并（半角 `-` / `~`、全角、转义分隔符都算）→ true', () {
      for (final sep in const ['-', '~', '－', '～', '\\~', '\\-']) {
        final text = [
          merged(1, 7),
          '- 8 ${sep}12 | t8 ~ t12 | 合并内容。',
          entry(13),
          entry(14),
          entry(15),
          entry(16),
          entry(17),
        ].join('\n');
        expect(isMemoryMergeApplied(text, duePlan()), isTrue,
            reason: '分隔符 $sep 应被视为同一区间');
      }
    });

    test('无动作的计划恒为已落地', () {
      expect(isMemoryMergeApplied('', plan('', 5, 1)), isTrue);
      expect(
        isMemoryMergeApplied(entry(1), planMemoryMerge(
          memoryText: entry(1),
          tier: 0,
          newRoundIndex: 2,
        )),
        isTrue,
      );
    });

    test('多个区间需全部落地', () {
      final text = [
        merged(1, 7),
        for (var r = 8; r <= 57; r++) entry(r),
      ].join('\n');
      final p = plan(text, 5, 58);
      expect(p.ranges.length, greaterThan(1));
      // 只落地第一个区间 → 未完成。
      final partial = [
        merged(1, 7),
        merged(8, 12),
        for (var r = 13; r <= 57; r++) entry(r),
        entry(58),
      ].join('\n');
      expect(isMemoryMergeApplied(partial, p), isFalse);
      final full = [
        merged(1, 7),
        merged(8, 12),
        merged(13, 17),
        merged(18, 22),
        merged(23, 27),
        merged(28, 32),
        merged(33, 37),
        merged(38, 42),
        merged(43, 47),
        merged(48, 52),
        for (var r = 53; r <= 58; r++) entry(r),
      ].join('\n');
      expect(isMemoryMergeApplied(full, p), isTrue);
    });
  });

  group('与格式层一致', () {
    test('planMemoryMerge 读的就是 kMemoryMergedEntryFormat 形态', () {
      expect(kMemoryMergedEntryFormat, contains('{开头轮} - {结尾轮}'));
      final p = plan(memoryWithMergedHead(16), 5, 17);
      final r = p.ranges.single;
      final line = memoryMergedEntryTemplate(
        startRound: r.startRound,
        endRound: r.endRound,
        startTime: r.startTime,
        endTime: r.endTime,
      );
      expect(line, '- 8 - 12 | t8 ~ t12 | {记忆内容}');
      expect(parseMemoryEntries(line).single.isMerged, isTrue,
          reason: '模板行必须能被解析层识别为区间条目');
      expect(parseMemoryEntries(line).single.roundMax, 12);
    });
  });
}
