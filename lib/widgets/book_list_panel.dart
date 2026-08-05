import 'package:flutter/material.dart';

import '../models/book.dart';

/// 左侧书籍列表栏。
///
/// 展示全部书籍、当前选中高亮、新建/编辑/删除入口。
/// 桌面端固定显示在左侧；移动端作为左抽屉（由父级控制显隐）。
class BookListPanel extends StatelessWidget {
  final List<Book> books;
  final Book? currentBook;
  final ValueChanged<Book> onSelect;
  final VoidCallback onCreate;
  final ValueChanged<Book> onEdit;
  final ValueChanged<Book> onDelete;

  const BookListPanel({
    super.key,
    required this.books,
    required this.currentBook,
    required this.onSelect,
    required this.onCreate,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 使用 Material 提供正确的 Material 祖先，确保 ListTile 选中背景可见。
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(5),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    Icons.library_books_outlined,
                    size: 16,
                    color: theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    '书籍',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                  ),
                ),
                IconButton(
                  onPressed: onCreate,
                  icon: const Icon(Icons.add),
                  tooltip: '新建书籍',
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
          Divider(height: 1, color: theme.colorScheme.outlineVariant),
          Expanded(
            child: books.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.menu_book_outlined,
                            size: 40, color: theme.colorScheme.outlineVariant),
                        const SizedBox(height: 8),
                        Text(
                          '暂无书籍\n点击右上角 + 新建',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: theme.colorScheme.outline,
                            fontSize: 13,
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    itemCount: books.length,
                    itemBuilder: (context, index) {
                      final book = books[index];
                      final selected = currentBook?.id == book.id;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: ListTile(
                          selected: selected,
                          selectedTileColor:
                              theme.colorScheme.primaryContainer.withValues(alpha: 0.45),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          contentPadding:
                              const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                          leading: Icon(
                            Icons.menu_book,
                            size: 20,
                            color: selected
                                ? theme.colorScheme.primary
                                : theme.colorScheme.outline,
                          ),
                          title: Text(
                            book.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                            ),
                          ),
                          subtitle: Text(
                            book.category.isEmpty ? '未设置类别' : book.category,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                          trailing: PopupMenuButton<String>(
                            tooltip: '更多操作',
                            onSelected: (value) {
                              switch (value) {
                                case 'edit':
                                  onEdit(book);
                                case 'delete':
                                  onDelete(book);
                              }
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem(value: 'edit', child: Text('编辑')),
                              PopupMenuItem(value: 'delete', child: Text('删除')),
                            ],
                          ),
                          onTap: () => onSelect(book),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
