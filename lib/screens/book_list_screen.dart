import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/book.dart';
import '../providers/book_provider.dart';
import '../providers/notification_settings_provider.dart';
import '../theme/app_theme.dart';
import '../utils/book_list_utils.dart';
import '../widgets/app_menu.dart';
import '../widgets/book_actions.dart';
import '../widgets/book_cover.dart';
import '../widgets/book_grid_card.dart';
import '../widgets/book_list_toolbar.dart';
import 'home_navigation.dart';
import 'settings_screen.dart';

/// 首页：书籍列表。
///
/// - 搜索：按标题 / 分类过滤（空格分隔多关键词模糊匹配）；
/// - 排序：更新时间（默认，取 `book_meta.updated_at`）或 A-Z（拼音）；
/// - 排列：方格（默认）或列表；
/// - 方格卡片：默认封面（2:3）+ 最多三行标题 + 灰色分类；
/// - 点击书籍进入对话页；方格长按 / 右键、列表「更多操作」都只提供「删除」；
/// - 「新建书籍」入口在首页顶栏的加号。
class BookListScreen extends StatefulWidget {
  /// 是否处于宽屏（左侧已由 [HomeScreen] 放置品牌栏）。
  ///
  /// 只影响内容内边距，不决定是否显示顶栏 / 左栏。
  final bool wide;

  const BookListScreen({super.key, this.wide = false});

  @override
  State<BookListScreen> createState() => _BookListScreenState();
}

class _BookListScreenState extends State<BookListScreen> {
  final TextEditingController _searchController = TextEditingController();
  BookSortMode _sortMode = BookSortMode.time;
  BookLayoutMode _layoutMode = BookLayoutMode.grid;

  @override
  void initState() {
    super.initState();
    // 启动时兜底刷新一次更新时间（loadBooks 通常已加载；内容变更后回到首页
    // 还会再刷新一次）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<BookProvider>().refreshTimes();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<BookProvider>();
    final filtered = filterBooks(provider.books, _searchController.text);
    final books = sortBooks(filtered, _sortMode, provider.updatedTimes);
    final horizontal = widget.wide ? 28.0 : 16.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        BookListToolbar(
          searchController: _searchController,
          onSearchChanged: (_) => setState(() {}),
          sortMode: _sortMode,
          onSortChanged: (mode) => setState(() => _sortMode = mode),
          layoutMode: _layoutMode,
          onLayoutChanged: (mode) => setState(() => _layoutMode = mode),
          bookCount: provider.books.length,
          onOpenSyncSettings: () => SettingsScreen.open(
            context,
            initialIndex: SettingsScreen.pageIndexCloudSync,
          ),
          horizontalPadding: horizontal,
        ),
        // 第三行：通知异常提示（安卓通知未开启 / 生成完成渠道被关）。
        Consumer<NotificationSettingsProvider>(
          builder: (context, settings, _) {
            final message = _notificationHintMessage(settings);
            if (message == null) return const SizedBox.shrink();
            return _buildNotificationHint(
              context,
              settings,
              message: message,
              horizontalPadding: horizontal,
            );
          },
        ),
        Expanded(child: _buildBody(context, provider, books, horizontal)),
      ],
    );
  }

  /// 通知异常提示文案；无异常返回 null。
  String? _notificationHintMessage(NotificationSettingsProvider settings) {
    if (settings.notificationsEnabled == false) {
      return '您没有开启系统通知，这会导致软件处于后台时，易生成失败且无法收到完成提示';
    }
    // 通知总开关开着，但生成完成渠道的悬浮通知 / 铃声被系统侧关闭。
    final channel = settings.generationDoneChannelState;
    if (channel == null || channel.fullyEnabled) return null;
    final disabled = [
      if (!channel.headsUp) '悬浮通知',
      if (!channel.sound) '通知铃声',
    ].join('、');
    return '生成完成通知的$disabled已被关闭，软件处于后台时，生成完成将无法及时提醒您';
  }

  /// 内容区：加载中 / 空库 / 搜索无结果 / 方格 / 列表。
  Widget _buildBody(
    BuildContext context,
    BookProvider provider,
    List<Book> books,
    double horizontal,
  ) {
    if (provider.isLoading && provider.books.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (provider.books.isEmpty) return _buildWelcomeEmpty(context);
    if (books.isEmpty) return _buildNoMatch(context);
    return _layoutMode == BookLayoutMode.grid
        ? _buildGrid(context, books, horizontal)
        : _buildList(context, provider, books, horizontal);
  }

  /// 方格排列：列数随视口宽度动态计算，封面固定 2:3。
  Widget _buildGrid(
    BuildContext context,
    List<Book> books,
    double horizontal,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final contentWidth = constraints.maxWidth - horizontal * 2;
        if (contentWidth <= 0) return const SizedBox.shrink();
        final columns = bookGridColumns(contentWidth);
        final cardWidth =
            (contentWidth - (columns - 1) * kBookGridSpacing) / columns;
        final extent = bookGridItemExtent(
          cardWidth,
          MediaQuery.textScalerOf(context),
        );
        return GridView.builder(
          padding: EdgeInsets.fromLTRB(horizontal, 12, horizontal, 24),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: kBookGridSpacing,
            mainAxisSpacing: kBookGridSpacing,
            mainAxisExtent: extent,
          ),
          itemCount: books.length,
          itemBuilder: (context, index) {
            final book = books[index];
            return BookGridCard(
              key: ValueKey('book_card_${book.uuid}'),
              book: book,
              onTap: () => openHomeChat(context, book),
              onContextMenu: (position) => _showBookMenu(book, position),
            );
          },
        );
      },
    );
  }

  /// 列表排列：沿用原 ListTile 样式，左侧补 2:3 封面缩略图。
  Widget _buildList(
    BuildContext context,
    BookProvider provider,
    List<Book> books,
    double horizontal,
  ) {
    return ListView.separated(
      padding: EdgeInsets.fromLTRB(horizontal, 12, horizontal, 16),
      itemCount: books.length,
      separatorBuilder: (_, _) => const SizedBox(height: 6),
      itemBuilder: (context, index) =>
          _buildBookTile(context, provider, books[index]),
    );
  }

  /// 单个书籍项：点击进入对话；菜单仅「删除」。
  Widget _buildBookTile(
    BuildContext context,
    BookProvider provider,
    Book book,
  ) {
    final theme = Theme.of(context);
    final updatedAt = provider.updatedTimes[book.uuid];
    return ListTile(
      key: ValueKey('book_row_${book.uuid}'),
      // 收紧「更多操作」按钮与卡片右缘的间距（M3 默认右内边距 24 使右侧空白偏大）。
      contentPadding: const EdgeInsetsDirectional.only(start: 16, end: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      tileColor: theme.colorScheme.surfaceContainerLow,
      leading: BookCover(width: 36, radius: 8),
      title: Text(
        book.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: context.narrColors.textPrimary,
        ),
      ),
      subtitle: Text(
        book.category.isEmpty ? '未设置类别' : book.category,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (updatedAt != null)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Text(
                formatLastActivity(updatedAt),
                style: TextStyle(
                  fontSize: 11,
                  color: context.narrColors.textSecondary,
                ),
              ),
            ),
          PopupMenuButton<String>(
            tooltip: '更多操作',
            onSelected: (value) {
              if (value == bookMenuDelete) {
                deleteBookWithConfirm(context, book);
              }
            },
            itemBuilder: (_) => bookMenuEntries(),
          ),
        ],
      ),
      onTap: () => openHomeChat(context, book),
    );
  }

  /// 方格卡片的右键 / 长按菜单：与列表共用同一套删除项。
  Future<void> _showBookMenu(Book book, Offset position) async {
    final action = await showAppMenu<String>(
      context: context,
      position: position,
      items: bookMenuEntries(),
    );
    if (action != bookMenuDelete || !mounted) return;
    await deleteBookWithConfirm(context, book);
  }

  /// 通知异常提示卡片（第三行）。
  Widget _buildNotificationHint(
    BuildContext context,
    NotificationSettingsProvider settings, {
    required String message,
    required double horizontalPadding,
  }) {
    final colors = context.narrColors;
    return Padding(
      padding: EdgeInsets.fromLTRB(horizontalPadding, 10, horizontalPadding, 0),
      child: Material(
        color: colors.bannerBackground,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
          child: Row(
            children: [
              Icon(
                Icons.notifications_off_outlined,
                size: 18,
                color: colors.warning,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(fontSize: 12.5, color: colors.textPrimary),
                ),
              ),
              TextButton(
                onPressed: () => settings.openSettings(),
                child: Text(
                  '去开启',
                  style: TextStyle(fontSize: 12.5, color: colors.warning),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 无任何书籍时的欢迎空态。
  Widget _buildWelcomeEmpty(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.auto_stories_outlined,
            size: 56,
            color: NarrChatTheme.primary.withValues(alpha: 0.35),
          ),
          const SizedBox(height: 12),
          Text(
            '还没有书籍',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: context.narrColors.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '点击右上角 + 新建你的第一本书',
            style: TextStyle(
              fontSize: 13,
              color: context.narrColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  /// 搜索无结果时的空态。
  Widget _buildNoMatch(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.search_off,
            size: 48,
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
          const SizedBox(height: 12),
          Text(
            '未找到匹配的书籍',
            style: TextStyle(
              fontSize: 13,
              color: context.narrColors.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () {
              _searchController.clear();
              setState(() {});
            },
            child: const Text('清空搜索'),
          ),
        ],
      ),
    );
  }
}
