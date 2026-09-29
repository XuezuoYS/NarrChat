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

  group('字体大小档位设置', () {
    test('未配置时使用默认档（索引 0 = 0%，不缩放）', () async {
      final p = UiSettingsProvider();
      await p.load();
      expect(p.fontScaleIndex, 0);
      expect(p.fontScaleLabel, '0%');
      expect(p.fontScaleMultiplier, 1.0);
    });

    test('setFontScaleIndex 写入配置且可重新加载（含最小/最大档）', () async {
      final p = UiSettingsProvider();
      await p.load();

      // 最小档 -30%（负偏移量）。
      await p.setFontScaleIndex(FontScaleLevel.minus30.offset);
      expect(p.fontScaleIndex, FontScaleLevel.minus30.offset);
      expect(p.fontScaleMultiplier, 0.70);
      expect(
        await LocalConfigService.readValue<num>(
          UiSettingsProvider.keyFontScaleIndex,
        ),
        FontScaleLevel.minus30.offset,
      );

      // 最大档 +45%。
      await p.setFontScaleIndex(FontScaleLevel.plus45.offset);
      expect(p.fontScaleLabel, '+45%');
      final reloaded = UiSettingsProvider();
      await reloaded.load();
      expect(reloaded.fontScaleIndex, FontScaleLevel.plus45.offset);
      expect(reloaded.fontScaleMultiplier, 1.45);
    });

    test('越界偏移量归一化为默认档', () async {
      final p = UiSettingsProvider();
      await p.load();
      await p.setFontScaleIndex(FontScaleLevel.maxOffset + 1);
      expect(p.fontScaleIndex, 0);
      await p.setFontScaleIndex(FontScaleLevel.minOffset - 1);
      expect(p.fontScaleIndex, 0);
    });

    test('配置中的非法值（越界 / 小数 / 类型不符）加载时回退默认档', () async {
      for (final invalid in <Object>[-3, 4, 99, 2.5, 'abc']) {
        await LocalConfigService.write({
          UiSettingsProvider.keyFontScaleIndex: invalid,
          UiSettingsProvider.keyThemeMode: 'dark',
        });
        final p = UiSettingsProvider();
        await p.load();
        expect(p.fontScaleIndex, 0, reason: '非法值 $invalid 应回退 0%');
        // 消毒只针对档位键，不影响其它键。
        expect(p.themeMode, AppThemeMode.dark);
      }
    });

    test('写入档位不冲掉字体、主题、侧栏宽度等其它键', () async {
      final p = UiSettingsProvider();
      await p.load();
      await p.setThemeMode(AppThemeMode.dark);
      await p.setChatSidebarWidth(520);
      await p.setFontScaleIndex(2);

      final reloaded = UiSettingsProvider();
      await reloaded.load();
      expect(reloaded.fontScaleIndex, 2);
      expect(reloaded.themeMode, AppThemeMode.dark);
      expect(reloaded.chatSidebarWidth, 520);
    });
  });
}
