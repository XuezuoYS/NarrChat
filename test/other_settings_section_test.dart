import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/update_check_flow.dart';
import 'package:narrchat/services/update_check_service.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/other_settings_section.dart';

import 'helpers/fakes.dart';
import 'helpers/notice_harness.dart';

const GitHubRelease _release = GitHubRelease(
  tagVersion: 'v1.4.0',
  displayName: 'NarrChat 1.4.0',
  pageUrl: 'https://github.com/XuezuoYS/NarrChat/releases/tag/v1.4.0',
  notes: '## 更新内容\n- 新功能',
  publishedAt: '2026-01-01T00:00:00Z',
);

/// 可挂起的手动检查替身：用于断言「检查中」状态与防重复点击。
class _ControlledUpdateCheckService extends FakeUpdateCheckService {
  final completer = Completer<UpdateCheckResult>();

  @override
  Future<UpdateCheckResult> check({
    required String currentVersion,
    bool forceShow = false,
  }) {
    calls++;
    checkedVersions.add(currentVersion);
    return completer.future;
  }
}

/// 单独挂「其它设置」卡片（不经过整页设置，避免字体扫描等无关初始化）。
Future<void> _pumpSection(
  WidgetTester tester, {
  UpdateCheckService? service,
  String currentVersion = '1.3.1',
  Future<void> Function(Map<String, dynamic> patch)? writeConfig,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: NarrChatTheme.light,
      builder: floatingNoticeBuilder(),
      home: Scaffold(
        body: SingleChildScrollView(
          child: OtherSettingsSection(
            updateService: service,
            currentVersion: currentVersion,
            writeConfig: writeConfig,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  final checkRow = find.byKey(const ValueKey('other_update_check_now'));

  testWidgets('发现新版本：用当前版本号检查并弹出「发现新版本」对话框', (tester) async {
    final service = FakeUpdateCheckService([UpdateAvailable(_release)]);
    await _pumpSection(tester, service: service);

    await tester.tap(checkRow);
    await tester.pumpAndSettle();

    expect(service.calls, 1);
    expect(service.checkedVersions, ['1.3.1']);
    expect(find.text('发现新版本'), findsOneWidget);
    expect(find.textContaining('v1.4.0 已发布'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('update_dialog_later')));
    await tester.pumpAndSettle();
  });

  testWidgets('手动检查发现新版本：选「跳过此版本」会落盘', (tester) async {
    final writes = <Map<String, dynamic>>[];
    final service = FakeUpdateCheckService([UpdateAvailable(_release)]);
    await _pumpSection(
      tester,
      service: service,
      writeConfig: (patch) async => writes.add(patch),
    );

    await tester.tap(checkRow);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('update_dialog_skip')));
    await tester.pumpAndSettle();

    expect(writes, [
      {UpdateCheckFlow.keyUpdateSkipVersion: 'v1.4.0'},
    ]);
  });

  testWidgets('已是最新：提示当前已是最新版本', (tester) async {
    final service = FakeUpdateCheckService([const UpToDate()]);
    await _pumpSection(tester, service: service);

    await tester.tap(checkRow);
    await tester.pumpAndSettle();

    expect(find.text('当前已是最新版本（1.3.1）'), findsOneWidget);
    await flushNotices(tester);
  });

  testWidgets('仓库暂无发布：提示暂无发布版本', (tester) async {
    final service = FakeUpdateCheckService([const NoRelease()]);
    await _pumpSection(tester, service: service);

    await tester.tap(checkRow);
    await tester.pumpAndSettle();

    expect(find.text('GitHub 仓库暂无发布版本'), findsOneWidget);
    await flushNotices(tester);
  });

  testWidgets('检查失败：提示失败原因', (tester) async {
    final service = FakeUpdateCheckService([const CheckFailed('网络请求超时')]);
    await _pumpSection(tester, service: service);

    await tester.tap(checkRow);
    await tester.pumpAndSettle();

    expect(find.text('检查更新失败：网络请求超时'), findsOneWidget);
    await flushNotices(tester);
  });

  testWidgets('检查中：行尾转圈、忽略重复点击，完成后恢复', (tester) async {
    final service = _ControlledUpdateCheckService();
    await _pumpSection(tester, service: service);

    await tester.tap(checkRow);
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('正在检查是否有新版本…'), findsOneWidget);

    // 进行中再次点击不会发起第二次请求。
    await tester.tap(checkRow);
    await tester.pump();
    expect(service.calls, 1);

    service.completer.complete(const UpToDate());
    await tester.pumpAndSettle();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('点击检查 GitHub 上是否有新版本发布'), findsOneWidget);
    expect(find.text('当前已是最新版本（1.3.1）'), findsOneWidget);
    await flushNotices(tester);
  });
}
