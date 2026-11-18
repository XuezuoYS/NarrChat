import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/providers/cloud_sync_provider.dart';
import 'package:narrchat/services/sync/sync_conflict.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/markdown_preview.dart';
import 'package:narrchat/widgets/sync_conflict_preview.dart';

import 'helpers/sync_conflict_fixtures.dart';

/// 冲突预览对话框：展开长字段、统一选区、限高滚动、Mod 全名单与紧凑省略号。
void main() {
  Future<_PreviewProvider> pumpPreview(
    WidgetTester tester, {
    SyncConflict? conflict,
    _PreviewProvider? provider,
    double width = 360,
  }) async {
    final fake = provider ?? _PreviewProvider((side) => buildPreview(side));
    tester.view.physicalSize = Size(width, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: NarrChatTheme.light,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showSyncConflictPreview(
                  context,
                  conflict ?? buildBookConflict(),
                  fake,
                ),
                child: const Text('打开预览'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开预览'));
    await tester.pumpAndSettle();
    return fake;
  }

  /// 从 ListView 左侧留白处拖动，避开长字段内部的滚动区，专门滚动外层预览。
  Future<void> scrollPreview(WidgetTester tester, double dy) async {
    final list = find.byType(ListView);
    final rect = tester.getRect(list);
    await tester.dragFrom(rect.topLeft + const Offset(6, 120), Offset(0, dy));
    await tester.pumpAndSettle();
  }

  Future<void> expandField(WidgetTester tester, String title) async {
    final finder = find.text(title);
    // ListView 只构建视口附近的子项；先滚到字段标题被构建出来。
    for (var i = 0; i < 12 && finder.evaluate().isEmpty; i++) {
      await scrollPreview(tester, -320);
    }
    expect(finder, findsOneWidget, reason: '预览里应能找到「$title」');
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('展开长字段：两侧正文可见、无 ErrorWidget、对话框内无 SelectableText', (
    tester,
  ) async {
    final provider = await pumpPreview(tester);

    expect(provider.previewCalls, 2, reason: '本地 + 云端各加载一次');
    expect(find.textContaining('对比预览 · 书籍《测试书》'), findsOneWidget);

    await expandField(tester, '最近一轮 · 用户输入');
    expect(tester.takeException(), isNull);
    expect(find.byType(ErrorWidget), findsNothing);
    expect(find.text('本地用户输入'), findsOneWidget);
    expect(find.text('云端用户输入'), findsOneWidget);

    final dialog = find.byType(Dialog);
    expect(
      find.descendant(of: dialog, matching: find.byType(SelectableText)),
      findsNothing,
      reason: '预览统一走 SelectableTextArea / PlainTextPreview',
    );
    expect(
      find.descendant(of: dialog, matching: find.byType(EditableText)),
      findsNothing,
      reason: '不再引入 SelectableText 的 EditableText 选区实现',
    );

    await scrollPreview(tester, -400);
    expect(find.text('本地用户输入').hitTestable(), findsOneWidget);
    await scrollPreview(tester, -320);
    expect(find.text('云端用户输入').hitTestable(), findsOneWidget);
  });

  testWidgets('超长正文：每侧限高且各自可滚，外层仍能到另一侧', (tester) async {
    final longLocal = '本地长文' * 500;
    final longRemote = '云端长文' * 500;
    final provider = _PreviewProvider(
      (side) => buildPreview(
        side,
        localUserInput: longLocal,
        remoteUserInput: longRemote,
      ),
    );
    await pumpPreview(tester, provider: provider);

    await expandField(tester, '最近一轮 · 用户输入');
    expect(tester.takeException(), isNull);
    expect(find.byType(ErrorWidget), findsNothing);
    expect(find.text(longLocal), findsOneWidget);
    expect(find.text(longRemote), findsOneWidget);

    final scrolls = find.byType(SingleChildScrollView);
    expect(scrolls, findsNWidgets(2), reason: '本地/云端各一块独立阅读区');
    expect(tester.getSize(scrolls.first).height, lessThanOrEqualTo(260));
    expect(tester.getSize(scrolls.last).height, lessThanOrEqualTo(260));
    expect(
      tester.getRect(find.text(longLocal)).height,
      greaterThan(260),
      reason: '内容确实比阅读区高，说明发生了内部滚动',
    );

    await tester.ensureVisible(find.text('云端').last);
    await tester.pumpAndSettle();
    expect(find.text('云端').last.hitTestable(), findsOneWidget);
  });

  testWidgets('Markdown 长字段同样限高且不抛 PageStorage 类型错误', (tester) async {
    final provider = _PreviewProvider(
      (side) => buildPreview(
        side,
        localNarrative: '# 本地标题\n\n${'本地正文' * 400}',
        remoteNarrative: '# 云端标题\n\n${'云端正文' * 400}',
      ),
    );
    await pumpPreview(tester, provider: provider);

    await expandField(tester, '最近一轮 · 正文摘要');
    expect(tester.takeException(), isNull);
    expect(find.byType(ErrorWidget), findsNothing);
    expect(find.byType(MarkdownPreview), findsNWidgets(2));
    final scrolls = find.byType(SingleChildScrollView);
    expect(scrolls, findsNWidgets(2));
    expect(tester.getSize(scrolls.first).height, lessThanOrEqualTo(260));
  });

  testWidgets('宽屏：本地/云端并排展开正常', (tester) async {
    await pumpPreview(tester, width: 900);

    await expandField(tester, '最近一轮 · 用户输入');
    expect(tester.takeException(), isNull);
    expect(find.byType(ErrorWidget), findsNothing);

    final local = tester.getRect(find.text('本地用户输入'));
    final remote = tester.getRect(find.text('云端用户输入'));
    expect(local.left, lessThan(remote.left), reason: '宽屏应并排');
  });

  testWidgets('启用的 Mod 展开看全，差异不再被两行截断吞掉', (tester) async {
    const localMods = ['默认破甲', '强度更高的', '本地独有'];
    const remoteMods = ['默认破甲', '强度更高的', '云端独有'];
    final provider = _PreviewProvider(
      (side) => buildPreview(
        side,
        localModNames: localMods,
        remoteModNames: remoteMods,
      ),
    );
    await pumpPreview(tester, provider: provider);

    await expandField(tester, '启用的 Mod');
    expect(tester.takeException(), isNull);
    expect(find.byType(ErrorWidget), findsNothing);
    expect(find.text('有差异'), findsWidgets);
    expect(find.text('默认破甲、强度更高的、本地独有'), findsOneWidget);
    expect(find.text('默认破甲、强度更高的、云端独有'), findsOneWidget);
  });

  testWidgets('紧凑行超长值截断时带省略号', (tester) async {
    final longCategory = '非常长的分类名' * 12;
    final provider = _PreviewProvider(
      (side) => buildPreview(
        side,
        localCategory: longCategory,
        remoteCategory: longCategory,
      ),
    );
    await pumpPreview(tester, provider: provider);

    final textWidgets = tester.widgetList<Text>(find.text(longCategory));
    expect(textWidgets, isNotEmpty);
    for (final text in textWidgets) {
      expect(text.maxLines, 2);
      expect(text.overflow, TextOverflow.ellipsis);
    }
  });
}

/// 只覆写预览读取的小 provider 替身。
class _PreviewProvider extends CloudSyncProvider {
  _PreviewProvider(this.previewOf);

  final SyncSidePreview Function(SyncPreviewSide side) previewOf;
  int previewCalls = 0;

  @override
  Future<SyncSidePreview> loadConflictPreview(
    SyncConflict conflict,
    SyncPreviewSide side,
  ) async {
    previewCalls++;
    return previewOf(side);
  }
}
