import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/providers/experimental_settings_provider.dart';
import 'package:narrchat/services/local_config_service.dart';

/// 实验性功能设置（Agent 模式开关）Provider：默认关闭、本地持久化与加载。
void main() {
  late Directory tempRoot;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('narrchat_experimental_');
    LocalConfigService.testRootOverride = tempRoot.path;
    LocalConfigService.resetForTest();
  });

  tearDown(() async {
    LocalConfigService.testRootOverride = null;
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  test('默认关闭（无配置 / 读取失败按默认值）', () async {
    final provider = ExperimentalSettingsProvider();
    expect(provider.agentModeEnabled, isFalse);

    await provider.load();
    expect(provider.agentModeEnabled, isFalse);
  });

  test('预置 agentModeEnabled: true 时加载为开启', () async {
    await LocalConfigService.update({
      ExperimentalSettingsProvider.keyAgentModeEnabled: true,
    });
    final provider = ExperimentalSettingsProvider()..load();
    await provider.load(); // 幂等
    expect(provider.agentModeEnabled, isTrue);
  });

  test('setAgentModeEnabled 乐观生效并持久化（可切回）', () async {
    final provider = ExperimentalSettingsProvider();
    var notified = 0;
    provider.addListener(() => notified++);

    expect(await provider.setAgentModeEnabled(true), isTrue);
    expect(provider.agentModeEnabled, isTrue);
    expect(notified, 1);

    // 持久化后重新加载（模拟重启）仍为开启。
    final reloaded = ExperimentalSettingsProvider()..load();
    await reloaded.load();
    expect(reloaded.agentModeEnabled, isTrue);
    final config = await LocalConfigService.read();
    expect(config[ExperimentalSettingsProvider.keyAgentModeEnabled], isTrue);

    expect(await provider.setAgentModeEnabled(false), isTrue);
    expect(provider.agentModeEnabled, isFalse);
    final config2 = await LocalConfigService.read();
    expect(config2[ExperimentalSettingsProvider.keyAgentModeEnabled], isFalse);
  });
}
