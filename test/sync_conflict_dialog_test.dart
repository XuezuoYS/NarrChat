import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/sync_conflict_dialog.dart';

/// 同步冲突对话框测试：两个选项（取消同步 / 解决冲突）与关闭默认值。
void main() {
  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: NarrChatTheme.light,
        home: const Scaffold(body: SizedBox()),
      ),
    );
    await tester.pump();
  }

  /// 以 Scaffold（位于 MaterialApp 内部）为上下文打开对话框。
  Future<SyncConflictAction> openDialog(WidgetTester tester) {
    return showSyncConflictDialog(tester.element(find.byType(Scaffold)));
  }

  testWidgets('展示冲突说明与两个按钮', (tester) async {
    await pumpApp(tester);
    final future = openDialog(tester);
    await tester.pumpAndSettle();

    expect(find.text('检测到同步冲突'), findsOneWidget);
    expect(find.text('取消同步'), findsOneWidget);
    expect(find.text('解决冲突'), findsOneWidget);
    // 关闭避免泄漏路由。
    Navigator.of(tester.element(find.byType(Scaffold))).pop();
    await tester.pumpAndSettle();
    expect(await future, SyncConflictAction.cancelSync);
  });

  testWidgets('点「解决冲突」返回 resolve', (tester) async {
    await pumpApp(tester);
    final future = openDialog(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.text('解决冲突'));
    await tester.pumpAndSettle();
    expect(await future, SyncConflictAction.resolve);
  });

  testWidgets('点「取消同步」返回 cancelSync', (tester) async {
    await pumpApp(tester);
    final future = openDialog(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.text('取消同步'));
    await tester.pumpAndSettle();
    expect(await future, SyncConflictAction.cancelSync);
  });

  testWidgets('关闭对话框（返回键）视为取消同步', (tester) async {
    await pumpApp(tester);
    final future = openDialog(tester);
    await tester.pumpAndSettle();

    Navigator.of(tester.element(find.byType(Scaffold))).pop();
    await tester.pumpAndSettle();
    expect(await future, SyncConflictAction.cancelSync);
  });
}
