import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/providers/book_provider.dart';
import 'package:narrchat/providers/cloud_sync_provider.dart';
import 'package:narrchat/providers/mod_provider.dart';
import 'package:narrchat/providers/world_book_provider.dart';
import 'package:narrchat/screens/book_settings_screen.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:provider/provider.dart';

import 'helpers/fakes.dart';

void main() {
  late FakeBookDao dao;
  late BookProvider bookProvider;

  setUp(() async {
    dao = FakeBookDao(books: [
      const Book(
        id: 1,
        title: '当前标题',
        category: '当前分类',
        baseSetting: '当前设定',
      ),
    ]);
    bookProvider = BookProvider(dao: dao);
    await bookProvider.loadBooks();
  });

  /// 以编辑模式 pump 书籍设置页（可注入一个"陈旧"的 Book 快照，模拟调用方持有旧实例）。
  Future<void> pumpSettings(WidgetTester tester, {Book? book}) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: bookProvider),
          ChangeNotifierProvider(
            create: (_) => WorldBookProvider(dao: FakeWorldBookDao()),
          ),
          ChangeNotifierProvider(
            create: (_) => ModProvider(dao: FakeModDao()),
          ),
          ChangeNotifierProvider(create: (_) => CloudSyncProvider()),
        ],
        child: MaterialApp(
          theme: NarrChatTheme.light,
          home: BookSettingsScreen(book: book),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('打开时以 Provider 最新实例为准：陈旧快照不决定展示值', (tester) async {
    // 库中已有最新设置（模拟云同步落地后重载过）。
    dao.books[0] = dao.books[0].copyWith(title: '云端新标题', category: '云端新分类');
    await bookProvider.loadBooks();

    // 调用方传入陈旧快照（同步落地前打开的对话页遗留引用）。
    await pumpSettings(
      tester,
      book: const Book(id: 1, title: '陈旧标题', category: '旧分类'),
    );

    expect(find.widgetWithText(TextField, '云端新标题'), findsOneWidget,
        reason: '打开即解析 Provider 最新实例');
    expect(find.widgetWithText(TextField, '云端新分类'), findsOneWidget);
    expect(find.widgetWithText(TextField, '陈旧标题'), findsNothing);
  });

  testWidgets('打开期间远端设置落地：未编辑字段即时刷新，已编辑字段保留草稿', (tester) async {
    await pumpSettings(tester, book: bookProvider.currentBook);

    // 用户正在编辑「书籍总类别」。
    await tester.enterText(
      find.widgetWithText(TextField, '当前分类'),
      '用户草稿',
    );
    await tester.pump();
    expect(find.widgetWithText(TextField, '用户草稿'), findsOneWidget);

    // 云同步落地：标题 / 分类均被远端修改。
    dao.books[0] = dao.books[0].copyWith(
      title: '远端新标题',
      category: '远端新分类',
    );
    await bookProvider.loadBooks();
    await tester.pump();

    expect(find.widgetWithText(TextField, '远端新标题'), findsOneWidget,
        reason: '未编辑字段跟随远端最新值');
    expect(find.widgetWithText(TextField, '用户草稿'), findsOneWidget,
        reason: '用户编辑中的字段保留草稿');
    expect(find.widgetWithText(TextField, '远端新分类'), findsNothing);

    // 再次落地：已编辑字段仍不被覆盖。
    dao.books[0] = dao.books[0].copyWith(title: '远端标题2');
    await bookProvider.loadBooks();
    await tester.pump();

    expect(find.widgetWithText(TextField, '远端标题2'), findsOneWidget);
    expect(find.widgetWithText(TextField, '用户草稿'), findsOneWidget);
  });
}
