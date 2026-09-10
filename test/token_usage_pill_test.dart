import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/utils/formats.dart';
import 'package:narrchat/widgets/token_usage_bubble.dart';
import 'package:narrchat/widgets/token_usage_pill.dart';

/// Token 栏（模型名 + 输入 / 输出 Token 胶囊）与点击后弹出的计费明细气泡：
/// 明细行的装配、无数据行的斜体「（无）」、点击外部关闭、文字可选中复制。
const _richRound = Round(
  bookUuid: 'b1',
  roundIndex: 1,
  tokensIn: 10000,
  tokensOut: 500,
  cachedTokensIn: 4940,
  modelName: 'deepseek-v4-flash',
);

/// 全字段无数据（历史轮次 / 模型未返回 usage）。
const _emptyRound = Round(bookUuid: 'b1', roundIndex: 2);

/// 以左下角放置 Token 栏（气泡默认在其上方，视口内放得下）。
Future<void> _pump(WidgetTester tester, Round round) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomLeft,
          child: TokenUsagePill(round: round),
        ),
      ),
    ),
  );
}

Future<void> _openBubble(WidgetTester tester, Round round) async {
  await _pump(tester, round);
  await tester.tap(find.byType(TokenUsagePill));
  await tester.pumpAndSettle();
}

void main() {
  group('TokenUsageBubble.rowsOf', () {
    test('六行顺序与取值：总 token = 输入 + 输出，命中率 = 缓存命中 / 输入', () {
      final rows = TokenUsageBubble.rowsOf(_richRound);
      expect(rows.map((r) => r.label).toList(), [
        '模型名',
        '输入 token',
        '缓存命中输入 token',
        '缓存命中率',
        '输出 token',
        '总 token',
      ]);
      expect(rows[0].value, 'deepseek-v4-flash');
      expect(rows[1].value, '10000');
      expect(rows[2].value, '4940');
      expect(rows[3].value, '49.4%');
      expect(rows[4].value, '500');
      expect(rows[5].value, '10500');
    });

    test('缺字段 → 该行无数据（null），其余行不受影响', () {
      final rows = TokenUsageBubble.rowsOf(
        const Round(
          bookUuid: 'b1',
          roundIndex: 1,
          tokensIn: 1000,
          tokensOut: 20,
          modelName: '   ',
        ),
      );
      expect(rows[0].value, isNull, reason: '模型名空白视为无数据');
      expect(rows[1].value, '1000');
      expect(rows[2].value, isNull, reason: '模型未返回缓存命中字段');
      expect(rows[3].value, isNull, reason: '缺缓存侧数据算不出命中率');
      expect(rows[5].value, '1020', reason: '只有一侧缺数据不影响总量');
    });

    test('全字段无数据 → 全部 null', () {
      expect(
        TokenUsageBubble.rowsOf(_emptyRound).map((r) => r.value),
        everyElement(isNull),
      );
    });

    test('totalTokens：只有一侧有数据按已知侧求和，两侧都无 → null', () {
      const onlyOut = Round(bookUuid: 'b1', roundIndex: 1, tokensOut: 7);
      expect(TokenUsageBubble.totalTokens(onlyOut), 7);
      expect(TokenUsageBubble.totalTokens(_emptyRound), isNull);
    });
  });

  group('Token 栏 → 明细气泡', () {
    testWidgets('点击 Token 栏弹出气泡，逐行展示六项明细', (tester) async {
      await _openBubble(tester, _richRound);

      final bubble = find.byType(TokenUsageBubble);
      expect(bubble, findsOneWidget);
      for (final label in const [
        '模型名',
        '输入 token',
        '缓存命中输入 token',
        '缓存命中率',
        '输出 token',
        '总 token',
      ]) {
        expect(
          find.descendant(of: bubble, matching: find.text(label)),
          findsOneWidget,
          reason: '缺少明细行：$label',
        );
      }
      for (final value in const [
        'deepseek-v4-flash',
        '10000',
        '4940',
        '49.4%',
        '500',
        '10500',
      ]) {
        expect(
          find.descendant(of: bubble, matching: find.text(value)),
          findsOneWidget,
          reason: '明细值缺失：$value',
        );
      }
      // 有数据 → 气泡内不出现「（无）」。
      expect(
        find.descendant(of: bubble, matching: find.text(Formats.noData)),
        findsNothing,
      );
    });

    testWidgets('无数据明细行显示斜体（无），有数据行为正体', (tester) async {
      // 模型名为空 + 无缓存字段 → 模型名 / 缓存命中输入 / 缓存命中率三行无数据。
      await _openBubble(
        tester,
        const Round(
          bookUuid: 'b1',
          roundIndex: 1,
          tokensIn: 1000,
          tokensOut: 20,
        ),
      );

      final bubble = find.byType(TokenUsageBubble);
      final missingTexts = tester
          .widgetList<Text>(
            find.descendant(of: bubble, matching: find.text(Formats.noData)),
          )
          .toList();
      expect(missingTexts, hasLength(3));
      for (final text in missingTexts) {
        expect(text.style?.fontStyle, FontStyle.italic);
      }
      final value = tester.widget<Text>(
        find.descendant(of: bubble, matching: find.text('1000')),
      );
      expect(value.style?.fontStyle, isNot(FontStyle.italic));
    });

    testWidgets('历史轮次全字段无数据：六行均为斜体（无）', (tester) async {
      await _openBubble(tester, _emptyRound);

      final bubble = find.byType(TokenUsageBubble);
      final missing = find.descendant(
        of: bubble,
        matching: find.text(Formats.noData),
      );
      expect(missing, findsNWidgets(6));
      expect(
        tester
            .widgetList<Text>(missing)
            .every((t) => t.style?.fontStyle == FontStyle.italic),
        isTrue,
      );
      // Token 栏外显同样是「（无）」，与气泡一致。
      expect(
        find.text('输入 Tokens: ${Formats.noData}  ·  输出 Tokens: ${Formats.noData}'),
        findsOneWidget,
      );
    });

    testWidgets('点击气泡外关闭；点击气泡内不关闭', (tester) async {
      await _openBubble(tester, _richRound);

      // 气泡内的文字（拖选 / 点击）不属于「气泡外」。
      await tester.tap(find.text('模型名'));
      await tester.pumpAndSettle();
      expect(find.byType(TokenUsageBubble), findsOneWidget);

      await tester.tapAt(const Offset(790, 5));
      await tester.pumpAndSettle();
      expect(find.byType(TokenUsageBubble), findsNothing);
    });

    testWidgets('气泡内文字可选中复制（SelectionArea 覆盖全部明细行）', (tester) async {
      await _openBubble(tester, _richRound);

      final area = find.byType(SelectionArea);
      expect(area, findsOneWidget);
      // 六行明细（标签 + 值）全部落在同一个可选区里（可跨行拖动选择后复制）。
      final selectableTexts = find.descendant(of: area, matching: find.byType(Text));
      expect(tester.widgetList<Text>(selectableTexts), hasLength(12));
    });

    testWidgets('Token 栏外显：无数据显示（无），有数据显示原值', (tester) async {
      await _pump(tester, _emptyRound);
      expect(
        find.text('输入 Tokens: ${Formats.noData}  ·  输出 Tokens: ${Formats.noData}'),
        findsOneWidget,
      );

      await _pump(tester, _richRound);
      expect(
        find.text('输入 Tokens: 10000  ·  输出 Tokens: 500'),
        findsOneWidget,
      );
    });
  });
}
