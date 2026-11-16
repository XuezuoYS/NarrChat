import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/models/token_usage.dart';
import 'package:narrchat/utils/formats.dart';

/// `RoundTokenUsage` 的纯统计口径：主模型 / 子模型 / 总计、NULL 无数据与 0。
void main() {
  group('RoundTokenUsage.of', () {
    test('未启用子模型：子模型为 null，总计等于主模型', () {
      const round = Round(
        bookUuid: 'b1',
        roundIndex: 1,
        modelName: 'deepseek-flash',
        tokensIn: 100,
        cachedTokensIn: 50,
        tokensOut: 30,
      );

      final usage = RoundTokenUsage.of(round);
      expect(usage.hasSubagent, isFalse);
      expect(usage.subagent, isNull);
      expect(usage.main.modelName, 'deepseek-flash');
      expect(usage.main.tokensIn, 100);
      expect(usage.main.cachedTokensIn, 50);
      expect(usage.main.tokensOut, 30);
      expect(usage.main.totalTokens, 130);
      expect(usage.main.cacheHitRateText, '50%');
      expect(usage.total.tokensIn, 100);
      expect(usage.total.cachedTokensIn, 50);
      expect(usage.total.tokensOut, 30);
      expect(usage.total.totalTokens, 130);
    });

    test('启用子模型：主 / 子 / 总计逐项求和', () {
      const round = Round(
        bookUuid: 'b1',
        roundIndex: 1,
        modelName: 'deepseek-flash',
        tokensIn: 100,
        cachedTokensIn: 50,
        tokensOut: 30,
        subagentModelName: 'deepseek-v4-pro',
        subagentTokensIn: 20,
        subagentCachedTokensIn: 10,
        subagentTokensOut: 5,
      );

      final usage = RoundTokenUsage.of(round);
      expect(usage.hasSubagent, isTrue);
      expect(usage.subagent, isNotNull);
      expect(usage.subagent!.modelName, 'deepseek-v4-pro');
      expect(usage.subagent!.tokensIn, 20);
      expect(usage.subagent!.cachedTokensIn, 10);
      expect(usage.subagent!.tokensOut, 5);
      expect(usage.subagent!.totalTokens, 25);
      expect(usage.subagent!.cacheHitRateText, '50%');
      expect(usage.total.tokensIn, 120);
      expect(usage.total.cachedTokensIn, 60);
      expect(usage.total.tokensOut, 35);
      expect(usage.total.totalTokens, 155);
      expect(usage.total.cacheHitRateText, '50%');
    });

    test('单侧 null 按已知侧求和；双侧 null 保持 null；0 是真实数据', () {
      const onlyMainOut = Round(bookUuid: 'b1', roundIndex: 1, tokensOut: 7);
      final usage = RoundTokenUsage.of(onlyMainOut);
      expect(usage.main.tokensIn, isNull);
      expect(usage.main.totalTokens, 7);
      expect(usage.total.tokensIn, isNull);
      expect(usage.total.totalTokens, 7);

      const bothNull = Round(bookUuid: 'b1', roundIndex: 1);
      final empty = RoundTokenUsage.of(bothNull);
      expect(empty.total.tokensIn, isNull);
      expect(empty.total.tokensOut, isNull);
      expect(empty.total.totalTokens, isNull);
      expect(empty.total.totalTokensText, Formats.noData);
      expect(empty.main.cacheHitRateText, Formats.noData);

      const zeroIn = Round(bookUuid: 'b1', roundIndex: 1, tokensIn: 0);
      final zero = RoundTokenUsage.of(zeroIn);
      expect(zero.total.tokensIn, 0);
      expect(zero.total.totalTokens, 0);
      expect(
        zero.main.cacheHitRateText,
        Formats.noData,
        reason: '输入为 0 算不出命中率',
      );
    });

    test('名称空但子模型 token 有值：仍视为启用，名称显示（无）', () {
      const round = Round(bookUuid: 'b1', roundIndex: 1, subagentTokensIn: 1);
      final usage = RoundTokenUsage.of(round);
      expect(usage.hasSubagent, isTrue);
      expect(usage.subagent!.displayModelName, Formats.noData);
      expect(usage.total.tokensIn, 1);
    });

    test('主模型名空白显示（无）', () {
      const round = Round(
        bookUuid: 'b1',
        roundIndex: 1,
        modelName: '   ',
        tokensIn: 1,
      );
      final usage = RoundTokenUsage.of(round);
      expect(usage.main.displayModelName, Formats.noData);
      expect(usage.total.tokensIn, 1);
    });
  });
}
