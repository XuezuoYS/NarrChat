import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config/chat_route.dart';
import '../models/book.dart';
import '../providers/book_provider.dart';
import '../providers/notification_settings_provider.dart';
import '../theme/app_theme.dart';
import '../utils/book_list_utils.dart';
import '../utils/focus_utils.dart';
import '../widgets/app_menu.dart';
import '../widgets/book_actions.dart';
import '../widgets/generation_banner.dart';
import 'book_settings_screen.dart';
import 'chat_screen.dart';

/// 首页：书籍列表。
///
/// - 搜索：按标题 / 分类过滤（空格分隔多关键词模糊匹配）；
/// - 排序：时间（最近对话）或 A-Z（拼音）；
/// - 点击书籍进入对话页；列表项菜单仅提供「删除」；
/// - 「新建书籍」打开书籍设置页（创建模式），保存后直接进入该书的对话页；
/// - 不在列表中提供任何「进入书籍设置」的入口。
class BookListScreen extends StatefulWidget {
  const BookListScreen({super.key});

  @override
  State<BookListScreen> createState() => _BookListScreenState();
}

class _BookListScreenState extends State<BookListScreen> {
  final TextEditingController _searchController = TextEditingController();
  BookSortMode _sortMode = BookSortMode.time;

  @override
  void initState() {
    super.initState();
    // 启动时确保最近对话时间就绪（loadBooks 通常已加载，此处兜底刷新）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<BookProvider>().refreshLastRoundTimes();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// 进入对话页；返回后刷新「最近对话时间」。
  Future<void> _openChat(Book book) async {
    final provider = context.read<BookProvider>();
    provider.selectBook(book);
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const ChatScreen(),
        settings: RouteSettings(name: chatRouteName, arguments: book.id),
      ),
    );
    if (!mounted) return;
    await provider.refreshLastRoundTimes();
  }

  /// 新建书籍：打开创建页，保存成功后进入该书的对话页。
  Future<void> _createBook() async {
    final saved = await BookSettingsScreen.open(context);
    if (saved != true || !mounted) return;
    final book = context.read<BookProvider>().currentBook;
    if (book == null) return;
    await _openChat(book);
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<BookProvider>();
    final filtered = filterBooks(provider.books, _searchController.text);
    final books = sortBooks(filtered, _sortMode, provider.lastRoundTimes);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildToolbar(context, provider.books.length),
            const Divider(height: 1),
            // 系统通知未开启提示（Android）：后台生成成功将无法及时收到通知。
            Consumer<NotificationSettingsProvider>(
              builder: (context, settings, _) {
                if (settings.notificationsEnabled != false) {
                  return const SizedBox.shrink();
                }
                return _buildNotificationHint(context, settings);
              },
            ),
            // 跨书进程提示栏：其他书籍正在生成时展示计数横幅，点击弹窗选择跳转。
            GenerationBanner(onOpenBook: _openChat),
            Expanded(
              child: provider.isLoading && provider.books.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : provider.books.isEmpty
                  ? _buildWelcomeEmpty(context)
                  : books.isEmpty
                  ? _buildNoMatch(context)
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                      itemCount: books.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 6),
                      itemBuilder: (context, index) =>
                          _buildBookTile(context, provider, books[index]),
                    ),
            ),
            _buildCreateButton(context),
          ],
        ),
      ),
    );
  }

  /// 系统通知未开启提示卡片（Android 检测到未开启时显示）。
  Widget _buildNotificationHint(
    BuildContext context,
    NotificationSettingsProvider settings,
  ) {
    final colors = context.narrColors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
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
                  '您没有开启系统通知，这会导致软件处于后台时，易生成失败且无法收到完成提示',
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

  /// 顶部：标题 + 搜索框 + 排序切换。
  Widget _buildToolbar(BuildContext context, int total) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                '书籍',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: context.narrColors.textPrimary,
                ),
              ),
              const Spacer(),
              Text(
                '$total 本',
                style: TextStyle(
                  fontSize: 12,
                  color: context.narrColors.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _searchController,
            onChanged: (_) => setState(() {}),
            onTapOutside: unfocusOnTapOutside,
            decoration: InputDecoration(
              hintText: '搜索书籍（名称 / 类别，空格分隔多关键词）',
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _searchController.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      tooltip: '清空搜索',
                      onPressed: () {
                        _searchController.clear();
                        setState(() {});
                      },
                    ),
              isDense: true,
              filled: true,
              fillColor: theme.colorScheme.surfaceContainerLow,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Text(
                '排序',
                style: TextStyle(
                  fontSize: 12,
                  color: context.narrColors.textSecondary,
                ),
              ),
              const SizedBox(width: 10),
              SegmentedButton<BookSortMode>(
                segments: const [
                  ButtonSegment(value: BookSortMode.time, label: Text('时间')),
                  ButtonSegment(value: BookSortMode.az, label: Text('A-Z')),
                ],
                selected: {_sortMode},
                onSelectionChanged: (s) => setState(() => _sortMode = s.first),
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 12)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 单个书籍项：点击进入对话；菜单仅「删除」。
  Widget _buildBookTile(
    BuildContext context,
    BookProvider provider,
    Book book,
  ) {
    final theme = Theme.of(context);
    final lastTime = provider.lastRoundTimes[book.id];
    return ListTile(
      // 收紧「更多操作」按钮与卡片右缘的间距（M3 默认右内边距 24 使右侧空白偏大）。
      contentPadding: const EdgeInsetsDirectional.only(start: 16, end: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      tileColor: theme.colorScheme.surfaceContainerLow,
      leading: Icon(Icons.menu_book, color: NarrChatTheme.primary, size: 20),
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
          if (lastTime != null)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Text(
                formatLastActivity(lastTime),
                style: TextStyle(
                  fontSize: 11,
                  color: context.narrColors.textSecondary,
                ),
              ),
            ),
          PopupMenuButton<String>(
            tooltip: '更多操作',
            onSelected: (value) {
              if (value == 'delete') {
                deleteBookWithConfirm(context, book);
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'delete',
                child: AppMenuAction(
                  icon: Icons.delete_outline,
                  label: '删除',
                  color: Color(0xFFE5484D),
                ),
              ),
            ],
          ),
        ],
      ),
      onTap: () => _openChat(book),
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
            '点击下方「新建书籍」开始创作',
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

  /// 底部「新建书籍」按钮。
  Widget _buildCreateButton(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: FilledButton.icon(
        onPressed: _createBook,
        icon: const Icon(Icons.add),
        label: const Text('新建书籍'),
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(46),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}
