import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:narrchat/providers/ui_settings_provider.dart';
import 'package:narrchat/screens/font_settings_screen.dart';
import 'package:narrchat/services/local_config_service.dart';
import 'package:narrchat/theme/app_theme.dart';

/// 「字体设置」二级页：结构、草稿态隔离、重置、保存落盘与未保存返回提示。
void main() {
  late Directory tempRoot;
  late UiSettingsProvider provider;

  setUp(() async {
    LocalConfigService.resetForTest();
    tempRoot = await Directory.systemTemp.createTemp('narrchat_font_settings_');
    LocalConfigService.testRootOverride = tempRoot.path;
    provider = UiSettingsProvider();
  });

  tearDown(() async {
    LocalConfigService.testRootOverride = null;
    // 清掉可能残留的互斥队列链（fake zone 中未完成的写链不该影响下一个用例）。
    LocalConfigService.resetForTest();
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  /// pump 一个可从当前页 push 出字体设置二级页的最小应用。
  Future<void> pumpApp(WidgetTester tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ChangeNotifierProvider<UiSettingsProvider>.value(
        value: provider,
        child: MaterialApp(
          navigatorKey: navigator,
          theme: NarrChatTheme.light,
          home: const Scaffold(body: SizedBox()),
        ),
      ),
    );
    // 直接 push 二级页（不等待其返回，页面由测试交互）。
    navigator.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const FontSettingsScreen()),
    );
    await tester.pumpAndSettle();
  }

  /// 在真实 zone 中执行 [action] 并驱动真实事件循环，同时持续泵帧。
  ///
  /// 用于「点击 → 页面异步落盘 → 返回上一级」这类跨 zone 流程：
  /// 点击后对话框的 pop 回调在测试 fake zone 中续跑，其文件 IO 只有真实
  /// 事件循环推进才能完成，因此必须在 runAsync 内一边等真实时间一边泵帧。
  Future<void> runInRealZone(
    WidgetTester tester,
    Future<void> Function() action, {
    Duration settle = const Duration(seconds: 5),
  }) async {
    await tester.runAsync(() async {
      await action();
      final deadline = DateTime.now().add(settle);
      while (DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 20));
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();
  }

  testWidgets('页面结构齐全：顶栏（重置 / 保存）、预览块、字体与大小选择', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpApp(tester);

    // 顶栏。
    expect(find.text('字体设置'), findsOneWidget);
    expect(find.byKey(const ValueKey('font_settings_back')), findsOneWidget);
    expect(find.byKey(const ValueKey('font_settings_reset')), findsOneWidget);
    expect(find.byKey(const ValueKey('font_settings_save')), findsOneWidget);
    // 预览块。
    expect(find.text('预览'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('font_settings_preview_cn')),
      findsOneWidget,
    );
    // 字体选择。
    expect(find.text('字体样式'), findsOneWidget);
    expect(find.byKey(const ValueKey('font_settings_font_tile')), findsOneWidget);
    // 大小选择：默认档标签 + 滑杆 + 6 个刻度标签。
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('font_settings_scale_label')))
          .data,
      '0%',
    );
    expect(
      find.byKey(const ValueKey('font_settings_scale_slider')),
      findsOneWidget,
    );
    // 刻度标签与当前档位标签可能同名（如默认档两处都是 0%），故用 findsWidgets。
    for (final level in FontScaleLevel.values) {
      expect(find.text(level.label), findsWidgets, reason: level.label);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('拖动滑杆为草稿态：档位标签即时变化，保存前不写入全局设置', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpApp(tester);

    final slider = find.byKey(const ValueKey('font_settings_scale_slider'));
    String label() => tester
        .widget<Text>(find.byKey(const ValueKey('font_settings_scale_label')))
        .data!;

    expect(label(), '0%');
    expect(provider.fontScaleIndex, 0);

    // 最右档 = +45%。
    await tester.drag(slider, const Offset(600, 0));
    await tester.pumpAndSettle();
    expect(label(), '+45%');
    expect(provider.fontScaleIndex, 0, reason: '保存前不得写入全局设置');

    // 最左档 = -30%。
    await tester.drag(slider, const Offset(-900, 0));
    await tester.pumpAndSettle();
    expect(label(), '-30%');
    expect(provider.fontScaleIndex, 0, reason: '保存前不得写入全局设置');
  });

  testWidgets('保存：档位写入 Provider 并落盘，随后返回上一级', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpApp(tester);

    await tester.drag(
      find.byKey(const ValueKey('font_settings_scale_slider')),
      const Offset(600, 0),
    );
    await tester.pumpAndSettle();

    // 落盘是真实文件 IO：须在真实 zone 中点击并驱动事件循环，
    // 否则 fake zone 里 LocalConfigService 的 Future 永不完成。
    await runInRealZone(tester, () async {
      await tester.tap(find.byKey(const ValueKey('font_settings_save')));
    });

    expect(provider.fontScaleIndex, FontScaleLevel.plus45.offset);
    expect(provider.fontScaleLabel, '+45%');
    expect(
      await tester.runAsync(
        () => LocalConfigService.readValue<num>(
          UiSettingsProvider.keyFontScaleIndex,
        ),
      ),
      FontScaleLevel.plus45.offset,
    );
    // 保存后返回上一级。
    expect(find.byKey(const ValueKey('font_settings_save')), findsNothing);
  });

  testWidgets('重置：字体样式回系统默认、大小回 0%', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpApp(tester);

    // 通过真实交互把草稿改为非默认档（避免 fake zone 中的真实落盘）。
    final slider = find.byKey(const ValueKey('font_settings_scale_slider'));
    await tester.drag(slider, const Offset(600, 0));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('font_settings_scale_label')))
          .data,
      '+45%',
    );

    await tester.tap(find.byKey(const ValueKey('font_settings_reset')));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('font_settings_scale_label')))
          .data,
      '0%',
    );
    // 字体样式同时重置为系统默认。
    expect(find.text('系统默认'), findsOneWidget);
  });

  testWidgets('返回：无修改直接退出，不弹提示', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpApp(tester);

    await tester.tap(find.byKey(const ValueKey('font_settings_back')));
    await tester.pumpAndSettle();

    expect(find.text('保存修改？'), findsNothing);
    expect(find.byKey(const ValueKey('font_settings_save')), findsNothing);
  });

  testWidgets('返回：有修改时弹提示，选「不保存」退出且全局设置不变', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpApp(tester);

    await tester.drag(
      find.byKey(const ValueKey('font_settings_scale_slider')),
      const Offset(600, 0),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('font_settings_back')));
    await tester.pumpAndSettle();
    expect(find.text('保存修改？'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('font_settings_unsaved_discard')),
    );
    await tester.pumpAndSettle();

    expect(provider.fontScaleIndex, 0, reason: '「不保存」不得写入全局设置');
    expect(find.byKey(const ValueKey('font_settings_save')), findsNothing);
  });

  testWidgets('返回：有修改时选「取消」留在页面，选「保存」保存并退出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpApp(tester);

    await tester.drag(
      find.byKey(const ValueKey('font_settings_scale_slider')),
      const Offset(600, 0),
    );
    await tester.pumpAndSettle();

    // 取消：留在页面。
    await tester.tap(find.byKey(const ValueKey('font_settings_back')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('font_settings_unsaved_cancel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('font_settings_save')), findsOneWidget);
    expect(provider.fontScaleIndex, 0);

    // 保存：写入并退出（对话框 pop 回调在 fake zone 续跑，需真实事件循环）。
    await tester.tap(find.byKey(const ValueKey('font_settings_back')));
    await tester.pumpAndSettle();
    await runInRealZone(tester, () async {
      await tester.tap(
        find.byKey(const ValueKey('font_settings_unsaved_save')),
      );
    });
    expect(provider.fontScaleIndex, FontScaleLevel.plus45.offset);
    expect(find.byKey(const ValueKey('font_settings_save')), findsNothing);
  });

  testWidgets('窄窗口下拖到最大档后刻度标签与预览不溢出', (tester) async {
    // 窄屏 + 最大档（+45%）：验证 6 等分刻度行与预览块的自适应。
    await tester.binding.setSurfaceSize(const Size(420, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpApp(tester);

    await tester.drag(
      find.byKey(const ValueKey('font_settings_scale_slider')),
      const Offset(600, 0),
    );
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('font_settings_scale_label')))
          .data,
      '+45%',
    );
    for (final level in FontScaleLevel.values) {
      expect(find.text(level.label), findsWidgets, reason: level.label);
    }
    expect(
      find.byKey(const ValueKey('font_settings_preview_cn')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
