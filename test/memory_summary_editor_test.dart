import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/memory_summary_editor.dart';

Widget _wrap(Widget child) {
  return MaterialApp(
    theme: NarrChatTheme.light,
    home: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: child,
      ),
    ),
  );
}

/// `MemorySummaryEditor` 视图 / 编辑模式测试。
///
/// 条目解析本身的用例在 `memory_entry_format_test.dart`（格式真源）；本文件只
/// 验证组件行为：新格式与旧格式（兼容渲染）都按条目卡片渲染、非结构化文本原样
/// 展示、编辑保存回调。
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
