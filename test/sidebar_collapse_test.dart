import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/markdown_collapsible_editor.dart';
import 'package:narrchat/widgets/markdown_field.dart';
import 'package:narrchat/widgets/memory_summary_editor.dart';
import 'package:narrchat/widgets/sidebar_panel.dart';

void main() {
  Future<void> pumpSidebar(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: NarrChatTheme.light,
        home: Scaffold(
          body: SizedBox(
            width: 380,
            height: 800,
            child: SidebarPanel(
              round: const Round(
                bookId: 1,
                roundIndex: 1,
                worldState: '- 地点：青云宗',
                characterState: '## 女主角\n### 苏清月\n- 心情：平静',
                memorySummary: '- 第1轮｜日期：第一天 清晨｜主角初入宗门。',
                currentTime: '第三天 午时',
              ),
              isHistoryView: false,
              onAutoSaveField: (r, f, v) async => true,
              onBackToCurrent: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('侧边栏渲染 4 个吸顶标题栏与各编辑器', (tester) async {
    await pumpSidebar(tester);
    expect(find.byType(CustomScrollView), findsOneWidget);
    expect(find.byType(SliverPersistentHeader), findsNWidgets(4));
    // 「当前时间」标题与输入框 hint 同名，此处不按文本数断言。
    expect(find.text('世界状态'), findsOneWidget);
    expect(find.text('角色状态'), findsOneWidget);
    expect(find.text('记忆总结'), findsOneWidget);
    expect(find.byType(MemorySummaryEditor), findsOneWidget);
  });

  testWidgets('点击「记忆总结」标题栏可折叠/展开', (tester) async {
    await pumpSidebar(tester);
    // 初始展开。
    expect(find.byType(MemorySummaryEditor), findsOneWidget);
    // 折叠。
    await tester.tap(find.text('记忆总结'));
    await tester.pumpAndSettle();
    expect(find.byType(MemorySummaryEditor), findsNothing);
    expect(find.text('已折叠'), findsOneWidget);
    // 展开。
    await tester.tap(find.text('记忆总结'));
    await tester.pumpAndSettle();
    expect(find.byType(MemorySummaryEditor), findsOneWidget);
    expect(find.text('已折叠'), findsNothing);
  });

  testWidgets('折叠「角色状态」后其编辑器隐藏', (tester) async {
    await pumpSidebar(tester);
    expect(find.byType(MarkdownCollapsibleEditor), findsOneWidget);
    await tester.tap(find.text('角色状态'));
    await tester.pumpAndSettle();
    expect(find.byType(MarkdownCollapsibleEditor), findsNothing);
    expect(find.text('已折叠'), findsOneWidget);
  });

  testWidgets('标题栏【编辑】/【保存】驱动当前模块编辑器', (tester) async {
    await pumpSidebar(tester);
    // 世界状态编辑器初始为视图模式（无 TextField）。
    final worldField = find.descendant(
      of: find.byType(MarkdownField),
      matching: find.byType(TextField),
    );
    expect(worldField, findsNothing);
    // 找到「世界状态」吸顶标题栏。
    final worldHeader = find.ancestor(
      of: find.text('世界状态'),
      matching: find.byType(SliverPersistentHeader),
    );
    expect(worldHeader, findsOneWidget);
    // 点击标题栏【编辑】进入编辑模式。
    await tester.tap(
      find.descendant(of: worldHeader, matching: find.text('编辑')),
    );
    await tester.pumpAndSettle();
    expect(worldField, findsOneWidget);
    // 点击标题栏【保存】退出编辑并保存。
    await tester.tap(
      find.descendant(of: worldHeader, matching: find.text('保存')),
    );
    await tester.pumpAndSettle();
    expect(worldField, findsNothing);
  });

  testWidgets('长内容滚动到底后，前面的标题栏随组滚出视口、不叠层', (tester) async {
    // 长角色状态：使侧边栏内容远超视口、可大幅滚动。
    final sb = StringBuffer('# 主角\n');
    for (var i = 0; i < 30; i++) {
      sb.writeln('## 角色$i');
      sb.writeln('- 属性A：值$i');
      sb.writeln('- 属性B：值$i');
    }
    await tester.pumpWidget(
      MaterialApp(
        theme: NarrChatTheme.light,
        home: Scaffold(
          body: SizedBox(
            width: 380,
            height: 500,
            child: SidebarPanel(
              round: Round(bookId: 1, roundIndex: 1, characterState: sb.toString()),
              isHistoryView: false,
              onAutoSaveField: (r, f, v) async => true,
              onBackToCurrent: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 滚动到底部。
    for (var i = 0; i < 10; i++) {
      await tester.drag(find.byType(SidebarPanel), const Offset(0, -600));
      await tester.pumpAndSettle();
    }
    // 关键断言：前面的「当前时间」「世界状态」标题栏已随组滚出视口（不在树中），
    // 不再叠层堆在顶部；一次只有一个标题栏（当前模块「角色状态」）固定在顶部。
    expect(find.text('当前时间'), findsNothing);
    expect(find.text('世界状态'), findsNothing);
    expect(find.text('角色状态'), findsOneWidget);
  });
}
