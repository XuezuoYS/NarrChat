import 'package:flutter/material.dart';

import '../models/book.dart';
import '../theme/app_theme.dart';

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
      color: Colors.white,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 顶部标题
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                const Text(
                  '书籍',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: NarrChatTheme.textPrimary,
                  ),
                ),
                const Spacer(),
                Text(
                  '${books.length} 本',
                  style: const TextStyle(
                    fontSize: 12,
                    color: NarrChatTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          // “新建书籍”按钮（模仿 DeepSeek「开始新对话」）
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
            child: Material(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(10),
              child: InkWell(
                onTap: onCreate,
                borderRadius: BorderRadius.circular(10),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Row(
                    children: [
                      Icon(
                        Icons.add,
                        size: 18,
                        color: NarrChatTheme.textPrimary,
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        '新建书籍',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: NarrChatTheme.textPrimary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Divider(height: 1, color: NarrChatTheme.divider),
          Expanded(
            child: books.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.menu_book_outlined,
                            size: 36, color: theme.colorScheme.outlineVariant),
                        const SizedBox(height: 8),
                        Text(
                          '暂无书籍，点击上方「新建书籍」创建',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: NarrChatTheme.textSecondary,
                            fontSize: 13,
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    itemCount: books.length,
                    itemBuilder: (context, index) {
                      final book = books[index];
                      final selected = currentBook?.id == book.id;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: ListTile(
                          selected: selected,
                          selectedTileColor: theme.colorScheme.surfaceContainer,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          contentPadding:
                              const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                          leading: Icon(
                            Icons.menu_book,
                            size: 18,
                            color: selected
                                ? NarrChatTheme.primary
                                : NarrChatTheme.textSecondary,
                          ),
                          title: Text(
                            book.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                              color: selected
                                  ? NarrChatTheme.textPrimary
                                  : NarrChatTheme.textPrimary,
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
