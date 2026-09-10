import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/agent_mode_level.dart';
import 'package:narrchat/providers/experimental_settings_provider.dart';
import 'package:narrchat/services/local_config_service.dart';

/// 实验性功能设置（Agent 模式档位）Provider：默认关闭、三档持久化、
/// 旧布尔键迁移与非法值回退。
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

  group('AgentModeLevel', () {
    test('id 稳定（0/1/2）与徽标文本', () {
      expect(AgentModeLevel.off.id, 0);
      expect(AgentModeLevel.lv1.id, 1);
      expect(AgentModeLevel.lv2.id, 2);
      expect(AgentModeLevel.off.badge, isEmpty);
      expect(AgentModeLevel.lv1.badge, 'Agent Lv.1 On (BETA)');
      expect(AgentModeLevel.lv2.badge, 'Agent Lv.2 On (BETA)');
      expect(AgentModeLevel.off.isOn, isFalse);
      expect(AgentModeLevel.lv1.isOn, isTrue);
      expect(AgentModeLevel.lv2.isOn, isTrue);
    });

    test('parse：合法值还原档位，非法 / 非 int 一律回退关闭', () {
      expect(AgentModeLevel.parse(0), AgentModeLevel.off);
      expect(AgentModeLevel.parse(1), AgentModeLevel.lv1);
      expect(AgentModeLevel.parse(2), AgentModeLevel.lv2);
      expect(AgentModeLevel.parse(99), AgentModeLevel.off);
      expect(AgentModeLevel.parse('1'), AgentModeLevel.off);
      expect(AgentModeLevel.parse(null), AgentModeLevel.off);
    });
  });

  test('默认关闭（无配置 / 读取失败按默认值）', () async {
    final provider = ExperimentalSettingsProvider();
    expect(provider.agentModeLevel, AgentModeLevel.off);
    expect(provider.agentModeEnabled, isFalse);

    await provider.load();
    expect(provider.agentModeLevel, AgentModeLevel.off);
  });

  test('新键存在时按其值加载（Lv.1 / Lv.2，非法值回退关闭）', () async {
    await LocalConfigService.update({
      ExperimentalSettingsProvider.keyAgentModeLevel: 1,
    });
    final lv1 = ExperimentalSettingsProvider();
    await lv1.load();
    expect(lv1.agentModeLevel, AgentModeLevel.lv1);

    await LocalConfigService.update({
      ExperimentalSettingsProvider.keyAgentModeLevel: 2,
    });
    final lv2 = ExperimentalSettingsProvider();
    await lv2.load();
    expect(lv2.agentModeLevel, AgentModeLevel.lv2);

    await LocalConfigService.update({
      ExperimentalSettingsProvider.keyAgentModeLevel: 7,
    });
    final bad = ExperimentalSettingsProvider();
    await bad.load();
    expect(bad.agentModeLevel, AgentModeLevel.off);
  });

  test('旧键迁移：agentModeEnabled=true → Lv.2（新键缺失时）', () async {
    await LocalConfigService.update({
      ExperimentalSettingsProvider.keyAgentModeEnabled: true,
    });
    final provider = ExperimentalSettingsProvider();
    await provider.load();
    expect(provider.agentModeLevel, AgentModeLevel.lv2);
    expect(provider.agentModeEnabled, isTrue);
    // 迁移只读不写盘：新键不出现在配置里（用户未切换过档位）。
    final config = await LocalConfigService.read();
    expect(config.containsKey(ExperimentalSettingsProvider.keyAgentModeLevel),
        isFalse);
  });

  test('新键存在（含显式关闭 0）时忽略旧键', () async {
    await LocalConfigService.update({
      ExperimentalSettingsProvider.keyAgentModeEnabled: true,
      ExperimentalSettingsProvider.keyAgentModeLevel: 0,
    });
    final provider = ExperimentalSettingsProvider();
    await provider.load();
    expect(provider.agentModeLevel, AgentModeLevel.off);
  });

  test('旧键为 false / 非布尔时加载为关闭', () async {
    await LocalConfigService.update({
      ExperimentalSettingsProvider.keyAgentModeEnabled: false,
    });
    final provider = ExperimentalSettingsProvider();
    await provider.load();
    expect(provider.agentModeLevel, AgentModeLevel.off);

    await LocalConfigService.write({
      ExperimentalSettingsProvider.keyAgentModeEnabled: 'yes',
    });
    final weird = ExperimentalSettingsProvider();
    await weird.load();
    expect(weird.agentModeLevel, AgentModeLevel.off);
  });

  test('setAgentModeLevel 乐观生效并持久化（可切回）', () async {
    final provider = ExperimentalSettingsProvider();
    var notified = 0;
    provider.addListener(() => notified++);

    expect(await provider.setAgentModeLevel(AgentModeLevel.lv1), isTrue);
    expect(provider.agentModeLevel, AgentModeLevel.lv1);
    expect(notified, 1);

    // 持久化后重新加载（模拟重启）仍为 Lv.1。
    final reloaded = ExperimentalSettingsProvider();
    await reloaded.load();
    expect(reloaded.agentModeLevel, AgentModeLevel.lv1);
    final config = await LocalConfigService.read();
    expect(config[ExperimentalSettingsProvider.keyAgentModeLevel], 1);

    // 升档到 Lv.2 再关回：新键始终为准。
    expect(await provider.setAgentModeLevel(AgentModeLevel.lv2), isTrue);
    final config2 = await LocalConfigService.read();
    expect(config2[ExperimentalSettingsProvider.keyAgentModeLevel], 2);

    expect(await provider.setAgentModeLevel(AgentModeLevel.off), isTrue);
    expect(provider.agentModeLevel, AgentModeLevel.off);
    expect(provider.agentModeEnabled, isFalse);
    final config3 = await LocalConfigService.read();
    expect(config3[ExperimentalSettingsProvider.keyAgentModeLevel], 0);
  });
}
