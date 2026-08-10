import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/database/book_dao.dart';
import 'package:narrchat/database/round_dao.dart';
import 'package:narrchat/database/world_book_dao.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/failed_attempt.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/models/world_book_entry.dart';
import 'package:narrchat/providers/book_provider.dart';
import 'package:narrchat/providers/round_provider.dart';
import 'package:narrchat/providers/sidebar_provider.dart';
import 'package:narrchat/providers/world_book_provider.dart';
import 'package:narrchat/screens/chat_screen.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/utils/focus_utils.dart';
import 'package:provider/provider.dart';

/// 内存版 DAO，避免测试依赖 sqflite（仅覆盖加载所需方法）。
class _MockBookDao extends BookDao {
  final List<Book> books;
  _MockBookDao(this.books);
  @override
  Future<List<Book>> getAllBooks() async => books;
  @override
  Future<FailedAttempt> getFailedAttempt(int bookId) async =>
      const FailedAttempt();
}

class _MockRoundDao extends RoundDao {
  @override
  Future<List<Round>> getRoundsByBook(int bookId) async => [];
}

class _MockWorldBookDao extends WorldBookDao {
  @override
  Future<List<WorldBookEntry>> getEntriesByBook(int bookId) async => [];
}

void main() {
  group('onTapOutside 共享工具', () {
    testWidgets('点击输入框外部取消焦点（触屏平台）', (tester) async {
      // 模拟触屏平台（Android）：Flutter 默认在此平台不会点击外部取消焦点，
      // 修复后应通过显式 onTapOutside 取消。
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      final controller = TextEditingController();
      addTearDown(controller.dispose);
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                TextField(
                  controller: controller,
                  focusNode: focusNode,
                  onTapOutside: unfocusOnTapOutside,
                ),
                const Spacer(),
              ],
            ),
          ),
        ),
      );

      // 点击输入框内部 → 正常聚焦。
      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(focusNode.hasFocus, isTrue);

      // 点击输入框外部（空白区域）→ 焦点被取消（光标停止闪烁）。
      await tester.tapAt(const Offset(200, 400));
      await tester.pump();
      expect(focusNode.hasFocus, isFalse);

      // 再次点击输入框内部 → 仍可正常重新聚焦（回归保护：不误拦截框内点击）。
      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(focusNode.hasFocus, isTrue);

      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('聊天主输入框', () {
    Future<void> pumpNarrowChat(WidgetTester tester) async {
      tester.view.physicalSize = const Size(600, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const book = Book(id: 1, title: '测试书');
      final bookDao = _MockBookDao([book]);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider(
              create: (_) => BookProvider(dao: bookDao)..loadBooks(),
            ),
            ChangeNotifierProvider(
              create: (_) => WorldBookProvider(dao: _MockWorldBookDao()),
            ),
            ChangeNotifierProvider(
              create: (_) => RoundProvider(dao: _MockRoundDao(), bookDao: bookDao),
            ),
            ChangeNotifierProvider(create: (_) => SidebarProvider()),
          ],
          child: MaterialApp(
            theme: NarrChatTheme.light,
            home: Scaffold(body: const ChatScreen()),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    /// 聊天主输入框（通过 hint 定位，避免误匹配侧边栏抽屉内的编辑框）。
    Finder chatInput() => find.widgetWithText(TextField, '输入你的行动或对话…');

    bool chatInputHasFocus(WidgetTester tester) {
      final editable = tester.widget<EditableText>(
        find.descendant(of: chatInput(), matching: find.byType(EditableText)),
      );
      return editable.focusNode.hasFocus;
    }

    testWidgets('触屏：聚焦后点击消息区空白处，输入框取消焦点', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await pumpNarrowChat(tester);

      // 点击输入框内部 → 聚焦（光标开始闪烁）。
      await tester.tap(chatInput());
      await tester.pump();
      expect(chatInputHasFocus(tester), isTrue);

      // 点击消息区空白处（输入框外部）→ 取消焦点（光标停止闪烁）。
      await tester.tapAt(const Offset(100, 300));
      await tester.pump();
      expect(chatInputHasFocus(tester), isFalse);

      // 再次点击输入框 → 可正常重新聚焦。
      await tester.tap(chatInput());
      await tester.pump();
      expect(chatInputHasFocus(tester), isTrue);

      debugDefaultTargetPlatformOverride = null;
    });
  });
}
