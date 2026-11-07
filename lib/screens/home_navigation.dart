import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config/chat_route.dart';
import '../models/book.dart';
import '../providers/book_provider.dart';
import 'book_settings_screen.dart';
import 'chat_screen.dart';

/// 从首页进入某本书的对话页；返回后刷新首页「更新时间」。
///
/// 首页方格卡片点击与「新建书籍」保存后的跳转共用，避免两处各写一遍
/// 「选中 → push → 返回刷新」链路。
Future<void> openHomeChat(BuildContext context, Book book) async {
  final provider = context.read<BookProvider>();
  provider.selectBook(book);
  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => const ChatScreen(),
      settings: RouteSettings(name: chatRouteName, arguments: book.uuid),
    ),
  );
  await provider.refreshTimes();
}

/// 首页「新建书籍」：打开创建页，保存成功后直接进入新书的对话页。
Future<void> createHomeBook(BuildContext context) async {
  final saved = await BookSettingsScreen.open(context);
  if (saved != true || !context.mounted) return;
  final book = context.read<BookProvider>().currentBook;
  if (book == null) return;
  await openHomeChat(context, book);
}
