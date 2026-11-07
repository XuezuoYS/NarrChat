import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/settings/settings_kit.dart';

/// 设置页交互控件：整行点击、开关/复选只切换一次、下拉菜单、分段滑动、标签切换。
void main() {
  /// 带可变状态的宿主：把 setState 暴露给用例，便于验证「值 + 回调次数」。
  Future<void> pumpHost(
    WidgetTester tester,
    Widget Function(BuildContext context, StateSetter setState) builder, {
    double width = 600,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: NarrChatTheme.light,
        home: Scaffold(
          body: SingleChildScrollView(
            child: Center(
              child: SizedBox(
                width: width,
                child: StatefulBuilder(builder: builder),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('开关行：点整行只切换一次，点开关也只切换一次', (tester) async {
    var value = false;
    var calls = 0;
    await pumpHost(tester, (context, setState) {
      return SettingsCard(
        child: SettingsSwitchRow(
          title: '检查更新',
          subtitle: '启动时检查新版本',
          value: value,
          switchKey: const ValueKey('switch'),
          onChanged: (next) {
            calls++;
            setState(() => value = next);
          },
        ),
      );
    });

    await tester.tap(find.text('检查更新'));
    await tester.pump();
    expect(value, isTrue, reason: '点整行即可切换开关状态');
    expect(calls, 1, reason: '一次点击只触发一次切换');

    await tester.tap(find.byKey(const ValueKey('switch')));
    await tester.pump();
    expect(value, isFalse);
    expect(calls, 2, reason: '点开关本身也只切换一次（不与整行叠加）');
  });

  testWidgets('开关行：禁用时点行与点开关都不回调', (tester) async {
    var calls = 0;
    await pumpHost(tester, (context, setState) {
      return SettingsCard(
        child: SettingsSwitchRow(
          title: '检查更新',
          value: true,
          switchKey: const ValueKey('switch'),
          onChanged: null,
        ),
      );
    });

    await tester.tap(find.text('检查更新'));
    await tester.tap(find.byKey(const ValueKey('switch')));
    await tester.pump();
    expect(calls, 0);
  });

  testWidgets('复选行：点整行与点复选各只切换一次', (tester) async {
    var value = false;
    var calls = 0;
    await pumpHost(tester, (context, setState) {
      return SettingsCard(
        child: SettingsCheckboxRow(
          title: 'gw-a',
          subtitle: '将覆盖同名配置',
          value: value,
          checkboxKey: const ValueKey('checkbox'),
          onChanged: (next) {
            calls++;
            setState(() => value = next);
          },
        ),
      );
    });

    await tester.tap(find.text('gw-a'));
    await tester.pump();
    expect(value, isTrue);
    expect(calls, 1);

    await tester.tap(find.byKey(const ValueKey('checkbox')));
    await tester.pump();
    expect(value, isFalse);
    expect(calls, 2);
  });

  testWidgets('下拉行：点标题行即可展开菜单，选中后当前值淡入更新', (tester) async {
    var value = 'illustration1';
    await pumpHost(tester, (context, setState) {
      return SettingsCard(
        child: SettingsSelectRow<String>(
          title: '默认封面',
          subtitle: '未设置封面时首页展示的内容',
          value: value,
          valueKey: const ValueKey('select_value'),
          labelOf: (v) => v == 'illustration1' ? '插画1' : '无插画',
          options: const [
            SettingsSelectOption(value: 'illustration1', label: '插画1'),
            SettingsSelectOption(
              value: 'none',
              label: '无插画',
              detail: '程序生成的灰底书名封面',
            ),
          ],
          onSelected: (next) => setState(() => value = next),
        ),
      );
    });

    expect(find.text('插画1'), findsOneWidget);
    expect(find.text('无插画'), findsNothing);

    // 点标题文字（不靠近箭头）也能展开。
    await tester.tap(find.text('默认封面'));
    await tester.pumpAndSettle();
    expect(find.text('无插画'), findsOneWidget);
    expect(find.text('程序生成的灰底书名封面'), findsOneWidget);

    await tester.tap(find.text('无插画'));
    await tester.pumpAndSettle();

    expect(value, 'none');
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('select_value'))).data,
      '无插画',
    );
    expect(find.text('程序生成的灰底书名封面'), findsNothing, reason: '菜单已关闭');
  });

  testWidgets('下拉行：菜单右边缘对齐行内箭头（不再靠左）', (tester) async {
    await pumpHost(tester, (context, setState) {
      return SettingsCard(
        child: SettingsSelectRow<String>(
          icon: Icons.image_outlined,
          title: '默认封面',
          subtitle: '未设置封面时首页展示的内容',
          value: 'a',
          rowKey: const ValueKey('select_row'),
          options: const [
            SettingsSelectOption(value: 'a', label: '插画1'),
            SettingsSelectOption(
              value: 'b',
              label: '无插画',
              detail: '程序生成的灰底书名封面',
            ),
          ],
          onSelected: (_) {},
        ),
      );
    });

    final rowRect = tester.getRect(find.byKey(const ValueKey('select_row')));
    await tester.tap(find.text('默认封面'));
    await tester.pumpAndSettle();

    final itemRect = tester.getRect(find.byType(MenuItemButton).first);
    expect(
      itemRect.right,
      closeTo(rowRect.right - 14, 1),
      reason: '菜单右边缘应落在行内下拉箭头的右缘（行内边距 14）',
    );
    expect(itemRect.width, closeTo(320, 1), reason: '菜单使用固定宽度');
    expect(
      itemRect.left,
      greaterThan(rowRect.left + 100),
      reason: '菜单不再贴行左缘展开',
    );
  });

  testWidgets('下拉行：无选项时禁用展开', (tester) async {
    await pumpHost(tester, (context, setState) {
      return SettingsCard(
        child: SettingsSelectRow<String>(
          title: '默认封面',
          value: 'a',
          options: const [],
          onSelected: (_) {},
        ),
      );
    });

    await tester.tap(find.text('默认封面'));
    await tester.pumpAndSettle();
    expect(find.byType(MenuItemButton), findsNothing);
  });

  testWidgets('分段选择：点选项更新值，高亮片滑到目标位置', (tester) async {
    var value = 'system';
    await pumpHost(tester, (context, setState) {
      return SettingsSegmented<String>(
        value: value,
        options: const [
          SettingsSegment(
            value: 'system',
            label: '跟随系统',
            icon: Icons.brightness_auto_outlined,
          ),
          SettingsSegment(value: 'light', label: '亮色'),
          SettingsSegment(value: 'dark', label: '暗色'),
        ],
        onChanged: (next) => setState(() => value = next),
      );
    });

    expect(find.byType(ChoiceChip), findsNothing, reason: '分段不是芯片');

    await tester.tap(find.text('暗色'));
    await tester.pumpAndSettle();
    expect(value, 'dark');
    expect(
      tester.widget<AnimatedAlign>(find.byType(AnimatedAlign)).alignment,
      const Alignment(1, 0),
    );
  });

  testWidgets('分段选择行：窄屏换行、宽屏与标题同行', (tester) async {
    Future<void> pumpRow(double width) => pumpHost(tester, (context, setState) {
          return SettingsSegmentedRow<String>(
            icon: Icons.brightness_6_outlined,
            title: '主题',
            subtitle: '跟随系统（默认）：随系统亮暗自动切换',
            value: 'system',
            options: const [
              SettingsSegment(value: 'system', label: '跟随系统'),
              SettingsSegment(value: 'light', label: '亮色'),
              SettingsSegment(value: 'dark', label: '暗色'),
            ],
            onChanged: (_) {},
          );
        }, width: width);

    await pumpRow(400);
    final narrowSegmented = tester.getRect(
      find.byType(SettingsSegmented<String>),
    );
    final narrowTitle = tester.getRect(find.text('主题'));
    expect(
      narrowSegmented.top,
      greaterThan(narrowTitle.bottom + 20),
      reason: '窄屏时分段换到标题下方整行铺开',
    );

    await pumpRow(800);
    final wideSegmented = tester.getRect(find.byType(SettingsSegmented<String>));
    final wideRow = tester.getRect(find.byType(SettingsRow));
    expect(
      wideSegmented.center.dy,
      closeTo(wideRow.center.dy, 1),
      reason: '宽屏时分段与标题同处一行、垂直居中',
    );
    expect(
      wideSegmented.left,
      greaterThan(tester.getRect(find.text('主题')).right),
      reason: '宽屏时分段在标题文字右侧，不挤压标题',
    );
  });

  testWidgets('可切换标签：点击切换，内部仍是 ChoiceChip', (tester) async {
    var selected = false;
    await pumpHost(tester, (context, setState) {
      return SettingsToggleChip(
        label: '识图',
        selected: selected,
        onTap: () => setState(() => selected = !selected),
      );
    });

    final chipFinder = find.byType(ChoiceChip);
    expect(chipFinder, findsOneWidget);
    expect(tester.widget<ChoiceChip>(chipFinder).selected, isFalse);

    await tester.tap(chipFinder);
    await tester.pump();
    expect(selected, isTrue);
    expect(tester.widget<ChoiceChip>(chipFinder).selected, isTrue);
  });
}
