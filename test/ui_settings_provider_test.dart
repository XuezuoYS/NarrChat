import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/providers/ui_settings_provider.dart';
import 'package:narrchat/services/local_config_service.dart';

/// UiSettingsProvider 宽屏侧栏宽度：默认值 / 持久化 / 非法值消毒。
void main() {
  late Directory tempRoot;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('narrchat_ui_settings_');
    LocalConfigService.testRootOverride = tempRoot.path;
  });

  tearDown(() async {
    LocalConfigService.testRootOverride = null;
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  group('宽屏侧栏宽度设置', () {
    test('未配置时使用默认宽度（380 = 最小宽度）', () async {
      final p = UiSettingsProvider();
      await p.load();
      expect(p.chatSidebarWidth, kChatSidebarDefaultWidth);
      expect(p.hasCustomSidebarWidth, isFalse);
    });

    test('setChatSidebarWidth 写入配置且可重新加载', () async {
      final p = UiSettingsProvider();
      await p.load();
      await p.setChatSidebarWidth(520);

      expect(p.chatSidebarWidth, 520);
      expect(p.hasCustomSidebarWidth, isTrue);
      // 落盘到 local_config/app_settings.json（经 testRootOverride 临时目录）。
      expect(
        await LocalConfigService.readValue<num>(
          UiSettingsProvider.keyChatSidebarWidth,
        ),
        520,
      );

      final reloaded = UiSettingsProvider();
      await reloaded.load();
      expect(reloaded.chatSidebarWidth, 520);
    });

    test('低于默认值 / 非有限的输入归一化为默认宽度', () async {
      final p = UiSettingsProvider();
      await p.load();

      await p.setChatSidebarWidth(100);
      expect(p.chatSidebarWidth, kChatSidebarDefaultWidth);

      await p.setChatSidebarWidth(double.nan);
      expect(p.chatSidebarWidth, kChatSidebarDefaultWidth);

      await p.setChatSidebarWidth(double.infinity);
      expect(p.chatSidebarWidth, kChatSidebarDefaultWidth);
    });

    test('配置中的非法值（负数 / 类型不符）加载时回退默认', () async {
      await LocalConfigService.write({
        UiSettingsProvider.keyChatSidebarWidth: -1,
        UiSettingsProvider.keyThemeMode: 'dark',
      });
      final p1 = UiSettingsProvider();
      await p1.load();
      expect(p1.chatSidebarWidth, kChatSidebarDefaultWidth);
      // 消毒只针对宽度键，不影响其它键。
      expect(p1.themeMode, AppThemeMode.dark);

      await LocalConfigService.write({
        UiSettingsProvider.keyChatSidebarWidth: 'abc',
      });
      final p2 = UiSettingsProvider();
      await p2.load();
      expect(p2.chatSidebarWidth, kChatSidebarDefaultWidth);
    });

    test('写入宽度不冲掉主题模式等其它键', () async {
      final p = UiSettingsProvider();
      await p.load();
      await p.setThemeMode(AppThemeMode.dark);
      await p.setChatSidebarWidth(520);

      final reloaded = UiSettingsProvider();
      await reloaded.load();
      expect(reloaded.themeMode, AppThemeMode.dark);
      expect(reloaded.chatSidebarWidth, 520);
    });
  });
}
