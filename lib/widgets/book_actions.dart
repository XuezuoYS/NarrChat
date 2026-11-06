import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/book.dart';
import '../providers/book_provider.dart';
import '../providers/round_provider.dart';
import 'app_notice_overlay.dart';
import 'round_action_dialogs.dart';

/// 删除书籍统一入口：确认 → 输入书名最后确认 → 删除 → 失败提示。
///
/// 供 [HomeScreen] 与 [BookListScreen] 共用，避免删除逻辑重复。
Future<void> deleteBookWithConfirm(BuildContext context, Book book) async {
  final ok = await showDeleteBookConfirmDialog(context, book.title);
  if (!ok || !context.mounted) return;
  // 第三道确认：逐字输入书名（可一键填入）后才能正式删除。
  final typed = await showDeleteBookFinalConfirmDialog(context, book.title);
  if (!typed || !context.mounted) return;
  // 先中断这本书正在跑的生成：否则晚到的提交可能把刚删掉的书库写回来。
  context.read<RoundProvider?>()?.cancelGeneration(bookUuid: book.uuid);
  final provider = context.read<BookProvider>();
  final result = await provider.deleteBook(book);
  if (!result && context.mounted) {
    context.notices.error('删除失败：${provider.error}');
  }
}
