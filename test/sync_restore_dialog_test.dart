import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/webdav_service.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/sync_restore_dialog.dart';

/// 快照恢复对话框（新版）测试：
/// - 展示「第 N 代 + 时间 + 大小」元信息与文件名；
/// - 默认选「合并」；可切换「删除并恢复」并出现不可撤销警告；
/// - 确认 / 取消的返回值。
const _snapshot = WebDavFile(
  name: 'narrchat_snapshot_g5_20260816_103005.db',
  size: 2048,
);

void main() {
  Future<SyncRestoreMode?> open(WidgetTester tester) {
    return showSyncRestoreDialog(
      tester.element(find.byType(Scaffold)),
      file: _snapshot,
    );
  }

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: NarrChatTheme.light,
        home: const Scaffold(body: SizedBox()),
      ),
    );
    await tester.pump();
  }

  testWidgets('展示新版命名信息：第 N 代 · 时间 · 大小 · 文件名', (tester) async {
    await pumpApp(tester);
    final future = open(tester);
    await tester.pumpAndSettle();

    expect(find.text('第 5 代'), findsOneWidget);
    expect(find.textContaining('2026-08-16 10:30:05'), findsOneWidget);
    expect(find.textContaining('2.0 KB'), findsOneWidget);
    expect(find.text(_snapshot.name), findsOneWidget);
    // 默认选「合并」（安全侧）。
    expect(find.widgetWithText(FilledButton, '合并'), findsOneWidget);
    Navigator.of(tester.element(find.byType(Scaffold))).pop();
    await tester.pumpAndSettle();
    expect(await future, isNull);
  });

  testWidgets('默认确认返回 merge', (tester) async {
    await pumpApp(tester);
    final future = open(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, '合并'));
    await tester.pumpAndSettle();
    expect(await future, SyncRestoreMode.merge);
  });

  testWidgets('切换「删除并恢复」：出现不可撤销警告，确认返回 replace', (tester) async {
    await pumpApp(tester);
    final future = open(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.text('删除本地数据并恢复'));
    await tester.pumpAndSettle();
    expect(find.textContaining('无法撤销'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '删除并恢复'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '删除并恢复'));
    await tester.pumpAndSettle();
    expect(await future, SyncRestoreMode.replace);
  });

  testWidgets('点「取消」返回 null', (tester) async {
    await pumpApp(tester);
    final future = open(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await future, isNull);
  });
}
