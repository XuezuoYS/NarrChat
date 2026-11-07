import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/settings/settings_kit.dart';

/// 设置页版式组件：卡片圆角 / 页面头 / 分区头 / 可展开卡片动画。
void main() {
  Widget wrap(Widget child, {ThemeData? theme}) {
    return MaterialApp(
      theme: theme ?? NarrChatTheme.light,
      home: Scaffold(
        body: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: SizedBox(width: 600, child: child),
          ),
        ),
      ),
    );
  }

  testWidgets('SettingsCard 使用统一卡片圆角与描边', (tester) async {
    await tester.pumpWidget(
      wrap(const SettingsCard(child: SizedBox(height: 40))),
    );

    final material = tester.widget<Material>(
      find
          .descendant(
            of: find.byType(SettingsCard),
            matching: find.byType(Material),
          )
          .first,
    );
    final shape = material.shape! as RoundedRectangleBorder;
    expect(
      shape.borderRadius,
      BorderRadius.circular(NarrChatTheme.cardRadius),
      reason: '卡片圆角必须来自统一 token，而不是各页手写 10/12/16',
    );
    expect(shape.side.color, NarrChatColors.light.divider);
  });

  testWidgets('SettingsCard 在暗色主题下同样渲染（无异常）', (tester) async {
    await tester.pumpWidget(
      wrap(
        const SettingsCard(child: SizedBox(height: 40)),
        theme: NarrChatTheme.dark,
      ),
    );

    expect(tester.takeException(), isNull);
    final material = tester.widget<Material>(
      find
          .descendant(
            of: find.byType(SettingsCard),
            matching: find.byType(Material),
          )
          .first,
    );
    final shape = material.shape! as RoundedRectangleBorder;
    expect(shape.side.color, NarrChatColors.dark.divider);
  });

  testWidgets('页面头 / 分区头 / 卡内头文案齐全且顺序正确', (tester) async {
    await tester.pumpWidget(
      wrap(
        Column(
          children: [
            const SettingsPageHeader(title: '页面标题', description: '页面描述'),
            SettingsSection(
              icon: Icons.tune,
              title: '分区标题',
              subtitle: '分区描述',
              child: const SettingsCard(
                padding: EdgeInsets.all(12),
                child: Text('分区内容'),
              ),
            ),
            const SettingsCard(
              padding: EdgeInsets.all(12),
              child: SettingsCardHeader(
                icon: Icons.info_outline,
                title: '卡内标题',
                subtitle: '卡内描述',
              ),
            ),
          ],
        ),
      ),
    );

    expect(find.text('页面标题'), findsOneWidget);
    expect(find.text('页面描述'), findsOneWidget);
    expect(find.text('分区标题'), findsOneWidget);
    expect(find.text('分区描述'), findsOneWidget);
    expect(find.text('分区内容'), findsOneWidget);
    expect(find.text('卡内标题'), findsOneWidget);
    expect(find.text('卡内描述'), findsOneWidget);

    // 分区头在内容上方；卡内头与服务内容同处一张卡。
    expect(
      tester.getTopLeft(find.text('分区标题')).dy,
      lessThan(tester.getTopLeft(find.text('分区内容')).dy),
    );
  });

  testWidgets('可展开卡片：初始收起，点头部展开、再点收起（带箭头旋转）', (tester) async {
    await tester.pumpWidget(
      wrap(
        const SettingsExpandableCard(
          title: Text('平台'),
          child: Text('模型内容'),
        ),
      ),
    );

    expect(find.text('模型内容'), findsNothing);
    expect(
      tester.widget<AnimatedRotation>(find.byType(AnimatedRotation)).turns,
      0,
    );

    await tester.tap(find.text('平台'));
    await tester.pumpAndSettle();
    expect(find.text('模型内容'), findsOneWidget);
    expect(
      tester.widget<AnimatedRotation>(find.byType(AnimatedRotation)).turns,
      0.5,
    );

    await tester.tap(find.text('平台'));
    await tester.pumpAndSettle();
    expect(find.text('模型内容'), findsNothing);
  });

  testWidgets('可展开卡片：initiallyExpanded 为 true 时首帧即展开', (tester) async {
    await tester.pumpWidget(
      wrap(
        const SettingsExpandableCard(
          title: Text('平台'),
          initiallyExpanded: true,
          child: Text('模型内容'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('模型内容'), findsOneWidget);
  });
}
