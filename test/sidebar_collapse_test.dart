import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/markdown_collapsible_editor.dart';
import 'package:narrchat/widgets/markdown_field.dart';
import 'package:narrchat/widgets/memory_summary_editor.dart';
import 'package:narrchat/widgets/plain_text_field_editor.dart';
import 'package:narrchat/widgets/sidebar_panel.dart';

void main() {
  /// 保存记录（field, value），用于断言「仅显式保存才写库」。
  final saves = <(String, String)>[];

  Future<void> pumpSidebar(
    WidgetTester tester, {
    Future<bool> Function(String field, String value)? onSaveField,
  }) async {
    saves.clear();
    await tester.pumpWidget(
      MaterialApp(
        theme: NarrChatTheme.light,
        home: Scaffold(
          body: SizedBox(
            width: 380,
            height: 800,
            child: SidebarPanel(
              round: const Round(
                bookUuid: 'b1',
                roundIndex: 1,
                worldState: '- 地点：青云宗',
                characterState: '## 女主角\n### 苏清月\n- 心情：平静',
                memorySummary: '- 第1轮｜日期：第一天 清晨｜主角初入宗门。',
                currentTime: '第三天 午时',
              ),
              isHistoryView: false,
              onSaveField: (r, f, v) async {
                saves.add((f, v));
                return onSaveField?.call(f, v) ?? true;
              },
              onBackToCurrent: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 定位指定子模块的吸顶标题栏。
  Finder sectionHeader(String label) => find.ancestor(
        of: find.text(label),
        matching: find.byType(SliverPersistentHeader),
      );

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
    // 点击标题栏【编辑】进入编辑模式。
    await tester.tap(
      find.descendant(of: sectionHeader('世界状态'), matching: find.text('编辑')),
    );
    await tester.pumpAndSettle();
    expect(worldField, findsOneWidget);
    // 编辑中标题栏显示【保存】/【取消】，不再显示【编辑】。
    // 布局顺序：左「取消」、右「保存」；保存带填充底纹（FilledButton），
    // 且与「编辑/取消」同款紧凑尺寸（底纹与悬停底纹面积一致）。
    final cancelBtn = find.descendant(
      of: sectionHeader('世界状态'),
      matching: find.widgetWithText(TextButton, '取消'),
    );
    final saveBtn = find.descendant(
      of: sectionHeader('世界状态'),
      matching: find.widgetWithText(FilledButton, '保存'),
    );
    expect(cancelBtn, findsOneWidget);
    expect(saveBtn, findsOneWidget);
    expect(
      tester.getTopLeft(cancelBtn).dx,
      lessThan(tester.getTopLeft(saveBtn).dx),
    );
    // 「保存」填充底纹与「取消」（悬停底纹）尺寸一致。
    expect(
      tester.getSize(saveBtn).height,
      tester.getSize(cancelBtn).height,
    );
    expect(
      tester.getSize(saveBtn).width,
      tester.getSize(cancelBtn).width,
    );
    expect(
      find.descendant(
        of: sectionHeader('世界状态'),
        matching: find.widgetWithText(FilledButton, '保存'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: sectionHeader('世界状态'), matching: find.text('编辑')),
      findsNothing,
    );
    // 点击标题栏【保存】退出编辑并保存。
    await tester.tap(
      find.descendant(of: sectionHeader('世界状态'), matching: find.text('保存')),
    );
    await tester.pumpAndSettle();
    expect(worldField, findsNothing);
  });

  testWidgets('编辑后不自动保存，点击【保存】才写库并以 SnackBar 提示', (tester) async {
    await pumpSidebar(tester);
    expect(find.textContaining('自动保存'), findsNothing);
    // 进入「世界状态」编辑并修改内容。
    await tester.tap(
      find.descendant(of: sectionHeader('世界状态'), matching: find.text('编辑')),
    );
    await tester.pumpAndSettle();
    final worldField = find.descendant(
      of: find.byType(MarkdownField),
      matching: find.byType(TextField),
    );
    await tester.enterText(worldField, '- 地点：青云宗\n- 掌门：苏清月');
    // 等待超过旧防抖时长：仍不应有自动保存。
    await tester.pump(const Duration(milliseconds: 900));
    expect(saves, isEmpty);
    // 点击【保存】→ 写库一次 + SnackBar「已保存」。
    await tester.tap(
      find.descendant(of: sectionHeader('世界状态'), matching: find.text('保存')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(saves, [('world_state', '- 地点：青云宗\n- 掌门：苏清月')]);
    expect(find.text('已保存'), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('点击【取消】放弃修改：不写库且还原为已保存内容', (tester) async {
    await pumpSidebar(tester);
    await tester.tap(
      find.descendant(of: sectionHeader('世界状态'), matching: find.text('编辑')),
    );
    await tester.pumpAndSettle();
    final worldField = find.descendant(
      of: find.byType(MarkdownField),
      matching: find.byType(TextField),
    );
    await tester.enterText(worldField, '- 地点：魔窟');
    await tester.tap(
      find.descendant(of: sectionHeader('世界状态'), matching: find.text('取消')),
    );
    await tester.pumpAndSettle();
    expect(saves, isEmpty);
    expect(worldField, findsNothing);
    // 再次进入编辑：编辑框内容应为原始已保存内容（修改已被放弃）。
    await tester.tap(
      find.descendant(of: sectionHeader('世界状态'), matching: find.text('编辑')),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(worldField).controller!.text,
      '- 地点：青云宗',
    );
  });

  testWidgets('「当前时间」子栏：编辑/保存/取消（平台编辑器）', (tester) async {
    await pumpSidebar(tester);
    // 视图模式直接显示当前时间文本。
    expect(find.byType(PlainTextFieldEditor), findsOneWidget);
    expect(find.text('第三天 午时'), findsOneWidget);
    // 编辑并保存。
    await tester.tap(
      find.descendant(of: sectionHeader('当前时间'), matching: find.text('编辑')),
    );
    await tester.pumpAndSettle();
    final timeField = find.descendant(
      of: find.byType(PlainTextFieldEditor),
      matching: find.byType(TextField),
    );
    expect(timeField, findsOneWidget);
    await tester.enterText(timeField, '第四天 子时');
    await tester.tap(
      find.descendant(of: sectionHeader('当前时间'), matching: find.text('保存')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(saves, [('current_time', '第四天 子时')]);
    expect(find.text('已保存'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('第四天 子时'), findsOneWidget);
    // 再次编辑后取消：还原为已保存内容，不写库。
    await tester.tap(
      find.descendant(of: sectionHeader('当前时间'), matching: find.text('编辑')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(timeField, '第五天 卯时');
    await tester.tap(
      find.descendant(of: sectionHeader('当前时间'), matching: find.text('取消')),
    );
    await tester.pumpAndSettle();
    expect(saves, [('current_time', '第四天 子时')]);
    expect(find.text('第四天 子时'), findsOneWidget);
  });

  testWidgets('保存失败时以 SnackBar 提示「保存失败」', (tester) async {
    await pumpSidebar(tester, onSaveField: (f, v) async => false);
    await tester.tap(
      find.descendant(of: sectionHeader('当前时间'), matching: find.text('编辑')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: sectionHeader('当前时间'), matching: find.text('保存')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('保存失败'), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('历史轮次视图下同样支持编辑/保存/取消', (tester) async {
    final historySaves = <(String, String)>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: NarrChatTheme.light,
        home: Scaffold(
          body: SizedBox(
            width: 380,
            height: 800,
            child: SidebarPanel(
              round: const Round(
                bookUuid: 'b1',
                roundIndex: 1,
                currentTime: '第三天 午时',
              ),
              isHistoryView: true,
              onSaveField: (r, f, v) async {
                historySaves.add((f, v));
                return true;
              },
              onBackToCurrent: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('历史轮次（第 1 轮）'), findsOneWidget);
    await tester.tap(
      find.descendant(of: sectionHeader('当前时间'), matching: find.text('编辑')),
    );
    await tester.pumpAndSettle();
    final timeField = find.descendant(
      of: find.byType(PlainTextFieldEditor),
      matching: find.byType(TextField),
    );
    await tester.enterText(timeField, '第四天 子时');
    await tester.tap(
      find.descendant(of: sectionHeader('当前时间'), matching: find.text('保存')),
    );
    await tester.pumpAndSettle();
    expect(historySaves, [('current_time', '第四天 子时')]);
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
              round: Round(
                bookUuid: 'b1',
                roundIndex: 1,
                characterState: sb.toString(),
              ),
              isHistoryView: false,
              onSaveField: (r, f, v) async => true,
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
