import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/utils/formats.dart';
import 'package:narrchat/widgets/token_usage_bubble.dart';
import 'package:narrchat/widgets/token_usage_pill.dart';

import 'helpers/selection_harness.dart';

/// Token 栏（模型名 + 输入 / 输出 Token 胶囊）与点击后弹出的统计卡：
/// 主模型 / 子模型 / 总计分区、无数据斜体「（无）」、点击外部关闭、可选中复制。
const _richRound = Round(
  bookUuid: 'b1',
  roundIndex: 1,
  tokensIn: 10000,
  tokensOut: 500,
  cachedTokensIn: 4940,
  modelName: 'deepseek-v4-flash',
);

/// 启用子模型的轮次：主 100 / 缓存 50 / 输出 30，子 20 / 10 / 5。
const _subRound = Round(
  bookUuid: 'b1',
  roundIndex: 2,
  modelName: 'deepseek-flash',
  tokensIn: 100,
  cachedTokensIn: 50,
  tokensOut: 30,
  subagentModelName: 'deepseek-v4-pro',
  subagentTokensIn: 20,
  subagentCachedTokensIn: 10,
  subagentTokensOut: 5,
);

/// 子模型已启用但没有 token 数据（服务商未返回 usage）。
const _subNoUsageRound = Round(
  bookUuid: 'b1',
  roundIndex: 3,
  modelName: 'deepseek-flash',
  tokensIn: 100,
  cachedTokensIn: 50,
  tokensOut: 30,
  subagentModelName: 'cheap-model',
);

/// 全字段无数据（历史轮次 / 模型未返回 usage）。
const _emptyRound = Round(bookUuid: 'b1', roundIndex: 4);

/// 以左下角放置 Token 栏（统计卡默认在其上方，视口内放得下）。
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

String _textOf(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(ValueKey(key))).data!;

void main() {
  group('Token 统计卡：主模型 only', () {
    testWidgets('未启用子模型：只显示主模型区，不显示子模型 / 总计', (tester) async {
      await _openBubble(tester, _richRound);

      final bubble = find.byType(TokenUsageBubble);
      expect(bubble, findsOneWidget);
      expect(
        find.byKey(const ValueKey('token_usage_main_section')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('token_usage_subagent_section')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('token_usage_total_section')),
        findsNothing,
      );

      expect(
        _textOf(tester, 'token_usage_main_model_name'),
        'deepseek-v4-flash',
      );
      expect(_textOf(tester, 'token_usage_main_input'), '10000');
      expect(_textOf(tester, 'token_usage_main_cached'), '4940');
      expect(_textOf(tester, 'token_usage_main_output'), '500');
      expect(_textOf(tester, 'token_usage_main_cache_rate'), '缓存命中率 49.4%');
      expect(_textOf(tester, 'token_usage_main_total'), '总 token 10500');
    });

    testWidgets('无数据：主模型区指标显示斜体（无）', (tester) async {
      await _openBubble(tester, _emptyRound);

      final bubble = find.byType(TokenUsageBubble);
      for (final key in const [
        'token_usage_main_input',
        'token_usage_main_cached',
        'token_usage_main_output',
      ]) {
        final value = tester.widget<Text>(find.byKey(ValueKey(key)));
        expect(value.data, Formats.noData, reason: key);
        expect(value.style?.fontStyle, FontStyle.italic, reason: key);
      }
      expect(
        find.descendant(of: bubble, matching: find.text(Formats.noData)),
        findsWidgets,
      );
      // 外显 Token 栏同样显示（无）。
      expect(
        find.text(
          '输入 Tokens: ${Formats.noData}  ·  输出 Tokens: ${Formats.noData}',
        ),
        findsOneWidget,
      );
    });
  });

  group('Token 统计卡：主模型 + 子模型', () {
    testWidgets('三个分区齐全，主 / 子 / 总计数值与命中率正确', (tester) async {
      await _openBubble(tester, _subRound);

      expect(
        find.byKey(const ValueKey('token_usage_main_section')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('token_usage_subagent_section')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('token_usage_total_section')),
        findsOneWidget,
      );

      expect(_textOf(tester, 'token_usage_main_model_name'), 'deepseek-flash');
      expect(
        _textOf(tester, 'token_usage_subagent_model_name'),
        'deepseek-v4-pro',
      );
      expect(_textOf(tester, 'token_usage_main_input'), '100');
      expect(_textOf(tester, 'token_usage_main_cached'), '50');
      expect(_textOf(tester, 'token_usage_main_output'), '30');
      expect(_textOf(tester, 'token_usage_subagent_input'), '20');
      expect(_textOf(tester, 'token_usage_subagent_cached'), '10');
      expect(_textOf(tester, 'token_usage_subagent_output'), '5');
      expect(_textOf(tester, 'token_usage_total_input'), '120');
      expect(_textOf(tester, 'token_usage_total_cached'), '60');
      expect(_textOf(tester, 'token_usage_total_output'), '35');
      expect(_textOf(tester, 'token_usage_total_total'), '总 token 155');
      expect(_textOf(tester, 'token_usage_main_cache_rate'), '缓存命中率 50%');
      expect(_textOf(tester, 'token_usage_subagent_cache_rate'), '缓存命中率 50%');
      expect(_textOf(tester, 'token_usage_total_cache_rate'), '缓存命中率 50%');
    });

    testWidgets('子模型启用但无 usage：子区三项（无），总计等于主模型', (tester) async {
      await _openBubble(tester, _subNoUsageRound);

      expect(_textOf(tester, 'token_usage_subagent_model_name'), 'cheap-model');
      for (final key in const [
        'token_usage_subagent_input',
        'token_usage_subagent_cached',
        'token_usage_subagent_output',
      ]) {
        final value = tester.widget<Text>(find.byKey(ValueKey(key)));
        expect(value.data, Formats.noData, reason: key);
        expect(value.style?.fontStyle, FontStyle.italic, reason: key);
      }
      expect(_textOf(tester, 'token_usage_total_input'), '100');
      expect(_textOf(tester, 'token_usage_total_cached'), '50');
      expect(_textOf(tester, 'token_usage_total_output'), '30');
      expect(_textOf(tester, 'token_usage_total_total'), '总 token 130');
    });
  });

  group('统计卡交互', () {
    testWidgets('点击卡外关闭；点击卡内不关闭', (tester) async {
      await _openBubble(tester, _richRound);

      await tester.tap(find.text('Token 用量'));
      await tester.pumpAndSettle();
      expect(find.byType(TokenUsageBubble), findsOneWidget);

      await tester.tapAt(const Offset(790, 5));
      await tester.pumpAndSettle();
      expect(find.byType(TokenUsageBubble), findsNothing);
    });

    testWidgets('卡内文字可拖拽选中复制', (tester) async {
      final copied = mockClipboard(tester);
      await _openBubble(tester, _richRound);

      final area = find.byType(SelectionArea);
      expect(area, findsOneWidget);

      final name = find.byKey(const ValueKey('token_usage_main_model_name'));
      final rect = tester.getRect(name);
      final gesture = await tester.startGesture(
        Offset(rect.left + 1, rect.center.dy),
        kind: PointerDeviceKind.mouse,
      );
      addTearDown(gesture.removePointer);
      await tester.pump();
      await gesture.moveTo(Offset(rect.right - 1, rect.center.dy));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(find.text('复制'), findsOneWidget);
      await tester.tap(find.text('复制'));
      await tester.pumpAndSettle();
      expect(copied, hasLength(1));
      expect(copied.single.trim(), 'deepseek-v4-flash');
    });
  });

  group('Token 栏', () {
    testWidgets('未启用子模型：行为与旧版一致（主模型名 + 输入 / 输出）', (tester) async {
      await _pump(tester, _richRound);
      expect(find.text('deepseek-v4-flash'), findsOneWidget);
      expect(find.text('输入 Tokens: 10000  ·  输出 Tokens: 500'), findsOneWidget);
    });

    testWidgets('启用子模型：模型名标注「+ 子模型」，输入 / 输出取总计', (tester) async {
      await _pump(tester, _subRound);
      expect(find.text('deepseek-flash + 子模型'), findsOneWidget);
      expect(find.text('输入 Tokens: 120  ·  输出 Tokens: 35'), findsOneWidget);
    });

    testWidgets('无数据：输入 / 输出都显示（无）', (tester) async {
      await _pump(tester, _emptyRound);
      expect(
        find.text(
          '输入 Tokens: ${Formats.noData}  ·  输出 Tokens: ${Formats.noData}',
        ),
        findsOneWidget,
      );
    });
  });
}
