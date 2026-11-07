import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/update_check_service.dart';
import 'package:narrchat/widgets/markdown_preview.dart';
import 'package:narrchat/widgets/update_available_dialog.dart';

import 'helpers/notice_harness.dart';

const GitHubRelease _release = GitHubRelease(
  tagVersion: 'v1.4.0',
  displayName: 'NarrChat 1.4.0',
  pageUrl: 'https://github.com/XuezuoYS/NarrChat/releases/tag/v1.4.0',
  notes: '## 更新内容\n- 新功能',
  publishedAt: '2026-01-01T00:00:00Z',
);

/// 打开按钮脚手架：弹出对话框并把 future 交回给用例断言。
class _DialogHarness {
  Future<UpdateDialogChoice?>? future;
  final List<Uri> openedUrls = [];
}

Future<_DialogHarness> _pumpOpenDialog(
  WidgetTester tester, {
  Future<bool> Function(Uri url)? openLink,
}) async {
  final harness = _DialogHarness();
  await tester.pumpWidget(
    MaterialApp(
      builder: floatingNoticeBuilder(),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () {
                harness.future = showUpdateAvailableDialog(
                  context,
                  release: _release,
                  currentVersion: '1.3.1',
                  openLink: (url) async {
                    harness.openedUrls.add(url);
                    return openLink == null ? true : await openLink(url);
                  },
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
  await tester.pumpAndSettle();
  return harness;
}

void main() {
  testWidgets('展示版本对比、发布说明与可选中链接', (tester) async {
    await _pumpOpenDialog(tester);

    expect(find.text('发现新版本'), findsOneWidget);
    expect(find.textContaining('v1.4.0 已发布'), findsOneWidget);
    expect(find.textContaining('当前版本 1.3.1'), findsOneWidget);
    expect(find.textContaining('下载地址'), findsOneWidget);
    expect(find.textContaining('更新内容'), findsOneWidget);
    // 下载地址以可选中文本呈现（统一选中容器：选中即弹「复制 / 全选」）。
    expect(
      find.descendant(
        of: find.byType(SelectableTextArea),
        matching: find.text(_release.pageUrl),
      ),
      findsOneWidget,
    );
    expect(find.text('复制链接'), findsOneWidget);
    expect(find.text('跳过此版本'), findsOneWidget);
    expect(find.text('以后再说'), findsOneWidget);
    expect(find.text('在浏览器打开'), findsOneWidget);

    // 主按钮 = 在浏览器打开（FilledButton）；其余为辅助按钮（TextButton）。
    final openButton = find.byKey(
      const ValueKey('update_dialog_open_browser'),
    );
    expect(tester.widget(openButton), isA<FilledButton>());
    expect(
      find.descendant(of: openButton, matching: find.text('在浏览器打开')),
      findsOneWidget,
    );
    final copyButton = find.byKey(const ValueKey('update_dialog_copy'));
    expect(tester.widget(copyButton), isA<TextButton>());
    expect(find.descendant(of: copyButton, matching: find.text('复制链接')),
        findsOneWidget);
    expect(
      tester.widget(find.byKey(const ValueKey('update_dialog_skip'))),
      isA<TextButton>(),
    );
    expect(
      tester.widget(find.byKey(const ValueKey('update_dialog_later'))),
      isA<TextButton>(),
    );

    // 宽屏：主操作与辅操作同一行，且主操作在最右。
    final copyTopLeft =
        tester.getTopLeft(find.byKey(const ValueKey('update_dialog_copy')));
    final openTopLeft = tester.getTopLeft(openButton);
    expect(openTopLeft.dy, closeTo(copyTopLeft.dy, 0.5));
    expect(openTopLeft.dx, greaterThan(copyTopLeft.dx));
  });

  testWidgets('窄屏：四个动作按钮都在，主操作换到下一行', (tester) async {
    tester.view.physicalSize = const Size(420, 820);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pumpOpenDialog(tester);

    // 换行布局不应产生溢出异常（此前 OverflowBar 会把四个按钮叠成四层）。
    expect(tester.takeException(), isNull);
    final openButton = find.byKey(
      const ValueKey('update_dialog_open_browser'),
    );
    for (final key in const [
      'update_dialog_later',
      'update_dialog_skip',
      'update_dialog_copy',
      'update_dialog_open_browser',
    ]) {
      expect(find.byKey(ValueKey(key)), findsOneWidget);
    }
    // 主操作独占下一行（右对齐），辅操作在上方一排。
    expect(
      tester.getTopLeft(openButton).dy,
      greaterThan(
        tester.getTopLeft(find.byKey(const ValueKey('update_dialog_copy'))).dy,
      ),
    );
  });

  testWidgets('在浏览器打开：用系统浏览器打开 Release 页面并返回 openInBrowser',
      (tester) async {
    final harness = await _pumpOpenDialog(tester);

    await tester.tap(find.byKey(const ValueKey('update_dialog_open_browser')));
    await tester.pumpAndSettle();

    expect(find.text('发现新版本'), findsNothing);
    expect(await harness.future, UpdateDialogChoice.openInBrowser);
    expect(harness.openedUrls, [Uri.parse(_release.pageUrl)]);
  });

  testWidgets('在浏览器打开失败：复制链接并提示', (tester) async {
    final log = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        log.add(call);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    final harness = await _pumpOpenDialog(
      tester,
      openLink: (_) async => false,
    );

    await tester.tap(find.byKey(const ValueKey('update_dialog_open_browser')));
    await tester.pumpAndSettle();
    await settleNoticeEnter(tester);

    expect(await harness.future, UpdateDialogChoice.openInBrowser);
    final copied = log.where((c) => c.method == 'Clipboard.setData').toList();
    expect(copied, hasLength(1));
    expect(
      (copied.single.arguments as Map<Object?, Object?>)['text'],
      _release.pageUrl,
    );
    expect(find.text('无法打开浏览器，下载链接已复制'), findsOneWidget);
    await flushNotices(tester);
  });

  testWidgets('复制链接：写入剪贴板、关闭对话框并提示', (tester) async {
    final log = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        log.add(call);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    final harness = await _pumpOpenDialog(tester);
    await tester.tap(find.byKey(const ValueKey('update_dialog_copy')));
    await tester.pumpAndSettle();

    expect(find.text('发现新版本'), findsNothing);
    expect(await harness.future, UpdateDialogChoice.copyLink);
    expect(harness.openedUrls, isEmpty);
    final copied = log.where((c) => c.method == 'Clipboard.setData').toList();
    expect(copied, hasLength(1));
    expect(
      (copied.single.arguments as Map<Object?, Object?>)['text'],
      _release.pageUrl,
    );
    expect(find.text('下载链接已复制，请在浏览器中打开'), findsOneWidget);
    await flushNotices(tester);
  });

  testWidgets('跳过此版本：返回 skipVersion', (tester) async {
    final harness = await _pumpOpenDialog(tester);

    await tester.tap(find.byKey(const ValueKey('update_dialog_skip')));
    await tester.pumpAndSettle();

    expect(find.text('发现新版本'), findsNothing);
    expect(await harness.future, UpdateDialogChoice.skipVersion);
  });

  testWidgets('以后再说：返回 later', (tester) async {
    final harness = await _pumpOpenDialog(tester);

    await tester.tap(find.byKey(const ValueKey('update_dialog_later')));
    await tester.pumpAndSettle();

    expect(await harness.future, UpdateDialogChoice.later);
  });

  testWidgets('点遮罩关闭：返回 null（等同以后再说）', (tester) async {
    final harness = await _pumpOpenDialog(tester);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(await harness.future, isNull);
  });
}
