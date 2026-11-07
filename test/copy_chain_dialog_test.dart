import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/branch.dart';
import 'package:narrchat/models/branch_copy.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/widgets/copy_chain_dialog.dart';

/// 「从此代拷贝链至新的分支」对话框的隔离测试：
/// 三种状态（拷贝中 / 完成 / 失败）与两个完成选项。
///
/// copy 由测试注入（Completer 控制节奏），不碰数据库；端到端接线见
/// `chat_branch_ui_test.dart`。

const Round _targetRound = Round(
  bookUuid: 'b1',
  uuid: 'g3',
  roundIndex: 3,
  roundSerialNum: 2,
);

BranchCopyResult _result({
  int generationCount = 4,
  int firstRoundIndex = 3,
  int lastRoundIndex = 6,
}) {
  return BranchCopyResult(
    branch: Branch(
      branchUuid: 'br2',
      fatherRow: 'g1',
      fatherRowIndex: 1,
      branchName: '分支 2',
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    ),
    generationCount: generationCount,
    firstRoundIndex: firstRoundIndex,
    lastRoundIndex: lastRoundIndex,
  );
}

/// pump 一个最小宿主并打开对话框；返回读取最终结果的 getter。
Future<CopyChainOutcome? Function()> _openDialog(
  WidgetTester tester,
  CopyChainRunner copy,
) async {
  CopyChainOutcome? outcome;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () async {
                outcome = await showCopyChainDialog(
                  context,
                  round: _targetRound,
                  copy: copy,
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pump(); // 推入对话框路由并完成首帧
  await tester.pump(); // 让 post-frame 的拷贝任务启动
  return () => outcome;
}

void main() {
  testWidgets('拷贝中：标题 / 进度条 / 无操作按钮；点遮罩关不掉', (tester) async {
    final gate = Completer<BranchCopyResult>();
    await _openDialog(tester, (onProgress) {
      onProgress?.call(0, 4);
      return gate.future;
    });

    expect(find.text('正在拷贝中'), findsOneWidget);
    expect(find.byKey(const ValueKey('copy-chain-dialog')), findsOneWidget);
    expect(find.byKey(const ValueKey('copy-chain-progress')), findsOneWidget);
    expect(
      find.text('正在拷贝第 3 轮第 2 代及其全部子代…'),
      findsOneWidget,
      reason: '文案要说清拷贝的是哪一代',
    );
    expect(find.text('已拷贝 0 / 4 代'), findsOneWidget);
    expect(find.byKey(const ValueKey('copy-chain-jump')), findsNothing);
    expect(find.byKey(const ValueKey('copy-chain-stay')), findsNothing);

    // 遮罩关闭被禁用：拷贝还在写库时不能把界面带走。
    await tester.tapAt(const Offset(5, 5));
    await tester.pump();
    expect(find.byKey(const ValueKey('copy-chain-dialog')), findsOneWidget);

    gate.complete(_result());
    await tester.pumpAndSettle();
    expect(find.text('拷贝完成'), findsOneWidget);
  });

  testWidgets('完成：展示分支名 / 代数 / 轮次范围；「留在当前分支」返回 stay', (
    tester,
  ) async {
    final gate = Completer<BranchCopyResult>();
    final outcome = await _openDialog(tester, (_) => gate.future);
    gate.complete(_result());
    await tester.pumpAndSettle();

    expect(find.text('拷贝完成'), findsOneWidget);
    expect(find.text('已创建分支「分支 2」'), findsOneWidget);
    expect(find.text('共拷贝 4 代（第 3–6 轮）。'), findsOneWidget);
    expect(find.text('点击跳转'), findsOneWidget);
    expect(find.text('留在当前分支'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('copy-chain-stay')));
    await tester.pumpAndSettle();
    expect(outcome()?.choice, CopyChainChoice.stay);
    expect(outcome()?.result.branch.branchUuid, 'br2');
    expect(find.byKey(const ValueKey('copy-chain-dialog')), findsNothing);
  });

  testWidgets('完成：「点击跳转」返回 jump；单轮范围写成「第 N 轮」', (tester) async {
    final gate = Completer<BranchCopyResult>();
    final outcome = await _openDialog(tester, (_) => gate.future);
    gate.complete(
      _result(generationCount: 1, firstRoundIndex: 3, lastRoundIndex: 3),
    );
    await tester.pumpAndSettle();

    expect(find.text('共拷贝 1 代（第 3 轮）。'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('copy-chain-jump')));
    await tester.pumpAndSettle();
    expect(outcome()?.choice, CopyChainChoice.jump);
    expect(outcome()?.result.branchName, '分支 2');
  });

  testWidgets('失败：显示去掉「Bad state:」的错误文本，关闭返回 null', (tester) async {
    final outcome = await _openDialog(tester, (_) async {
      throw StateError('磁盘写满了');
    });
    await tester.pumpAndSettle();

    expect(find.text('拷贝失败'), findsOneWidget);
    expect(find.text('磁盘写满了'), findsOneWidget);
    expect(find.textContaining('Bad state'), findsNothing);
    expect(find.byKey(const ValueKey('copy-chain-jump')), findsNothing);
    expect(find.byKey(const ValueKey('copy-chain-close')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('copy-chain-close')));
    await tester.pumpAndSettle();
    expect(outcome(), isNull);
  });

  testWidgets('进度回调刷新文案与进度条', (tester) async {
    final gate = Completer<BranchCopyResult>();
    late void Function(int done, int total) report;
    await _openDialog(tester, (onProgress) {
      report = onProgress!;
      onProgress(0, 6);
      return gate.future;
    });
    expect(find.text('已拷贝 0 / 6 代'), findsOneWidget);

    report(3, 6);
    await tester.pump();
    expect(find.text('已拷贝 3 / 6 代'), findsOneWidget);
    final bar = tester.widget<LinearProgressIndicator>(
      find.byKey(const ValueKey('copy-chain-progress')),
    );
    expect(bar.value, closeTo(0.5, 1e-9));

    gate.complete(_result());
    await tester.pumpAndSettle();
  });
}
