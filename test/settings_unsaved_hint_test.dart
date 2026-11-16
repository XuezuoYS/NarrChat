import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/ai_platform.dart';
import 'package:narrchat/providers/ai_settings_provider.dart';
import 'package:narrchat/providers/cloud_sync_provider.dart';
import 'package:narrchat/screens/settings_screen.dart';
import 'package:narrchat/services/app_notice_center.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:provider/provider.dart';

import 'helpers/notice_harness.dart';

/// 全局设置页「存在变更未保存」黄色提示。
///
/// 覆盖范围只应包含「点保存才生效」的内容（API 设置 / 云同步）；
/// 图片大小上限、jpg 转换这类即时落库项改了立刻生效，不应出提示。
void main() {
  Finder hint() => find.byKey(const ValueKey('settings_unsaved_hint'));

  Finder fieldWithLabel(String label) => find.byWidgetPredicate(
    (widget) => widget is TextField && widget.decoration?.labelText == label,
  );

  Future<void> pumpSettings(
    WidgetTester tester,
    _MemoryAiSettingsProvider ai,
  ) async {
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final center = AppNoticeCenter();
    addTearDown(center.dispose);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AiSettingsProvider>.value(value: ai),
          ChangeNotifierProvider<CloudSyncProvider>(
            create: (_) => CloudSyncProvider(),
          ),
        ],
        child: MaterialApp(
          theme: NarrChatTheme.light,
          builder: floatingNoticeBuilder(center: center),
          home: const SettingsScreen(initialIndex: SettingsScreen.pageIndexApi),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 每个用例独立一套 Provider（替身内部状态不跨用例共享）。
  _MemoryAiSettingsProvider makeAi() {
    final ai = _MemoryAiSettingsProvider();
    addTearDown(ai.dispose);
    return ai;
  }

  testWidgets('初始不显示提示；改平台名出现黄字，改回原值消失', (tester) async {
    final ai = makeAi();
    await pumpSettings(tester, ai);

    expect(hint(), findsNothing);
    expect(find.text('存在变更未保存'), findsNothing);

    final original = ai.platforms.first.displayName;
    final nameField = fieldWithLabel('平台名称');
    await tester.ensureVisible(nameField);
    await tester.pumpAndSettle();
    await tester.enterText(nameField, '我的网关');
    await tester.pump();

    expect(hint(), findsOneWidget);
    expect(find.text('存在变更未保存'), findsOneWidget);

    await tester.enterText(fieldWithLabel('平台名称'), original);
    await tester.pump();

    expect(hint(), findsNothing);
  });

  testWidgets('API Key 输入（控制器监听）触发未保存提示', (tester) async {
    final ai = makeAi();
    await pumpSettings(tester, ai);

    final apiKeyField = fieldWithLabel('API Key');
    await tester.ensureVisible(apiKeyField);
    await tester.pumpAndSettle();
    await tester.enterText(apiKeyField, 'sk-test');
    await tester.pump();

    expect(hint(), findsOneWidget);
  });

  testWidgets('即时生效的图片设置不触发未保存提示', (tester) async {
    final ai = makeAi();
    await pumpSettings(tester, ai);

    final toggle = find.byKey(const ValueKey('ai_settings_convert_jpg_switch'));
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pump();

    expect(ai.convertJpgToJpeg, isTrue);
    expect(hint(), findsNothing);
  });

  testWidgets('云同步连接与同步模式改动触发提示；改回后消失', (tester) async {
    final ai = makeAi();
    await pumpSettings(tester, ai);

    await tester.tap(find.text('云同步'));
    await tester.pumpAndSettle();

    final urlField = fieldWithLabel('WebDAV 服务器地址');
    await tester.ensureVisible(urlField);
    await tester.pumpAndSettle();
    await tester.enterText(urlField, 'https://dav.example.com/dav/');
    await tester.pump();
    expect(hint(), findsOneWidget);

    await tester.enterText(fieldWithLabel('WebDAV 服务器地址'), '');
    await tester.pump();
    expect(hint(), findsNothing);

    await tester.tap(find.text('手动'));
    await tester.pump();
    expect(hint(), findsOneWidget);
  });

  testWidgets('点保存成功后黄字提示消失', (tester) async {
    final ai = makeAi();
    await pumpSettings(tester, ai);

    final nameField = fieldWithLabel('平台名称');
    await tester.ensureVisible(nameField);
    await tester.pumpAndSettle();
    await tester.enterText(nameField, '我的网关');
    await tester.pump();
    expect(hint(), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    expect(ai.saveCalls, 1);
    expect(hint(), findsNothing);
    await flushNotices(tester);
  });
}

/// 内存版 AI 设置（只覆盖本文件会碰到的保存 / 即时项）。
class _MemoryAiSettingsProvider extends AiSettingsProvider {
  int saveCalls = 0;
  int _maxImageSizeMB = 16;
  bool _convertJpgToJpeg = false;

  @override
  int get maxImageSizeMB => _maxImageSizeMB;

  @override
  bool get convertJpgToJpeg => _convertJpgToJpeg;

  @override
  Future<bool> setMaxImageSizeMB(int mb) async {
    _maxImageSizeMB = mb;
    notifyListeners();
    return true;
  }

  @override
  Future<bool> setConvertJpgToJpeg(bool value) async {
    _convertJpgToJpeg = value;
    notifyListeners();
    return true;
  }

  @override
  Future<bool> save({
    required List<AiPlatform> platforms,
    required String selectedPlatformId,
    required String selectedModelId,
    required Map<String, String> apiKeys,
  }) async {
    saveCalls++;
    return true;
  }
}
