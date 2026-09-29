import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/island_bar.dart';
import 'package:narrchat/widgets/narr_chat_app_bar.dart';

/// 统一顶栏 `NarrChatAppBar` 的通用行为：
/// - 左侧按键 / 标题留白 / 右侧按键 / 图标 + 标题排布；
/// - 无左侧按键时标题保留标准左留白（16），不再贴到窗口左缘；
/// - 自动返回按钮交给 `AppBar` 依据 `ModalRoute.impliesAppBarDismissal` 判定，
///   路由栈变化后会自动消失（曾出现「返回首页后残留返回按钮」）。
void main() {
  Widget barApp({Widget? home}) => MaterialApp(
    theme: NarrChatTheme.light,
    home: home ??
        IslandAwareScaffold(
          appBarBuilder: (context, extraRow) => NarrChatAppBar(
            extraRowHeight: extraRow,
            icon: const Icon(Icons.abc, size: 24),
            title: '测试页',
          ),
          body: const SizedBox.expand(),
        ),
  );

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
}
