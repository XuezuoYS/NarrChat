import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/update_check_service.dart';
import 'package:narrchat/widgets/update_available_dialog.dart';

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
}

Future<_DialogHarness> _pumpOpenDialog(WidgetTester tester) async {
  final harness = _DialogHarness();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () {
                harness.future = showUpdateAvailableDialog(
                  context,
                  release: _release,
                  currentVersion: '1.3.1',
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
    expect(
      find.byWidgetPredicate(
        (w) => w is SelectableText && w.data == _release.pageUrl,
      ),
      findsOneWidget,
    );
    expect(find.text('复制链接'), findsOneWidget);
    expect(find.text('跳过此版本'), findsOneWidget);
    expect(find.text('以后再说'), findsOneWidget);
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
    final copied = log.where((c) => c.method == 'Clipboard.setData').toList();
    expect(copied, hasLength(1));
    expect(
      (copied.single.arguments as Map<Object?, Object?>)['text'],
      _release.pageUrl,
    );
    expect(find.text('下载链接已复制，请在浏览器中打开'), findsOneWidget);
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
