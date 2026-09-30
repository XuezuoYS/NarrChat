import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/memory_summary_editor.dart';

Widget _wrap(Widget child, {ThemeData? theme}) {
  return MaterialApp(
    theme: theme ?? NarrChatTheme.light,
    home: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: child,
      ),
    ),
  );
}

/// 徽标指示（`第N轮` / `第11~15轮`）所在 `Container` 的底纹色。
Color _badgeBackground(WidgetTester tester, String label) {
  final badge = tester.widget<Container>(
    find.ancestor(of: find.text(label), matching: find.byType(Container)).first,
  );
  return (badge.decoration! as BoxDecoration).color!;
}

/// 徽标文字色。
Color _badgeForeground(WidgetTester tester, String label) =>
    tester.widget<Text>(find.text(label)).style!.color!;

/// `MemorySummaryEditor` 视图 / 编辑模式测试。
///
/// 条目解析本身的用例在 `memory_entry_format_test.dart`（格式真源）；本文件只
/// 验证组件行为：新格式与旧格式（兼容渲染）都按条目卡片渲染、**合并区间条目
/// （`11~15`）以灰阶徽标渲染（亮/暗主题各一例）**、常规条目仍为品牌蓝徽标、
/// 非结构化文本原样展示、编辑保存回调。
void main() {
  group('MemorySummaryEditor', () {
    testWidgets('视图模式按条目渲染轮次徽标/时间/内容（新格式）', (tester) async {
      final controller = TextEditingController(
        text: '- 1 | 2026年10月1日03:32:31 | 主角初入宗门。\n'
            '- 2 | 2026年10月3日12:00:00 | 主角获胜。',
      );
      await tester.pumpWidget(_wrap(MemorySummaryEditor(controller: controller)));
      expect(find.text('第1轮'), findsOneWidget);
      expect(find.text('第2轮'), findsOneWidget);
      expect(find.text('2026年10月1日03:32:31'), findsOneWidget);
      expect(find.text('2026年10月3日12:00:00'), findsOneWidget);
      expect(find.text('主角初入宗门。'), findsOneWidget);
      expect(find.text('主角获胜。'), findsOneWidget);
      controller.dispose();
    });

    testWidgets('视图模式兼容旧格式（`- 第N轮｜日期：xxx｜概括内容`）', (tester) async {
      final controller = TextEditingController(
        text: '- 第1轮｜日期：第一天 清晨｜主角初入宗门。\n'
            '- 第2轮｜日期：第三天 午时｜主角获胜。',
      );
      await tester.pumpWidget(_wrap(MemorySummaryEditor(controller: controller)));
      expect(find.text('第1轮'), findsOneWidget);
      expect(find.text('第2轮'), findsOneWidget);
      expect(find.text('第一天 清晨'), findsOneWidget);
      expect(find.text('第三天 午时'), findsOneWidget);
      expect(find.text('主角初入宗门。'), findsOneWidget);
      expect(find.text('主角获胜。'), findsOneWidget);
      controller.dispose();
    });

    testWidgets('视图模式兼容无「时间：」前缀的旧条目', (tester) async {
      final controller = TextEditingController(
        text: '- 第1轮｜第一天 清晨｜主角初入宗门。\n'
            '- 第2轮｜第三天 午时｜主角获胜。',
      );
      await tester.pumpWidget(_wrap(MemorySummaryEditor(controller: controller)));
      expect(find.text('第1轮'), findsOneWidget);
      expect(find.text('第2轮'), findsOneWidget);
      expect(find.text('第一天 清晨'), findsOneWidget);
      expect(find.text('第三天 午时'), findsOneWidget);
      expect(find.text('主角初入宗门。'), findsOneWidget);
      expect(find.text('主角获胜。'), findsOneWidget);
      controller.dispose();
    });

    testWidgets('视图模式新旧混排：两种格式都渲染为卡片，杂散行兜底显示', (tester) async {
      final controller = TextEditingController(
        text: '- 第1轮｜日期：第一天 清晨｜主角初入宗门。\n'
            '- 2 | 第三天 午时 | 主角获胜。\n'
            '这一行不是条目格式。',
      );
      await tester.pumpWidget(_wrap(MemorySummaryEditor(controller: controller)));
      expect(find.text('第1轮'), findsOneWidget);
      expect(find.text('第2轮'), findsOneWidget);
      expect(find.text('第一天 清晨'), findsOneWidget);
      expect(find.text('第三天 午时'), findsOneWidget);
      expect(find.text('主角初入宗门。'), findsOneWidget);
      expect(find.text('主角获胜。'), findsOneWidget);
      // 未命中格式的行原样保留（不丢数据）。
      expect(find.text('这一行不是条目格式。'), findsOneWidget);
      controller.dispose();
    });

    testWidgets('时间缺失的条目显示「（未标注时间）」', (tester) async {
      final controller = TextEditingController(text: '- 1 |  | 主角初入宗门。');
      await tester.pumpWidget(_wrap(MemorySummaryEditor(controller: controller)));
      expect(find.text('（未标注时间）'), findsOneWidget);
      controller.dispose();
    });

    testWidgets('合并区间条目渲染为卡片（徽标保留原文分隔符，不进兜底文本）', (tester) async {
      final controller = TextEditingController(
        text: '- 11~15 | 第一天 清晨 | 区间概括。\n'
            '- 16 | 第二天 午时 | 主角获胜。',
      );
      await tester.pumpWidget(_wrap(MemorySummaryEditor(controller: controller)));
      expect(find.text('第11~15轮'), findsOneWidget);
      expect(find.text('区间概括。'), findsOneWidget);
      expect(find.text('第一天 清晨'), findsOneWidget);
      expect(find.text('第16轮'), findsOneWidget);
      // 合并行必须作为条目卡片渲染，而不是落到兜底原文里。
      expect(find.text('- 11~15 | 第一天 清晨 | 区间概括。'), findsNothing);
      controller.dispose();
    });

    testWidgets('合并条目两行布局：首行轮次+时间，次行内容整宽；单轮条目保持原布局', (tester) async {
      final controller = TextEditingController(
        text: '- 11~15 | 第一天 清晨 | 区间概括。\n'
            '- 16 | 第二天 午时 | 主角获胜。',
      );
      await tester.pumpWidget(_wrap(MemorySummaryEditor(controller: controller)));

      final mergedBadge = find
          .ancestor(of: find.text('第11~15轮'), matching: find.byType(Container))
          .first;
      // 首行：徽标与时间同处一行（垂直中心一致）。
      expect(
        tester.getCenter(find.text('第一天 清晨')).dy,
        closeTo(tester.getCenter(mergedBadge).dy, 0.5),
      );
      // 次行：内容另起一行，且与徽标左对齐（整宽，不再缩进在徽标右侧）。
      final mergedContent = tester.getTopLeft(find.text('区间概括。'));
      expect(
        mergedContent.dx,
        closeTo(tester.getTopLeft(mergedBadge).dx, 0.5),
      );
      expect(
        mergedContent.dy,
        greaterThanOrEqualTo(tester.getBottomLeft(mergedBadge).dy),
      );

      // 单轮条目保持原布局：时间与内容都在徽标右侧（缩进）。
      final singleBadge = find
          .ancestor(of: find.text('第16轮'), matching: find.byType(Container))
          .first;
      expect(
        tester.getTopLeft(find.text('第二天 午时')).dx,
        greaterThan(tester.getTopLeft(singleBadge).dx),
      );
      expect(
        tester.getTopLeft(find.text('主角获胜。')).dx,
        greaterThan(tester.getTopLeft(singleBadge).dx),
      );
      controller.dispose();
    });

    for (final (name, theme) in [
      ('浅色', NarrChatTheme.light),
      ('深色', NarrChatTheme.dark),
    ]) {
      testWidgets('合并条目徽标走灰阶主题色、常规条目仍为品牌蓝（$name）', (tester) async {
        final controller = TextEditingController(
          text: '- 11~15 | 第一天 清晨 | 区间概括。\n'
              '- 16 | 第二天 午时 | 主角获胜。',
        );
        await tester.pumpWidget(
          _wrap(MemorySummaryEditor(controller: controller), theme: theme),
        );
        final scheme = theme.colorScheme;
        // 合并条目：灰阶底纹 + 灰阶文字（亮/暗主题各取自己的 ColorScheme token）。
        expect(_badgeBackground(tester, '第11~15轮'), scheme.surfaceContainerHighest);
        expect(_badgeForeground(tester, '第11~15轮'), scheme.onSurfaceVariant);
        // 常规单轮条目：品牌蓝徽标不变（两态可区分）。
        expect(
          _badgeBackground(tester, '第16轮'),
          NarrChatTheme.primary.withValues(alpha: 0.1),
        );
        expect(_badgeForeground(tester, '第16轮'), NarrChatTheme.primary);
        controller.dispose();
      });
    }

    testWidgets('非结构化文本原样展示（不丢数据）', (tester) async {
      final controller = TextEditingController(text: '主角初入宗门。');
      await tester.pumpWidget(_wrap(MemorySummaryEditor(controller: controller)));
      expect(find.text('主角初入宗门。'), findsOneWidget);
      controller.dispose();
    });

    testWidgets('进入编辑并保存时回调 onSave', (tester) async {
      final controller = TextEditingController(
        text: '- 第1轮｜日期：第一天 清晨｜主角初入宗门。',
      );
      String? saved;
      await tester.pumpWidget(
        _wrap(
          MemorySummaryEditor(
            controller: controller,
            onSave: (v) => saved = v,
          ),
        ),
      );
      // 点击「编辑」进入原始文本模式
      await tester.tap(find.text('编辑'));
      await tester.pump();
      expect(find.text('原始文本编辑'), findsOneWidget);
      final field = find.byType(TextField);
      expect(field, findsOneWidget);
      // 追加一行（新格式）
      await tester.enterText(
        field,
        '- 第1轮｜日期：第一天 清晨｜主角初入宗门。\n'
        '- 2 | 第三天 午时 | 主角获胜。',
      );
      // 点击「完成」立即保存
      await tester.tap(find.text('完成'));
      await tester.pump();
      expect(saved, contains('- 2 | 第三天 午时 | 主角获胜。'));
      expect(controller.text, contains('- 2 | 第三天 午时 | 主角获胜。'));
      controller.dispose();
    });
  });
}
