import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/island_bar.dart';
import 'package:narrchat/widgets/narr_chat_app_bar.dart';

/// 统一顶栏 `NarrChatAppBar` 的通用行为：
/// - 左侧按键 / 标题留白 / 右侧按键 / 图标 + 标题排布；
/// - 无左侧按键时标题保留标准左留白（16），不再贴到窗口左缘；
/// - 自动返回按钮交给 `AppBar` 依据 `ModalRoute.impliesAppBarDismissal` 判定，
///   路由栈变化后会自动消失（曾出现「返回首页后残留返回按钮」）；
/// - 系统状态栏图标按顶栏实际底色反色（安卓亮色模式下白底白图标会像被隐藏）。
void main() {
  Widget barApp({Widget? home, String title = '测试页', ThemeData? theme}) =>
      MaterialApp(
        theme: theme ?? NarrChatTheme.light,
        home:
            home ??
            IslandAwareScaffold(
              appBarBuilder: (context, extraRow) => NarrChatAppBar(
                extraRowHeight: extraRow,
                icon: const Icon(Icons.abc, size: 24),
                title: title,
              ),
              body: const SizedBox.expand(),
            ),
      );

  /// 顶栏（`AppBar`）实际生效的系统状态栏样式。
  SystemUiOverlayStyle statusBarStyleOf(WidgetTester tester) {
    return tester
        .widget<AnnotatedRegion<SystemUiOverlayStyle>>(
          find.descendant(
            of: find.byType(AppBar),
            matching: find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
          ),
        )
        .value;
  }

  /// 与业务页一致的「二级页」：自带统一顶栏，应出现自动返回按钮。
  Widget secondPage() => IslandAwareScaffold(
    appBarBuilder: (context, extraRow) =>
        NarrChatAppBar(extraRowHeight: extraRow, title: '二级页'),
    body: const SizedBox.expand(),
  );

  testWidgets('根路由（无左侧按键）：标题保留标准左留白，且不显示返回按钮', (tester) async {
    await tester.pumpWidget(barApp());
    await tester.pumpAndSettle();

    expect(find.byType(BackButton), findsNothing);
    // 标题组件（此处为图标）从 16px 处开始，标题文字紧随图标。
    expect(tester.getRect(find.byIcon(Icons.abc)).left, closeTo(16, 0.5));
    expect(tester.getRect(find.text('测试页')).left, closeTo(16 + 24 + 10, 0.5));
  });

  testWidgets('可返回路由：自动出现返回按钮，标题让位', (tester) async {
    await tester.pumpWidget(barApp());
    await tester.pumpAndSettle();
    final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
    navigator.push(
      MaterialPageRoute<void>(builder: (_) => secondPage()),
    );
    await tester.pumpAndSettle();

    // 二级页顶栏出现自动返回按钮（48 宽的图标按钮居中于 56 宽的左键区），
    // 标题从 0 间距开始（紧随左键）。
    expect(find.text('二级页'), findsOneWidget);
    expect(find.byType(BackButton), findsOneWidget);
    final back = tester.getRect(find.byType(BackButton));
    expect(back.center.dx, closeTo(kToolbarHeight / 2, 0.5));
    expect(back.width, 48);
    expect(
      tester.getRect(find.text('二级页')).left,
      greaterThanOrEqualTo(kToolbarHeight),
    );
  });

  testWidgets('无常驻岛：标题不受挤压，可用满顶栏宽度', (tester) async {
    // 未接入岛作用域（无槽位）时，标题不应被预留出「岛的位置」。
    const longTitle =
        '测试页面标题很长用于验证无常驻岛时标题不会被挤压所以这里再补上足够多的字符让它远超顶栏中线';
    await tester.pumpWidget(barApp(title: longTitle));
    await tester.pumpAndSettle();

    final barWidth = tester.getSize(find.byType(NarrChatAppBar)).width;
    final title = tester.getRect(find.text(longTitle));
    expect(title.right, greaterThan(barWidth / 2),
        reason: '没有岛时标题不该被压到左半区');
    expect(title.left, closeTo(16 + 24 + 10, 0.5));
  });

  testWidgets('返回根路由后：返回按钮不残留，标题左留白恢复', (tester) async {
    await tester.pumpWidget(barApp());
    await tester.pumpAndSettle();
    final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);

    navigator.push(MaterialPageRoute<void>(builder: (_) => secondPage()));
    await tester.pumpAndSettle();
    expect(find.byType(BackButton), findsOneWidget);

    navigator.pop();
    await tester.pumpAndSettle();

    expect(find.text('二级页'), findsNothing);
    expect(find.byType(BackButton), findsNothing,
        reason: '回到根路由后不应残留返回按钮');
    expect(tester.getRect(find.byIcon(Icons.abc)).left, closeTo(16, 0.5));
  });

  // 系统状态栏图标必须跟随顶栏底色。回归：顶栏底色画在外层容器、里面的
  // `AppBar` 自身透明，交给它自动推导会把「透明」当成纯黑 → 永远是白色图标，
  // 安卓亮色模式下白底白图标，状态栏内容看起来像被隐藏。
  testWidgets('亮色主题：状态栏透明 + 深色图标', (tester) async {
    await tester.pumpWidget(barApp());
    await tester.pumpAndSettle();

    final style = statusBarStyleOf(tester);
    expect(style.statusBarColor, Colors.transparent);
    expect(style.statusBarIconBrightness, Brightness.dark);
    expect(style.statusBarBrightness, Brightness.light);
  });

  testWidgets('暗色主题：状态栏透明 + 浅色图标', (tester) async {
    await tester.pumpWidget(barApp(theme: NarrChatTheme.dark));
    await tester.pumpAndSettle();

    final style = statusBarStyleOf(tester);
    expect(style.statusBarColor, Colors.transparent);
    expect(style.statusBarIconBrightness, Brightness.light);
    expect(style.statusBarBrightness, Brightness.dark);
  });

  testWidgets('自定义深色顶栏底色：状态栏图标自动转浅色', (tester) async {
    await tester.pumpWidget(
      barApp(
        home: IslandAwareScaffold(
          appBarBuilder: (context, extraRow) => NarrChatAppBar(
            extraRowHeight: extraRow,
            title: '深色顶栏',
            backgroundColor: Colors.black,
          ),
          body: const SizedBox.expand(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(statusBarStyleOf(tester).statusBarIconBrightness, Brightness.light);
  });
}
