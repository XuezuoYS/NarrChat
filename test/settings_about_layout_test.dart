import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/providers/ai_settings_provider.dart';
import 'package:narrchat/providers/cloud_sync_provider.dart';
import 'package:narrchat/screens/settings_screen.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/brand_logo.dart';
import 'package:provider/provider.dart';

/// 宽屏下「关于」面板的排版回归测试。
///
/// 设置页整体为「左侧导航 + 靠左内容列」骨架，「关于」是信息型短面板，
/// 通过 `SettingsNavItem.centered` 豁免靠左结构：内容限宽 400、在内容区
/// 内水平居中，纵向从顶部排布（曾出现宽屏下挂在左上角、右侧大片空白的问题）。
void main() {
  /// 以宽屏视口直达「关于」面板。
  ///
  /// 用 initialIndex 跳过首页「通用设置」的挂载（其依赖 UI / 实验性设置
  /// Provider 与系统字体扫描），本文件只测关于面板的排版。
  Future<void> openAboutWide(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AiSettingsProvider(),
        child: ChangeNotifierProvider(
          create: (_) => CloudSyncProvider(),
          child: MaterialApp(
            theme: NarrChatTheme.light,
            home: const SettingsScreen(
              initialIndex: SettingsScreen.pageIndexAbout,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('宽屏：关于面板内容在内容区内水平居中、纵向从顶部排布', (tester) async {
    await openAboutWide(tester);

    final scroll = tester.getRect(find.byType(SingleChildScrollView));
    // 关于面板已被挂载（品牌图标可见）。
    expect(find.byType(BrandLogo), findsOneWidget);

    // 水平居中：品牌图标中心与内容区中心重合。
    final logo = tester.getRect(find.byType(BrandLogo));
    expect(logo.center.dx, closeTo(scroll.center.dx, 0.5));

    // 纵向不做垂直居中：信息卡顶边落在滚动区顶部 + 24 内边距处。
    final cardTop = tester
        .getRect(
          find
              .ancestor(
                of: find.byType(BrandLogo),
                matching: find.byType(Container),
              )
              .first,
        )
        .top;
    expect(cardTop, closeTo(scroll.top + 24, 0.5));
  });

  testWidgets('宽屏：关于面板信息卡限宽 400（不撑满靠左骨架的 860）', (tester) async {
    await openAboutWide(tester);

    // 品牌图标所在的信息卡容器（width: double.infinity）撑满内容列，
    // 其实测宽度即内容列限宽 400（而非靠左面板的 860）。
    final card = tester.getRect(
      find
          .ancestor(
            of: find.byType(BrandLogo),
            matching: find.byType(Container),
          )
          .first,
    );
    expect(card.width, closeTo(400, 0.5));
  });
}
