import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/providers/ai_settings_provider.dart';
import 'package:narrchat/providers/cloud_sync_provider.dart';
import 'package:narrchat/providers/experimental_settings_provider.dart';
import 'package:narrchat/providers/ui_settings_provider.dart';
import 'package:narrchat/screens/settings_screen.dart';
import 'package:narrchat/services/local_config_service.dart';
import 'package:narrchat/services/system_fonts_service.dart';
import 'package:narrchat/services/update_check_flow.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:provider/provider.dart';

/// 真实 LocalConfigService 的文件 IO 在 testWidgets 的 fake zone 中不会自行
/// 完成：每次 IO 步骤的完成回调会排入 fake 微任务队列，需「真实事件循环让步
/// （runAsync）+ 假时钟泵微任务（pump）」交替推进才可落定。循环多轮直至配置
/// 读写全部完成（读失败也会落定为默认值，不会死循环）。
Future<void> flushConfig(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
  }
}

void main() {
  late Directory tempRoot;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp(
      'narrchat_general_update_',
    );
    LocalConfigService.testRootOverride = tempRoot.path;
    // 上个 testWidgets 的 fake zone 拆解后，静态互斥队列可能残留死链，
    // 重置以隔离用例间状态。
    LocalConfigService.resetForTest();
  });

  tearDown(() async {
    LocalConfigService.testRootOverride = null;
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  Widget buildSettings() {
    return ChangeNotifierProvider(
      create: (_) => AiSettingsProvider(),
      child: ChangeNotifierProvider(
        create: (_) => ExperimentalSettingsProvider(),
        child: ChangeNotifierProvider(
          create: (_) => CloudSyncProvider(),
          child: ChangeNotifierProvider(
            create: (_) => UiSettingsProvider(),
            child: MaterialApp(
              theme: NarrChatTheme.light,
              home: const SettingsScreen(),
            ),
          ),
        ),
      ),
    );
  }

  /// pump 设置页并落定（预扫描系统字体，避免字体扫描真实 IO 挂起）。
  Future<void> pumpSettings(WidgetTester tester) async {
    // 预扫描系统字体：字体扫描是真实 IO，在 fake zone 中永不完成，
    // 会让 UiSettingsForm 一直显示转圈动画，导致 pumpAndSettle 超时。
    await tester.runAsync(() => SystemFontsService.instance.scan());
    await tester.pumpWidget(buildSettings());
    await tester.pumpAndSettle();
  }

  /// 打开「通用设置」面板（设置页首页即是；检查更新开关位于其
  /// 「其它设置」子分区），并让 initState 中的真实配置读取完成。
  Future<void> openGeneralSettings(WidgetTester tester) async {
    await pumpSettings(tester);
    await flushConfig(tester);
  }

  Switch switchWidget(WidgetTester tester) => tester.widget<Switch>(
        find.byKey(const ValueKey('other_update_check_switch')),
      );

  testWidgets('无配置时开关默认开启', (tester) async {
    await openGeneralSettings(tester);

    expect(switchWidget(tester).value, isTrue);
  });

  testWidgets('预置 updateCheckEnabled:false 时开关为关', (tester) async {
    await tester.runAsync(
      () => LocalConfigService.update(
        {UpdateCheckFlow.keyUpdateCheckEnabled: false},
      ),
    );

    await openGeneralSettings(tester);

    expect(switchWidget(tester).value, isFalse);
  });

  testWidgets('点击开关生效并落盘（可再次切回）', (tester) async {
    await openGeneralSettings(tester);
    expect(switchWidget(tester).value, isTrue);

    await tester.tap(find.byKey(const ValueKey('other_update_check_switch')));
    await tester.pump();
    expect(switchWidget(tester).value, isFalse);
    await flushConfig(tester);
    var config = await tester.runAsync(LocalConfigService.read);
    expect(config![UpdateCheckFlow.keyUpdateCheckEnabled], isFalse);

    await tester.tap(find.byKey(const ValueKey('other_update_check_switch')));
    await tester.pump();
    expect(switchWidget(tester).value, isTrue);
    await flushConfig(tester);
    config = await tester.runAsync(LocalConfigService.read);
    expect(config![UpdateCheckFlow.keyUpdateCheckEnabled], isTrue);
  });

  testWidgets('设置页首页即「通用设置」（无需切换面板）', (tester) async {
    await openGeneralSettings(tester);

    // 默认落在通用面板：其「其它设置」子分区的开关直接可见，无需任何点按。
    expect(find.byKey(const ValueKey('other_update_check_switch')), findsOneWidget);
    // 左侧导航第一项也是「通用设置」（导航项 + 面板标题共两处同名文本）。
    expect(find.text('通用设置'), findsNWidgets(2));
  });

  testWidgets('「关于」面板不再显示检查更新开关（已迁移）', (tester) async {
    await pumpSettings(tester);
    await tester.tap(find.text('关于'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('other_update_check_switch')),
      findsNothing,
    );
    expect(find.text('检查更新'), findsNothing);
  });
}
