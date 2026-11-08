import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/screens/home_screen.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/utils/book_list_utils.dart';
import 'package:narrchat/widgets/book_grid_card.dart';
import 'package:narrchat/widgets/brand_logo.dart';
import 'package:narrchat/widgets/narr_chat_app_bar.dart';

import 'helpers/chat_harness.dart';

/// 首页宽窄屏布局：左侧品牌栏 / 顶栏品牌、动态列数、顶栏动作与新建入口。
void main() {
  const books = [
    Book(uuid: 'b1', title: '书一'),
    Book(uuid: 'b2', title: '书二'),
    Book(uuid: 'b3', title: '书三'),
    Book(uuid: 'b4', title: '书四'),
    Book(uuid: 'b5', title: '书五'),
    Book(uuid: 'b6', title: '书六'),
    Book(uuid: 'b7', title: '书七'),
    Book(uuid: 'b8', title: '书八'),
    Book(uuid: 'b9', title: '书九'),
    Book(uuid: 'b10', title: '书十'),
    Book(uuid: 'b11', title: '书十一'),
    Book(uuid: 'b12', title: '书十二'),
  ];

  /// 方格首行卡片数（按卡片 top 坐标分组）。
  int firstRowCount(WidgetTester tester) {
    final cards = find.byType(BookGridCard);
    final tops = [
      for (var i = 0; i < cards.evaluate().length; i++)
        tester.getTopLeft(cards.at(i)).dy,
    ];
    if (tops.isEmpty) return 0;
    final minTop = tops.reduce((a, b) => a < b ? a : b);
    return tops.where((top) => (top - minTop).abs() < 1).length;
  }

  testWidgets('宽屏：左侧品牌栏、固定卡宽与右侧留白', (tester) async {
    await pumpHomeScreen(tester, books: books, size: const Size(1400, 900));

    expect(find.byKey(kHomeRailKey), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(kHomeRailKey),
        matching: find.byType(BrandLogo),
      ),
      findsOneWidget,
    );
    // 宽屏品牌只在左栏，不再重复进顶栏。
    expect(
      find.descendant(
        of: find.byType(NarrChatAppBar),
        matching: find.byType(BrandLogo),
      ),
      findsNothing,
    );
    expect(find.byTooltip('新建书籍'), findsOneWidget);
    expect(find.byTooltip('设置'), findsOneWidget);
    expect(find.text('12 本'), findsOneWidget);
    expect(firstRowCount(tester), 8, reason: '1400 宽屏内容区应排 8 列');

    // 左栏底色必须真实延伸到顶栏左侧。
    final railColor = tester
        .widget<Container>(find.byKey(kHomeRailKey))
        .color!;
    final bar = tester.widget<NarrChatAppBar>(find.byType(NarrChatAppBar));
    expect(bar.leadingBackgroundColor, railColor);
    expect(bar.leadingBackgroundWidth, kHomeRailWidth);

    // 宽屏方格固定卡片宽度、右侧留白，间距 24。
    final cards = find.byType(BookGridCard);
    final firstCard = cards.at(0);
    final firstSize = tester.getSize(firstCard);
    expect(firstSize.width, closeTo(kBookGridWideCardWidth, 0.5));
    final firstLeft = tester.getTopLeft(firstCard).dx;
    final secondLeft = tester.getTopLeft(cards.at(1)).dx;
    expect(
      secondLeft - firstLeft,
      closeTo(kBookGridWideCardWidth + kBookGridWideSpacing, 0.5),
    );

    // 首行右侧留白：大于 0，且不足再放下一格。
    final gridRect = tester.getRect(find.byType(GridView));
    final contentRight = gridRect.right - 28; // 宽屏内容内边距
    final rowOneTop = tester.getTopLeft(firstCard).dy;
    final firstRow = [
      for (var i = 0; i < 8; i++)
        if ((tester.getTopLeft(cards.at(i)).dy - rowOneTop).abs() < 1)
          tester.getRect(cards.at(i)),
    ];
    final maxRight = firstRow
        .map((rect) => rect.right)
        .reduce((a, b) => a > b ? a : b);
    final blank = contentRight - maxRight;
    expect(blank, greaterThan(0), reason: '卡片不应拉伸铺满，右侧要留白');
    expect(
      blank,
      lessThan(kBookGridWideCardWidth + kBookGridWideSpacing),
      reason: '留白不足一格时必须还能再放下一列才留白',
    );

    // 第二行与第一行的纵向间距。
    final rowTwoTop = tester.getTopLeft(cards.at(8)).dy;
    expect(
      rowTwoTop - rowOneTop - firstSize.height,
      closeTo(kBookGridWideSpacing, 0.5),
    );

    // 加号与设置使用同一种普通图标按钮（透明底，不再用 filled 蓝底）。
    final plus = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.add),
    );
    final settings = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.settings_outlined),
    );
    expect(plus.style, isNull);
    expect(settings.style, isNull);
  });

  testWidgets('窄屏：无左栏、品牌进顶栏、动态列数', (tester) async {
    await pumpHomeScreen(tester, books: books, size: const Size(400, 800));

    expect(find.byKey(kHomeRailKey), findsNothing);
    expect(
      find.descendant(
        of: find.byType(NarrChatAppBar),
        matching: find.byType(BrandLogo),
      ),
      findsOneWidget,
    );
    expect(find.byTooltip('新建书籍'), findsOneWidget);
    expect(find.byTooltip('设置'), findsOneWidget);
    expect(firstRowCount(tester), 3, reason: '400 窄屏应排 3 列');

    // 窄屏没有左侧品牌栏，顶栏不应出现附加色条。
    final bar = tester.widget<NarrChatAppBar>(find.byType(NarrChatAppBar));
    expect(bar.leadingBackgroundColor, isNull);
    expect(bar.leadingBackgroundWidth, 0);

    // 窄屏保持紧凑间距。
    final grid = tester.widget<GridView>(find.byType(GridView));
    final delegate =
        grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    expect(delegate.crossAxisSpacing, kBookGridSpacing);
    expect(delegate.mainAxisSpacing, kBookGridSpacing);
  });

  testWidgets('深色宽屏：左栏比内容面浅，并铺到顶栏', (tester) async {
    await pumpHomeScreen(
      tester,
      books: const [Book(uuid: 'b1', title: '测试书')],
      size: const Size(1400, 900),
      theme: NarrChatTheme.dark,
    );

    final rail = tester.widget<Container>(find.byKey(kHomeRailKey));
    final railColor = rail.color!;
    expect(
      railColor.computeLuminance(),
      greaterThan(NarrChatColors.dark.surface.computeLuminance()),
      reason: '深色模式下左栏必须比右侧内容面浅',
    );

    final bar = tester.widget<NarrChatAppBar>(find.byType(NarrChatAppBar));
    expect(bar.leadingBackgroundColor, railColor);
    expect(bar.leadingBackgroundWidth, kHomeRailWidth);
    final stripFinder = find.descendant(
      of: find.byType(NarrChatAppBar),
      matching: find.byWidgetPredicate(
        (widget) => widget is ColoredBox && widget.color == railColor,
      ),
    );
    expect(
      stripFinder,
      findsOneWidget,
      reason: '顶栏左侧应真实绘制左栏底色',
    );
    final strip = tester.getRect(stripFinder);
    final barRect = tester.getRect(find.byType(NarrChatAppBar));
    final railRect = tester.getRect(find.byKey(kHomeRailKey));
    expect(strip.top, closeTo(barRect.top, 1), reason: '色条从顶栏最上沿开始');
    expect(strip.bottom, closeTo(barRect.bottom, 1), reason: '色条覆盖整个顶栏');
    expect(strip.bottom, closeTo(railRect.top, 1), reason: '与下方左栏无缝衔接');
  });

  testWidgets('点击顶栏加号弹出菜单，可进入新建书籍页', (tester) async {
    await pumpHomeScreen(tester, books: const [], size: const Size(400, 800));

    await tester.tap(find.byTooltip('新建书籍'));
    await tester.pumpAndSettle();
    expect(find.text('创建新书'), findsOneWidget);
    expect(find.text('Agent 创建新书'), findsOneWidget);

    await tester.tap(find.text('创建新书'));
    await tester.pumpAndSettle();

    expect(find.text('新建书籍'), findsOneWidget, reason: '应进入书籍创建页');
  });

  testWidgets('菜单可进入 Agent 创建新书输入页', (tester) async {
    await pumpHomeScreen(tester, books: const [], size: const Size(400, 800));

    await tester.tap(find.byTooltip('新建书籍'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Agent 创建新书'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('agent_book_idea_field')),
      findsOneWidget,
      reason: '应进入输入页（满宽 Markdown 输入框）',
    );
    expect(find.text('输入内容不会被保存，只用于本次生成'), findsOneWidget);
  });
}
