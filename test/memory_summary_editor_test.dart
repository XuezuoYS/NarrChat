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

void main() {
  group('parseMemoryEntries', () {
    test('解析「- 第N轮｜日期：xxx｜概括内容」为条目（三者绑定）', () {
      const text = '- 第1轮｜日期：第一天 清晨｜主角初入宗门。\n'
          '- 第2轮｜日期：第三天 午时｜主角获胜。';
      final entries = parseMemoryEntries(text);
      expect(entries, hasLength(2));
      expect(entries[0].round, 1);
      expect(entries[0].date, '第一天 清晨');
      expect(entries[0].content, '主角初入宗门。');
      expect(entries[1].round, 2);
      expect(entries[1].date, '第三天 午时');
      expect(entries[1].content, '主角获胜。');
    });

    test('容忍半角分隔符、`*` 列表符与概括内容内的分隔符', () {
      const text = '* 第1轮 | 日期: 第一天 | 遇到苏清月｜结伴同行';
      final entries = parseMemoryEntries(text);
      expect(entries, hasLength(1));
      expect(entries.single.round, 1);
      expect(entries.single.date, '第一天');
      expect(entries.single.content, '遇到苏清月｜结伴同行');
    });

    test('兼容时间部分省略标签（无「时间：」前缀）', () {
      const text = '- 第1轮｜第一天 清晨｜主角初入宗门。\n'
          '- 第2轮｜第三天 午时｜主角获胜。';
      final entries = parseMemoryEntries(text);
      expect(entries, hasLength(2));
      expect(entries[0].round, 1);
      expect(entries[0].date, '第一天 清晨');
      expect(entries[0].content, '主角初入宗门。');
      expect(entries[1].round, 2);
      expect(entries[1].date, '第三天 午时');
      expect(entries[1].content, '主角获胜。');
    });

    test('兼容「时间：」标签与省略标签混用', () {
      const text = '- 第1轮｜时间：第一天 清晨｜主角初入宗门。\n'
          '- 第2轮｜第三天 午时｜主角获胜。';
      final entries = parseMemoryEntries(text);
      expect(entries, hasLength(2));
      expect(entries[0].round, 1);
      expect(entries[0].date, '第一天 清晨');
      expect(entries[1].round, 2);
      expect(entries[1].date, '第三天 午时');
    });

    test('无法解析的行被忽略（返回空列表）', () {
      expect(parseMemoryEntries('主角初入宗门。'), isEmpty);
      expect(parseMemoryEntries(''), isEmpty);
      expect(parseMemoryEntries('第1轮 第一天 内容'), isEmpty);
    });
  });

  group('MemorySummaryEditor', () {
    testWidgets('视图模式按条目渲染轮数徽标/日期/概括', (tester) async {
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

    testWidgets('视图模式兼容无「时间：」前缀的条目', (tester) async {
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
      // 追加一行
      await tester.enterText(
        field,
        '- 第1轮｜日期：第一天 清晨｜主角初入宗门。\n'
        '- 第2轮｜日期：第三天 午时｜主角获胜。',
      );
      // 点击「完成」立即保存
      await tester.tap(find.text('完成'));
      await tester.pump();
      expect(saved, contains('第2轮'));
      expect(controller.text, contains('第2轮'));
      controller.dispose();
    });
  });
}
