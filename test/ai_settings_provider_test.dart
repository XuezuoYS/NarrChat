import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/providers/ai_settings_provider.dart';
import 'package:narrchat/services/local_config_service.dart';

/// [AiSettingsProvider] 图片相关设置（`maxImageSizeMB` / `convertJpgToJpeg`）
/// 的开关状态与本地持久化测试。
///
/// 仅覆盖「构造默认值 + 即时持久化（不触碰 secure storage / path_provider 平台通道）」路径；
/// `load()` 因调用原生安全存储插件，不在此处覆盖（与迁移测试的纯函数做法一致）。
void main() {
  late Directory tempRoot;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('narrchat_ai_settings_');
    LocalConfigService.testRootOverride = tempRoot.path;
  });

  tearDown(() async {
    LocalConfigService.testRootOverride = null;
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  test('convertJpgToJpeg 默认关闭', () {
    final provider = AiSettingsProvider();
    expect(provider.convertJpgToJpeg, isFalse);
  });

  test('setConvertJpgToJpeg：更新状态并持久化到本地配置', () async {
    final provider = AiSettingsProvider();
    expect(provider.convertJpgToJpeg, isFalse);

    final ok = await provider.setConvertJpgToJpeg(true);
    expect(ok, isTrue);
    expect(provider.convertJpgToJpeg, isTrue);

    final cfg = await LocalConfigService.read();
    expect(cfg['convertJpgToJpeg'], isTrue);

    // 再次关闭：状态与持久化均更新。
    final ok2 = await provider.setConvertJpgToJpeg(false);
    expect(ok2, isTrue);
    expect(provider.convertJpgToJpeg, isFalse);
    expect((await LocalConfigService.read())['convertJpgToJpeg'], isFalse);
  });
}
