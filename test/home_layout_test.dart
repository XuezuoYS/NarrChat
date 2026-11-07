import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/screens/home_screen.dart';
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

  testWidgets('宽屏：左侧品牌栏、顶栏两个动作、动态多列', (tester) async {
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
    expect(find.text('7 本'), findsOneWidget);
    expect(firstRowCount(tester), 6, reason: '1400 宽屏内容区应排 6 列');
  });

  testWidgets('窄屏：无左栏、品牌进顶栏、两列方格', (tester) async {
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
    expect(firstRowCount(tester), 2, reason: '400 窄屏应排 2 列');
  });

  testWidgets('点击顶栏加号打开「新建书籍」页', (tester) async {
    await pumpHomeScreen(tester, books: const [], size: const Size(400, 800));

    await tester.tap(find.byTooltip('新建书籍'));
    await tester.pumpAndSettle();

    expect(find.text('新建书籍'), findsOneWidget, reason: '应进入书籍创建页');
  });
}
