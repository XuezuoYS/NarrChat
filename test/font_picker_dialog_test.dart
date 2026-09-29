import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/services/system_fonts_service.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/font_picker_dialog.dart';

/// [FontPickerDialog]：系统默认项、字体列表、返回值语义（'' / 族名 / null）。
void main() {
  /// pump 一个立即弹出字体选择对话框的应用，并返回收集到的返回值。
  Future<List<String?>> pumpDialog(
    WidgetTester tester, {
    String current = '',
  }) async {
    final results = <String?>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: NarrChatTheme.light,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  final selected = await showDialog<String>(
                    context: context,
                    builder: (_) => FontPickerDialog(current: current),
                  );
                  results.add(selected);
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    return results;
  }

  testWidgets('对话框列出「系统默认」为首项，点击返回空字符串', (tester) async {
    final results = await pumpDialog(tester);

    expect(find.text('选择全局字体'), findsOneWidget);
    expect(find.text('系统默认'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);

    await tester.tap(find.text('系统默认'));
    await tester.pumpAndSettle();
    expect(results, [''], reason: '选中「系统默认」返回空字符串（清空自定义字体）');
  });

  testWidgets('取消返回 null（表示不改变当前设置）', (tester) async {
    final results = await pumpDialog(tester);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(results, [null]);
  });

  testWidgets('已扫描字体时列出字体名并返回字体族名', (tester) async {
    // 字体扫描是真实 IO：本用例只读服务已有结果（不在此触发扫描，
    // 否则在 fake zone 中永不完成）；未扫描时跳过列表断言。
    final fonts = SystemFontsService.instance.fonts;
    if (fonts.isEmpty) {
      markTestSkipped('当前环境未扫描到系统字体，跳过字体列表断言');
      return;
    }

    final results = await pumpDialog(tester);
    // 首项之后的每一项都以自身字体渲染（族名或中文展示名可见其一）。
    final first = fonts.first;
    expect(
      find.text(first.familyName).evaluate().isNotEmpty ||
          find.text(first.displayName).evaluate().isNotEmpty,
      isTrue,
      reason: '首个系统字体应出现在列表中',
    );

    await tester.tap(find.text(first.displayName).first);
    await tester.pumpAndSettle();
    expect(results.single, isNotNull);
  });
}
