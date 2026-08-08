import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/book.dart';
import '../providers/book_provider.dart';
import '../widgets/round_action_dialogs.dart';
import 'book_settings_screen.dart';

/// 书籍列表页（无书籍时的欢迎/创建入口，以及 AppBar 中的快速切换列表）。
class BookListScreen extends StatelessWidget {
  const BookListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final bookProvider = context.watch<BookProvider>();
    final books = bookProvider.books;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Column(
          children: [
            const SizedBox(height: 24),
            Icon(Icons.auto_stories_outlined, size: 56, color: Colors.deepPurple.shade200),
            const SizedBox(height: 8),
            const Text(
              'NarrChat',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              '你的 AI 叙事交互引擎',
              style: TextStyle(color: Colors.grey.shade600),
            ),
            const SizedBox(height: 24),
            Expanded(
              child: books.isEmpty
                  ? Center(
                      child: Text(
                        '还没有书籍，点击下方“新建书籍”开始创作',
                        style: TextStyle(color: Colors.grey.shade600),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: books.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final book = books[index];
                        final selected = bookProvider.currentBook?.id == book.id;
                        return ListTile(
                          leading: Icon(
                            Icons.menu_book,
                            color: selected ? Colors.deepPurple : Colors.grey,
                          ),
                          title: Text(book.title),
                          subtitle: Text(
                            book.category.isEmpty ? '未设置类别' : book.category,
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.edit_outlined, size: 20),
                                tooltip: '编辑',
                                onPressed: () =>
                                    BookSettingsScreen.open(context, book: book),
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline, size: 20),
                                tooltip: '删除',
                                onPressed: () => _deleteBook(context, book),
                              ),
                            ],
                          ),
                          onTap: () => bookProvider.selectBook(book),
                        );
                      },
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton.icon(
                onPressed: () => BookSettingsScreen.open(context),
                icon: const Icon(Icons.add),
                label: const Text('新建书籍'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteBook(BuildContext context, Book book) async {
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
}
