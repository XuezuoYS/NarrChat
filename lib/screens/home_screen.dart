import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/book_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/book_actions.dart';
import '../widgets/book_list_panel.dart';
import '../widgets/brand_logo.dart';
import 'book_list_screen.dart';
import 'book_settings_screen.dart';
import 'chat_screen.dart';
import 'settings_screen.dart';

/// 宽屏（桌面端）断点：宽度 ≥ 此值时显示左侧书籍栏。
const double _kWideBreakpoint = 1100;

/// 桌面端左侧书籍栏宽度。
const double _kBookPanelWidth = 260;

/// 移动端书籍抽屉宽度。
const double _kBookDrawerWidth = 280;

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

  Widget _buildBookPanel(BuildContext context, BookProvider provider) {
    return BookListPanel(
      books: provider.books,
      currentBook: provider.currentBook,
      onSelect: (book) => provider.selectBook(book),
      onCreate: () => BookSettingsScreen.open(context),
      onEdit: (book) => BookSettingsScreen.open(context, book: book),
      onDelete: (book) => deleteBookWithConfirm(context, book),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bookProvider = context.watch<BookProvider>();
    final book = bookProvider.currentBook;

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= _kWideBreakpoint;
        return Scaffold(
          // 极简白色顶部：细底边 + 品牌 Logo（模仿 DeepSeek 顶部）。
          appBar: PreferredSize(
            preferredSize: const Size.fromHeight(kToolbarHeight),
            child: Container(
              decoration: BoxDecoration(
                color: context.narrColors.surface,
                border: Border(
                  bottom: BorderSide(color: context.narrColors.divider),
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
                title: const BrandLogo(title: 'NarrChat'),
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
                          width: _kBookPanelWidth,
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
          left: _bookDrawerOpen ? 0 : -_kBookDrawerWidth,
          width: _kBookDrawerWidth,
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
