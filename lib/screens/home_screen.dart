import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/book.dart';
import '../providers/book_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/book_list_panel.dart';
import '../widgets/round_action_dialogs.dart';
import 'book_list_screen.dart';
import 'book_settings_screen.dart';
import 'chat_screen.dart';
import 'settings_screen.dart';

/// 主界面：
/// - 未选择书籍时显示书籍列表页；
/// - 已选择书籍时：
///   - 桌面端：左侧书籍栏 + 右侧对话界面（对话内部再自适应右侧状态栏）；
///   - 移动端：对话界面全屏，书籍栏为从左滑出的抽屉（AppBar 汉堡按钮呼出）。
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _bookDrawerOpen = false;

  void _openBookDrawer() => setState(() => _bookDrawerOpen = true);

  void _closeBookDrawer() => setState(() => _bookDrawerOpen = false);

  Future<void> _createBook(BuildContext context) async {
    await BookSettingsScreen.open(context);
  }

  Future<void> _editBook(BuildContext context, Book book) async {
    await BookSettingsScreen.open(context, book: book);
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

  Widget _buildBookPanel(BuildContext context, BookProvider provider) {
    return BookListPanel(
      books: provider.books,
      currentBook: provider.currentBook,
      onSelect: (book) => provider.selectBook(book),
      onCreate: () => _createBook(context),
      onEdit: (book) => _editBook(context, book),
      onDelete: (book) => _deleteBook(context, book),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bookProvider = context.watch<BookProvider>();
    final book = bookProvider.currentBook;

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 1100;
        return Scaffold(
          // 极简白色顶部：细底边 + 品牌 Logo（模仿 DeepSeek 顶部）。
          appBar: PreferredSize(
            preferredSize: const Size.fromHeight(kToolbarHeight),
            child: Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                border: Border(
                  bottom: BorderSide(color: NarrChatTheme.divider),
                ),
              ),
              child: AppBar(
                leading: (book != null && !wide)
                    ? IconButton(
                        icon: const Icon(Icons.menu),
                        tooltip: '书籍列表',
                        onPressed: _openBookDrawer,
                      )
                    : null,
                title: const _BrandTitle(),
                actions: [
                  if (book != null) ...[
                    IconButton(
                      icon: const Icon(Icons.book_outlined),
                      tooltip: '书籍设置',
                      onPressed: () =>
                          BookSettingsScreen.open(context, book: book),
                    ),
                  ],
                  IconButton(
                    icon: const Icon(Icons.settings_outlined),
                    tooltip: '设置',
                    onPressed: () => SettingsScreen.open(context),
                  ),
                ],
              ),
            ),
          ),
          body: book == null
              ? const BookListScreen()
              : wide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          width: 260,
                          child: _buildBookPanel(context, bookProvider),
                        ),
                        const VerticalDivider(width: 1),
                        Expanded(
                          child: ChatScreen(key: ValueKey(book.id)),
                        ),
                      ],
                    )
                  : _buildMobileLayout(context, bookProvider),
        );
      },
    );
  }

  /// 移动端：对话全屏 + 左滑书籍抽屉。
  Widget _buildMobileLayout(BuildContext context, BookProvider provider) {
    final book = provider.currentBook;
    return Stack(
      children: [
        Positioned.fill(
          child: ChatScreen(key: ValueKey(book?.id)),
        ),
        if (_bookDrawerOpen)
          Positioned.fill(
            child: GestureDetector(
              onTap: _closeBookDrawer,
              child: Container(color: Colors.black26),
            ),
          ),
        AnimatedPositioned(
          // 固定 key：避免遮罩条件渲染导致元素索引变化而重建、丢失动画。
          key: const Key('left_book_drawer'),
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          top: 0,
          bottom: 0,
          left: _bookDrawerOpen ? 0 : -280,
          width: 280,
          child: Material(
            elevation: 12,
            child: SafeArea(
              right: false,
              child: _buildBookPanel(context, provider),
            ),
          ),
        ),
      ],
    );
  }
}

/// 顶部品牌标题：渐变 Logo 方块 + 「NarrChat」文字（模仿 DeepSeek 头部）。
class _BrandTitle extends StatelessWidget {
  const _BrandTitle();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            gradient: NarrChatTheme.brandGradient,
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Icon(
            Icons.auto_awesome,
            size: 16,
            color: Colors.white,
          ),
        ),
        const SizedBox(width: 10),
        const Text(
          'NarrChat',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: NarrChatTheme.textPrimary,
          ),
        ),
      ],
    );
  }
}
