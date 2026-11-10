import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/agent_mode_level.dart';
import 'package:narrchat/providers/experimental_settings_provider.dart';
import 'package:narrchat/services/local_config_service.dart';

/// 实验性功能设置（Agent 模式档位）Provider：默认关闭、两档持久化、
/// 残留旧布尔键被忽略与非法值回退。
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

  /// lib 已删除的旧布尔键（`true` 曾代表已移除的 Lv.2）。用例里用字面量
  /// 模拟旧配置残留：它不再参与迁移，任意取值都应被忽略。
  const String legacyKey = 'agentModeEnabled';

  group('AgentModeLevel', () {
    test('id 稳定（0/1）与徽标文本', () {
      expect(AgentModeLevel.off.id, 0);
      expect(AgentModeLevel.lv1.id, 1);
      expect(AgentModeLevel.off.badge, isEmpty);
      expect(AgentModeLevel.lv1.badge, 'Agent Lv.1 On (BETA)');
      expect(AgentModeLevel.off.isOn, isFalse);
      expect(AgentModeLevel.lv1.isOn, isTrue);
    });

    test('parse：合法值还原档位，已移除的 Lv.2 / 非法 / 非 int 一律回退关闭', () {
      expect(AgentModeLevel.parse(0), AgentModeLevel.off);
      expect(AgentModeLevel.parse(1), AgentModeLevel.lv1);
      expect(
        AgentModeLevel.parse(2),
        AgentModeLevel.off,
        reason: 'Lv.2 已移除：旧值不猜测、不回落到其它档位',
      );
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

  test('新键存在时按其值加载（Lv.1；已移除的 Lv.2 值与非法值回退关闭）', () async {
    await LocalConfigService.update({
      ExperimentalSettingsProvider.keyAgentModeLevel: 1,
    });
    final lv1 = ExperimentalSettingsProvider();
    await lv1.load();
    expect(lv1.agentModeLevel, AgentModeLevel.lv1);

    await LocalConfigService.update({
      ExperimentalSettingsProvider.keyAgentModeLevel: 2,
    });
    final removedLv2 = ExperimentalSettingsProvider();
    await removedLv2.load();
    expect(removedLv2.agentModeLevel, AgentModeLevel.off);

    await LocalConfigService.update({
      ExperimentalSettingsProvider.keyAgentModeLevel: 7,
    });
    final bad = ExperimentalSettingsProvider();
    await bad.load();
    expect(bad.agentModeLevel, AgentModeLevel.off);
  });

  test('残留旧布尔键被忽略：agentModeEnabled=true 且新键缺失 → off，读取不写盘', () async {
    await LocalConfigService.update({legacyKey: true});
    final provider = ExperimentalSettingsProvider();
    await provider.load();
    expect(provider.agentModeLevel, AgentModeLevel.off);
    expect(provider.agentModeEnabled, isFalse);

    // 旧键只被原样保留：load 既不迁移也不物化新键。
    final config = await LocalConfigService.read();
    expect(config[legacyKey], isTrue);
    expect(
      config.containsKey(ExperimentalSettingsProvider.keyAgentModeLevel),
      isFalse,
    );
  });

  test('残留旧布尔键的任意取值都不再被解析为开启', () async {
    for (final legacy in <Object>[false, 'yes']) {
      await LocalConfigService.write({legacyKey: legacy});
      final provider = ExperimentalSettingsProvider();
      await provider.load();
      expect(provider.agentModeLevel, AgentModeLevel.off, reason: '$legacy');
    }
  });

  test('新键存在时以新键为准（残留旧布尔键不参与）', () async {
    await LocalConfigService.update({
      legacyKey: true,
      ExperimentalSettingsProvider.keyAgentModeLevel: 1,
    });
    final lv1 = ExperimentalSettingsProvider();
    await lv1.load();
    expect(lv1.agentModeLevel, AgentModeLevel.lv1);

    await LocalConfigService.write({
      legacyKey: 'yes',
      ExperimentalSettingsProvider.keyAgentModeLevel: 0,
    });
    final off = ExperimentalSettingsProvider();
    await off.load();
    expect(off.agentModeLevel, AgentModeLevel.off);
  });

  test('精简思考回传：默认关、可持久化开启并回读', () async {
    final provider = ExperimentalSettingsProvider();
    expect(provider.reduceReasoningReplay, isFalse, reason: '默认不精简');

    // 配置缺失时 load 仍为默认关（读取不写盘）。
    await provider.load();
    expect(provider.reduceReasoningReplay, isFalse);

    var notified = 0;
    provider.addListener(() => notified++);
    expect(await provider.setReduceReasoningReplay(true), isTrue);
    expect(provider.reduceReasoningReplay, isTrue);
    expect(notified, 1);

    final reloaded = ExperimentalSettingsProvider();
    await reloaded.load();
    expect(reloaded.reduceReasoningReplay, isTrue);
    final config = await LocalConfigService.read();
    expect(
      config[ExperimentalSettingsProvider.keyReduceReasoningReplay],
      isTrue,
    );

    // 非布尔值 / 缺失 ⇒ 回退默认关。
    await LocalConfigService.write({
      ExperimentalSettingsProvider.keyReduceReasoningReplay: 'yes',
    });
    final weird = ExperimentalSettingsProvider();
    await weird.load();
    expect(weird.reduceReasoningReplay, isFalse);
  });

  test('setAgentModeLevel 乐观生效并持久化（只在 off / lv1 往返）', () async {
    final provider = ExperimentalSettingsProvider();
    var notified = 0;
    provider.addListener(() => notified++);

    expect(await provider.setAgentModeLevel(AgentModeLevel.lv1), isTrue);
    expect(provider.agentModeLevel, AgentModeLevel.lv1);
    expect(provider.agentModeEnabled, isTrue);
    expect(notified, 1);

    // 持久化后重新加载（模拟重启）仍为 Lv.1。
    final reloaded = ExperimentalSettingsProvider();
    await reloaded.load();
    expect(reloaded.agentModeLevel, AgentModeLevel.lv1);
    final config = await LocalConfigService.read();
    expect(config[ExperimentalSettingsProvider.keyAgentModeLevel], 1);

    // 切回关闭：落 0，不残留旧档位值。
    expect(await provider.setAgentModeLevel(AgentModeLevel.off), isTrue);
    expect(provider.agentModeLevel, AgentModeLevel.off);
    expect(provider.agentModeEnabled, isFalse);
    final config2 = await LocalConfigService.read();
    expect(config2[ExperimentalSettingsProvider.keyAgentModeLevel], 0);

    // 再切回 Lv.1：往返只在两档之间。
    expect(await provider.setAgentModeLevel(AgentModeLevel.lv1), isTrue);
    final config3 = await LocalConfigService.read();
    expect(config3[ExperimentalSettingsProvider.keyAgentModeLevel], 1);
    expect(AgentModeLevel.values, hasLength(2), reason: '档位只剩 off / lv1');
  });
}
