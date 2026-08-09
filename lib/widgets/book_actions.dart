import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/book.dart';
import '../providers/book_provider.dart';
import 'round_action_dialogs.dart';

/// 删除书籍统一入口：二次确认 → 删除 → 失败提示。
///
/// 供 [HomeScreen] 与 [BookListScreen] 共用，避免删除逻辑重复。
Future<void> deleteBookWithConfirm(BuildContext context, Book book) async {
  final ok = await showDeleteBookConfirmDialog(context, book.title);
  if (!ok || !context.mounted) return;
  final provider = context.read<BookProvider>();
  final result = await provider.deleteBook(book);
  if (!result && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('删除失败：${provider.error}')),
    );
  }
}
