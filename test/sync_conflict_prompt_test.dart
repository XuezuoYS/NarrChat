import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/sync/sync_conflict.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/sync_conflict_prompt_dialog.dart';

import 'helpers/sync_conflict_fixtures.dart';

/// 同步中「三选一」对话框：三个动作 + 两个二次确认分支 + 关闭 = 冲突决策。
void main() {
  SyncConflictPromptResult? result;

  Future<void> pumpPrompt(
    WidgetTester tester, {
    List<SyncConflict>? pending,
  }) async {
    result = null;
    final conflicts = pending ?? [buildBookConflict()];
    await tester.pumpWidget(
      MaterialApp(
        theme: NarrChatTheme.light,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () {
                  showSyncConflictPrompt(
                    context,
                    conflicts,
                  ).then((value) => result = value);
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  testWidgets('展示第一项摘要与三项动作', (tester) async {
    await pumpPrompt(tester);

    expect(find.text('检测到同步冲突'), findsOneWidget);
    expect(find.text('书籍《测试书》'), findsOneWidget);
    expect(find.textContaining('第 4 代'), findsOneWidget);
    expect(find.textContaining('device-a'), findsOneWidget);
    expect(find.text('冲突决策（逐项选择）'), findsOneWidget);
    expect(find.text('采用云端备份'), findsOneWidget);
    expect(find.text('暂停同步并改为手动'), findsOneWidget);
  });

  testWidgets('点主按钮：返回 decide', (tester) async {
    await pumpPrompt(tester);

    await tester.tap(find.text('冲突决策（逐项选择）'));
    await tester.pumpAndSettle();

    expect(result, SyncConflictPromptResult.decide);
    expect(find.text('检测到同步冲突'), findsNothing);
  });

  testWidgets('采用云端：二次确认后返回 adoptRemote', (tester) async {
    await pumpPrompt(tester);

    await tester.tap(find.text('采用云端备份'));
    await tester.pumpAndSettle();
    expect(find.text('采用云端备份？'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '采用云端'));
    await tester.pumpAndSettle();

    expect(result, SyncConflictPromptResult.adoptRemote);
  });

  testWidgets('采用云端：二次确认取消 → 转入 decide', (tester) async {
    await pumpPrompt(tester);

    await tester.tap(find.text('采用云端备份'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();

    expect(result, SyncConflictPromptResult.decide);
  });

  testWidgets('暂停同步：二次确认后返回 pause', (tester) async {
    await pumpPrompt(tester);

    await tester.tap(find.text('暂停同步并改为手动'));
    await tester.pumpAndSettle();
    expect(find.text('暂停同步？'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '暂停同步'));
    await tester.pumpAndSettle();

    expect(result, SyncConflictPromptResult.pause);
  });

  testWidgets('暂停同步：二次确认取消 → 转入 decide', (tester) async {
    await pumpPrompt(tester);

    await tester.tap(find.text('暂停同步并改为手动'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();

    expect(result, SyncConflictPromptResult.decide);
  });

  testWidgets('点空白关闭：视为冲突决策（不是暂停）', (tester) async {
    await pumpPrompt(tester);

    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();

    expect(result, SyncConflictPromptResult.decide);
  });

  testWidgets('多项冲突：显示「另有 N 项」', (tester) async {
    await pumpPrompt(
      tester,
      pending: [
        buildBookConflict(uuid: 'b1', title: '第一本'),
        buildBookConflict(uuid: 'b2', title: '第二本'),
      ],
    );

    expect(find.text('另有 1 项也需要你选择'), findsOneWidget);
  });
}
