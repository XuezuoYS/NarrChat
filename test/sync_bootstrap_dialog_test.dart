import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/sync/sync_bootstrapper.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/sync_bootstrap_dialog.dart';

void main() {
  Future<SyncBootstrapDecision? Function()> openDialog(
    WidgetTester tester, {
    SyncBootstrapSummary summary = const SyncBootstrapSummary(
      localBooks: 3,
      localMods: 2,
      cloudBooks: 5,
      cloudMods: 1,
    ),
    Size size = const Size(1400, 900),
  }) async {
    SyncBootstrapDecision? captured;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: NarrChatTheme.light,
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: TextButton(
                onPressed: () async {
                  captured = await showSyncBootstrapDialog(ctx, summary: summary);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    return () => captured;
  }

  Future<void> openAndSettle(WidgetTester tester) async {
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('默认选中合并；确定返回 mergeBoth', (tester) async {
    final getResult = await openDialog(tester);
    await openAndSettle(tester);

    expect(find.text('首次连接云同步'), findsOneWidget);
    expect(find.text('本地与云端都检测到数据，请选择如何处理。'), findsOneWidget);
    expect(find.text('3 本 · 2 个 Mod'), findsOneWidget);
    expect(find.text('5 本 · 1 个 Mod'), findsOneWidget);

    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(getResult(), SyncBootstrapDecision.mergeBoth);
  });

  testWidgets('选覆盖类需二次确认，确认后返回对应决策', (tester) async {
    final getResult = await openDialog(tester);
    await openAndSettle(tester);

    await tester.tap(find.text('用云端覆盖本地'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    // 二次确认对话框。
    expect(find.text('用云端覆盖本地'), findsWidgets);
    await tester.tap(find.text('继续'));
    await tester.pumpAndSettle();
    expect(getResult(), SyncBootstrapDecision.pullCloud);
  });

  testWidgets('覆盖类二次确认可取消，回到对话框', (tester) async {
    final getResult = await openDialog(tester);
    await openAndSettle(tester);

    await tester.tap(find.text('用本地覆盖云端'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    // 二次确认对话框的「取消」（最上层那个）。
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();

    expect(getResult(), isNull);
    expect(find.text('首次连接云同步'), findsOneWidget);
  });

  testWidgets('窄屏不溢出', (tester) async {
    await openDialog(tester, size: const Size(320, 640));
    await openAndSettle(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('首次连接云同步'), findsOneWidget);
  });
}
