import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config/chat_route.dart';
import '../models/book.dart';
import '../providers/book_provider.dart';
import 'agent_book_creation_page.dart';
import 'book_settings_screen.dart';
import 'chat_screen.dart';

/// 从首页进入某本书的对话页；返回后刷新首页「更新时间」。
///
/// 首页方格卡片点击与「新建书籍」保存后的跳转共用，避免两处各写一遍
/// 「选中 → push → 返回刷新」链路。
///
/// [replace] 为 true 时用对话页**替换当前路由**（一句话创建流程成功后，
/// 从创建页直接换成新书聊天页，返回时回到首页，不留半路页面）。
Future<void> openHomeChat(
  BuildContext context,
  Book book, {
  bool replace = false,
}) async {
  final provider = context.read<BookProvider>();
  provider.selectBook(book);
  final route = MaterialPageRoute<void>(
    builder: (_) => const ChatScreen(),
    settings: RouteSettings(name: chatRouteName, arguments: book.uuid),
  );
  if (replace) {
    await Navigator.of(context).pushReplacement(route);
  } else {
    await Navigator.of(context).push(route);
  }
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

/// 首页「Agent 创建新书」：进入一句话创建流程。
///
/// 流程页自己负责「成功 → 书籍设置 → 新书聊天页」的后续导航。
Future<void> createHomeBookWithAgent(BuildContext context) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => const AgentBookCreationPage(),
    ),
  );
}
