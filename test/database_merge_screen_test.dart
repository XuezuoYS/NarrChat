import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/screens/database_merge_screen.dart';
import 'package:narrchat/services/database_merge_service.dart';
import 'package:narrchat/theme/app_theme.dart';

import 'helpers/merge_db.dart';

void main() {
  late DatabaseMergePlan plan;

  setUp(() async {
    final local = await createMergeDb();
    final backup = await createMergeDb();
    try {
      // 冲突书：本地与备份同名但轮次不同。
      final lokA = await local.insert('books', {'title': 'A', 'category': '旧'});
      await local.insert('rounds', {
        'book_id': lokA,
        'round_index': 1,
        'user_input': '本地内容',
        'ai_narrative': '本地正文',
        'created_at': DateTime(2026, 1, 1).toIso8601String(),
      });
      final bakA = await backup.insert('books', {'title': 'A', 'category': '新'});
      await backup.insert('rounds', {
        'book_id': bakA,
        'round_index': 1,
        'user_input': '备份内容',
        'ai_narrative': '备份正文',
        'created_at': DateTime(2026, 2, 1).toIso8601String(),
      });
      // 仅导入有：B。
      final bakB = await backup.insert('books', {'title': 'B'});
      await backup.insert('rounds', {
        'book_id': bakB,
        'round_index': 1,
        'user_input': '云端B',
      });
      // 仅本地有：C。
      await local.insert('books', {'title': 'C'});
      // 全一致：D。
      final lokD = await local.insert('books', {'title': 'D', 'category': '同'});
      await local.insert('rounds', {
        'book_id': lokD,
        'round_index': 1,
        'user_input': '一致',
      });
      final bakD = await backup.insert('books', {'title': 'D', 'category': '同'});
      await backup.insert('rounds', {
        'book_id': bakD,
        'round_index': 1,
        'user_input': '一致',
      });

      plan = await DatabaseMergeService.buildPlan(backup, local);
    } finally {
      await local.close();
      await backup.close();
    }
  });

  testWidgets('列出书籍，冲突展示两侧轮次/时间与状态徽标', (tester) async {
    await _pumpScreen(tester, plan);
    expect(find.text('数据库合并'), findsOneWidget);
    expect(find.text('A'), findsOneWidget);
    expect(find.text('B'), findsOneWidget);
    expect(find.text('C'), findsOneWidget);
    expect(find.text('D'), findsOneWidget);
    expect(find.text('冲突'), findsOneWidget);
    expect(find.text('仅导入有'), findsOneWidget);
    expect(find.text('仅本地有'), findsNWidgets(2)); // 徽标 + 侧卡标签
    expect(find.text('两者全一致'), findsOneWidget);
    // 冲突书展示两侧卡片。
    expect(find.text('导入的备份'), findsNWidgets(2)); // 冲突导入侧 + 仅导入有侧
    expect(find.text('本地'), findsOneWidget);
  });

  testWidgets('切换保留侧并合并 → onApply 收到对应决策', (tester) async {
    final decisions = <String, MergeBookDecision>{};
    var called = false;
    await _pumpScreen(
      tester,
      plan,
      onApply: (p, d) async {
        called = true;
        decisions.addAll(d);
        return DatabaseMergeResult();
      },
    );
    expect(decisions, isEmpty);

    // 默认建议：冲突书 A 的备份较新 → 保留导入；此处切换为「保留本地」。
    await tester.tap(find.text('保留本地'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('合并'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '确认合并'));
    await tester.pumpAndSettle();
    // 走完 SnackBar 计时，避免测试结束残留悬挂计时器。
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    expect(called, isTrue);
    expect(decisions['A'], MergeBookDecision.keepLocal);
    expect(decisions['B'], MergeBookDecision.keepImported); // 默认纳入
    expect(decisions['D'], MergeBookDecision.keepLocal);
  });

  testWidgets('仅导入有的书不可取消，始终导入', (tester) async {
    final decisions = <String, MergeBookDecision>{};
    await _pumpScreen(
      tester,
      plan,
      onApply: (p, d) async {
        decisions.addAll(d);
        return DatabaseMergeResult();
      },
    );
    // 不再提供「取消导入」开关，仅标明「仅导入有，将导入此书」。
    expect(find.byType(Switch), findsNothing);
    expect(find.text('仅导入有，将导入此书'), findsOneWidget);
    await tester.tap(find.text('合并'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '确认合并'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    expect(decisions['B'], MergeBookDecision.keepImported);
  });

  testWidgets('打开时默认按轮次时间最新（备份较新 → 保留导入）', (tester) async {
    final decisions = <String, MergeBookDecision>{};
    await _pumpScreen(
      tester,
      plan,
      onApply: (p, d) async {
        decisions.addAll(d);
        return DatabaseMergeResult();
      },
    );
    await tester.tap(find.text('合并'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '确认合并'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    expect(decisions['A'], MergeBookDecision.keepImported); // 备份时间更新
    expect(decisions['B'], MergeBookDecision.keepImported);
    expect(decisions['D'], MergeBookDecision.keepLocal);
  });

  testWidgets('自动勾选：全本地 → 冲突保留本地、仅导入有仍导入', (tester) async {
    final decisions = <String, MergeBookDecision>{};
    await _pumpScreen(
      tester,
      plan,
      onApply: (p, d) async {
        decisions.addAll(d);
        return DatabaseMergeResult();
      },
    );
    await tester.tap(find.text('自动勾选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全本地'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('合并'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '确认合并'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    expect(decisions['A'], MergeBookDecision.keepLocal);
    expect(decisions['B'], MergeBookDecision.keepImported); // 仅导入有始终导入
  });

  testWidgets('自动勾选：按轮次数最多 → 轮次相同默认保留本地', (tester) async {
    final decisions = <String, MergeBookDecision>{};
    await _pumpScreen(
      tester,
      plan,
      onApply: (p, d) async {
        decisions.addAll(d);
        return DatabaseMergeResult();
      },
    );
    await tester.tap(find.text('自动勾选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('按轮次数最多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('合并'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '确认合并'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    expect(decisions['A'], MergeBookDecision.keepLocal); // 两侧轮次相同 → 保留本地
  });

  testWidgets('点预览打开书籍内容对话框', (tester) async {
    await _pumpScreen(tester, plan);
    await tester.tap(find.byTooltip('预览').first);
    await tester.pumpAndSettle();
    expect(find.text('书籍设置'), findsOneWidget);
    expect(find.textContaining('轮次（'), findsOneWidget);
  });

  testWidgets('左上返回取消导入并退出页面', (tester) async {
    await _pumpScreen(tester, plan);
    expect(find.text('数据库合并'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    expect(find.text('数据库合并'), findsNothing);
  });
}

/// 以 push 方式打开屏幕（使 pop 回到前置路由），并注入可选的 [onApply]。
Future<void> _pumpScreen(
  WidgetTester tester,
  DatabaseMergePlan plan, {
  Future<DatabaseMergeResult> Function(
    DatabaseMergePlan,
    Map<String, MergeBookDecision>,
  )?
  onApply,
}) async {
  // 加大视口，确保 4 本书的卡片都在列表中构建（ListView 遇小视口会懒加载，
  // 导致后面的「仅本地有」等卡片未被构建）。
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      theme: NarrChatTheme.light,
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () =>
                DatabaseMergeScreen.open(context, plan: plan, onApply: onApply),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}
