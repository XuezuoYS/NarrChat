import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/chat/branch_panel.dart';
import 'package:narrchat/models/branch.dart';

Branch _defaultBranch() => Branch(
      branchUuid: Branch.defaultBranchUuid,
      branchName: Branch.defaultBranchName,
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
      branchWorking: true,
    );

Branch _ifBranch({
  String uuid = 'b-if',
  String name = '另一种可能',
  int fatherRowIndex = 12,
}) =>
    Branch(
      branchUuid: uuid,
      branchName: name,
      fatherRowIndex: fatherRowIndex,
      createdAt: DateTime.utc(2026, 1, 2),
      updatedAt: DateTime.utc(2026, 1, 2),
    );

/// 面板本身不碰 Provider，全部通过回调，所以可以直接测。
void main() {
  late List<String> switched;
  late List<String> renamed;
  late List<String> deleted;

  Future<void> pumpPanel(
    WidgetTester tester, {
    List<Branch>? branches,
    String workingBranchUuid = Branch.defaultBranchUuid,
    Future<String?> Function(Branch)? onRename,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: BranchPanel(
              branches: branches ?? [_defaultBranch(), _ifBranch()],
              workingBranchUuid: workingBranchUuid,
              onSwitch: switched.add,
              onRename: onRename ??
                  (branch) async {
                    renamed.add(branch.branchUuid);
                    return branch.branchName;
                  },
              onDelete: (branch) async => deleted.add(branch.branchUuid),
            ),
          ),
        ),
      ),
    );
  }

  setUp(() {
    switched = [];
    renamed = [];
    deleted = [];
  });

  group('展示', () {
    testWidgets('默认分支显示为「主线」，非默认分支显示自己的名字', (tester) async {
      await pumpPanel(tester);
      expect(find.text('主线'), findsOneWidget);
      expect(find.text('另一种可能'), findsOneWidget);
    });

    testWidgets('默认分支标注不可删除，其它分支显示从第几轮分叉', (tester) async {
      await pumpPanel(tester);
      expect(find.textContaining('默认分支'), findsOneWidget);
      expect(find.text('从第 12 轮分叉'), findsOneWidget);
    });

    testWidgets('当前工作分支打勾，其它空心', (tester) async {
      await pumpPanel(tester, workingBranchUuid: 'b-if');
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      expect(find.byIcon(Icons.circle_outlined), findsOneWidget);
    });

    testWidgets('没有分支时给出空态文案', (tester) async {
      await pumpPanel(tester, branches: const []);
      expect(find.text('还没有分支'), findsOneWidget);
    });
  });

  group('切换', () {
    testWidgets('点非当前分支 → 切换', (tester) async {
      await pumpPanel(tester);
      await tester.tap(find.text('另一种可能'));
      await tester.pumpAndSettle();
      expect(switched, ['b-if']);
    });

    testWidgets('点当前分支不触发切换（避免无意义重载）', (tester) async {
      await pumpPanel(tester, workingBranchUuid: 'b-if');
      await tester.tap(find.text('另一种可能'));
      await tester.pumpAndSettle();
      expect(switched, isEmpty);
    });
  });

  group('结构化操作', () {
    testWidgets('默认分支没有操作菜单（不可改名/删除）', (tester) async {
      await pumpPanel(tester);
      // 只有一条非默认分支，所以菜单按钮只有一个。
      expect(find.byTooltip('分支操作'), findsOneWidget);
    });

    testWidgets('重命名走回调', (tester) async {
      await pumpPanel(
        tester,
        onRename: (branch) async {
          renamed.add(branch.branchUuid);
          return '新名字';
        },
      );
      await tester.tap(find.byTooltip('分支操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('重命名'));
      await tester.pumpAndSettle();
      expect(renamed, ['b-if']);
    });

    testWidgets('删除先确认：取消则不回调', (tester) async {
      await pumpPanel(tester);
      await tester.tap(find.byTooltip('分支操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除分支'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(deleted, isEmpty);
    });

    testWidgets('删除确认后回调，且提示会连带删除轮次', (tester) async {
      await pumpPanel(tester);
      await tester.tap(find.byTooltip('分支操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除分支'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('轮次会一起删除'),
        findsOneWidget,
        reason: '删除是破坏性操作，必须说清代价',
      );
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();
      expect(deleted, ['b-if']);
    });
  });
}
