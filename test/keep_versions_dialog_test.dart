import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/widgets/keep_versions_dialog.dart';

import 'helpers/fakes.dart';

/// 「保留历史版本」弹窗测试（StubCloudSyncProvider 切断真实 WebDAV）：
/// - 打开即 GET 云端真值并预填；
/// - 校验错误（空 / 越界）内联红字且不打网络；
/// - 保存失败弹窗保持打开、原样展示错误文本；
/// - 保存成功弹窗关闭并返回份数。
void main() {
  /// 打开弹窗；[capture] 接收保存成功的返回值。
  Future<void> pumpHost(
    WidgetTester tester,
    StubCloudSyncProvider provider,
    void Function(int?) capture,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              capture(
                await showKeepVersionsDialog(context, provider: provider),
              );
            },
            child: const Text('打开'),
          ),
        ),
      ),
    );
  }

  Future<void> tapOpen(WidgetTester tester) async {
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  testWidgets('打开即 GET 云端真值并预填输入框', (tester) async {
    final provider = StubCloudSyncProvider()..cloudKeepVersions = 12;
    await pumpHost(tester, provider, (_) {});
    await tapOpen(tester);

    expect(provider.refreshCalls, 1, reason: '打开即强制 GET 一次');
    expect(find.widgetWithText(TextField, '12'), findsOneWidget);
  });

  testWidgets('打开时 GET 失败：弹窗仍可用，预填缓存值并展示原生错误', (tester) async {
    final provider = StubCloudSyncProvider(
      refreshError: 'WebDavException: 下载失败 (500) server error',
    );
    await pumpHost(tester, provider, (_) {});
    await tapOpen(tester);

    expect(provider.refreshCalls, 1);
    expect(find.widgetWithText(TextField, '5'), findsOneWidget,
        reason: '读取失败时用缓存默认值预填');
    expect(
      find.textContaining('下载失败 (500)', findRichText: true),
      findsOneWidget,
      reason: '原生异常文本原样内联展示',
    );
  });

  testWidgets('校验错误（空 / 0 / 100）→ 内联红字且不调用保存', (tester) async {
    final provider = StubCloudSyncProvider()..cloudKeepVersions = 5;
    await pumpHost(tester, provider, (_) {});
    await tapOpen(tester);

    final field = find.byType(TextField);
    await tester.enterText(field, '');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('请输入整数'), findsOneWidget);
    expect(provider.saveCalls, 0);

    await tester.enterText(field, '0');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('需为 1 ~ 99 的整数'), findsOneWidget);
    expect(provider.saveCalls, 0);

    await tester.enterText(field, '100');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('需为 1 ~ 99 的整数'), findsOneWidget);
    expect(provider.saveCalls, 0);
  });

  testWidgets('校验通过后才发送保存请求；成功返回份数并关窗', (tester) async {
    final provider = StubCloudSyncProvider()..cloudKeepVersions = 5;
    int? value;
    await pumpHost(tester, provider, (v) => value = v);
    await tapOpen(tester);

    await tester.enterText(find.byType(TextField), '3');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(provider.saveCalls, 1);
    expect(provider.lastSavedValue, 3);
    expect(value, 3, reason: '弹窗返回保存成功的份数');
    expect(find.byType(AlertDialog), findsNothing, reason: '成功后关窗');
  });

  testWidgets('保存失败：弹窗保持打开，原样展示错误文本，可再次保存', (tester) async {
    final provider = StubCloudSyncProvider(
      saveError: 'WebDavException: 上传失败 (403) 服务器拒绝',
    );
    int? value;
    await pumpHost(tester, provider, (v) => value = v);
    await tapOpen(tester);

    await tester.enterText(find.byType(TextField), '3');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(provider.saveCalls, 1);
    expect(find.byType(AlertDialog), findsOneWidget, reason: '失败不关窗');
    expect(
      find.textContaining('上传失败 (403)', findRichText: true),
      findsOneWidget,
      reason: '原生异常原样输出',
    );
    expect(value, isNull, reason: '未保存成功不返回');

    // 再次保存（这次成功）→ 关窗并返回值。
    provider.saveError = null;
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(provider.saveCalls, 2);
    expect(find.byType(AlertDialog), findsNothing);
    expect(value, 3);
  });
}
