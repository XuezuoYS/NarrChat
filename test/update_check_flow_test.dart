import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/update_check_flow.dart';
import 'package:narrchat/services/update_check_service.dart';
import 'package:narrchat/widgets/update_available_dialog.dart';

import 'helpers/fakes.dart';

const GitHubRelease _release = GitHubRelease(
  tagVersion: 'v1.4.0',
  displayName: 'NarrChat 1.4.0',
  pageUrl: 'https://github.com/XuezuoYS/NarrChat/releases/tag/v1.4.0',
  notes: '## 更新内容\n- 新功能',
  publishedAt: '2026-01-01T00:00:00Z',
);

void main() {
  late Map<String, dynamic> config;
  late DateTime currentTime;
  late FakeUpdateCheckService service;
  late FakeNotificationBackend backend;
  late List<String> promptedVersions;
  late List<UpdateDialogChoice> choices;
  late GlobalKey<NavigatorState> navigatorKey;

  /// 注入全部替身的流程实例；每次调用复制当前 config（模拟文件快照）。
  UpdateCheckFlow buildFlow() => UpdateCheckFlow(
        service: service,
        backend: backend,
        currentVersion: '1.3.1',
        now: () => currentTime,
        readConfig: () async => Map.of(config),
        writeConfig: (patch) async => config.addAll(patch),
        prompt: (context, release, currentVersion) async {
          promptedVersions.add(currentVersion);
          return choices.removeAt(0);
        },
      );

  setUp(() {
    config = <String, dynamic>{};
    currentTime = DateTime(2026, 1, 1, 10);
    service = FakeUpdateCheckService([const NoRelease()]);
    backend = FakeNotificationBackend();
    promptedVersions = [];
    choices = [];
    navigatorKey = GlobalKey<NavigatorState>();
  });

  group('runAtStartup', () {
    test('开关关闭：零请求、零通知、零弹窗', () async {
      config[UpdateCheckFlow.keyUpdateCheckEnabled] = false;
      await buildFlow().runAtStartup(navigatorKey);

      expect(service.calls, 0);
      expect(backend.shown, isEmpty);
      expect(promptedVersions, isEmpty);
      // 未写任何时间戳 / 跳过版本。
      expect(config, {UpdateCheckFlow.keyUpdateCheckEnabled: false});
    });

    test('24 小时内重复启动：不发起检查', () async {
      config[UpdateCheckFlow.keyUpdateLastCheckAt] =
          currentTime.subtract(const Duration(hours: 23)).toIso8601String();
      await buildFlow().runAtStartup(navigatorKey);

      expect(service.calls, 0);
      expect(backend.shown, isEmpty);
      expect(promptedVersions, isEmpty);
    });

    test('距上次超过 24 小时：发起检查', () async {
      config[UpdateCheckFlow.keyUpdateLastCheckAt] =
          currentTime.subtract(const Duration(hours: 25)).toIso8601String();
      await buildFlow().runAtStartup(navigatorKey);

      expect(service.calls, 1);
      expect(service.checkedVersions, ['1.3.1']);
    });

    test('检查失败：发一条失败通知，且时间戳落盘（失败计入每天一次）', () async {
      service = FakeUpdateCheckService([const CheckFailed('网络请求失败：boom')]);
      await buildFlow().runAtStartup(navigatorKey);

      expect(backend.shown, hasLength(1));
      expect(backend.shown.single.title, '检查更新失败');
      expect(backend.shown.single.body, 'GitHub 源检查更新失败：网络请求失败：boom');
      expect(backend.shown.single.payload, '');
      expect(config[UpdateCheckFlow.keyUpdateLastCheckAt],
          currentTime.toIso8601String());
      expect(promptedVersions, isEmpty);
    });

    test('已是最新 / 仓库无发布：完全静默', () async {
      service = FakeUpdateCheckService([const UpToDate()]);
      await buildFlow().runAtStartup(navigatorKey);
      expect(backend.shown, isEmpty);
      expect(promptedVersions, isEmpty);

      service = FakeUpdateCheckService([const NoRelease()]);
      await buildFlow().runAtStartup(navigatorKey);
      expect(backend.shown, isEmpty);
      expect(promptedVersions, isEmpty);
    });

    test('navigator 无 context：检查执行但不弹窗、不抛异常', () async {
      service = FakeUpdateCheckService([UpdateAvailable(_release)]);
      expect(navigatorKey.currentContext, isNull);

      await buildFlow().runAtStartup(navigatorKey);

      expect(service.calls, 1);
      expect(promptedVersions, isEmpty);
      expect(backend.shown, isEmpty);
    });
  });

  group('runAtStartup（带 Navigator）', () {
    Future<void> pumpNavigator(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(navigatorKey: navigatorKey, home: const Scaffold()),
      );
    }

    testWidgets('发现新版本：弹窗一次；跳过此版本落盘，隔日同版本不再弹窗',
        (tester) async {
      await pumpNavigator(tester);
      service = FakeUpdateCheckService([
        UpdateAvailable(_release),
        UpdateAvailable(_release),
      ]);
      choices = [UpdateDialogChoice.skipVersion];
      final flow = buildFlow();

      await flow.runAtStartup(navigatorKey);
      expect(promptedVersions, ['1.3.1']);
      expect(config[UpdateCheckFlow.keyUpdateSkipVersion], 'v1.4.0');
      expect(config[UpdateCheckFlow.keyUpdateLastCheckAt],
          currentTime.toIso8601String());

      // 隔日（超过 24 小时）再次启动：同版本已被跳过，不再弹窗。
      currentTime = currentTime.add(const Duration(hours: 26));
      await flow.runAtStartup(navigatorKey);
      expect(service.calls, 2);
      expect(promptedVersions, hasLength(1));
    });

    testWidgets('选择「以后再说」：仅记录检查时间，不写跳过版本', (tester) async {
      await pumpNavigator(tester);
      service = FakeUpdateCheckService([UpdateAvailable(_release)]);
      choices = [UpdateDialogChoice.later];

      await buildFlow().runAtStartup(navigatorKey);

      expect(promptedVersions, ['1.3.1']);
      expect(config.containsKey(UpdateCheckFlow.keyUpdateSkipVersion), isFalse);
      expect(config[UpdateCheckFlow.keyUpdateLastCheckAt],
          currentTime.toIso8601String());
    });
  });
}
