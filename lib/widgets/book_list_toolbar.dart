import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/cloud_sync_provider.dart';
import '../theme/app_theme.dart';
import '../utils/book_list_utils.dart';
import '../utils/focus_utils.dart';
import 'sync_status_chip.dart';

/// 紧凑分段按钮样式（排序 / 排列双选框共用）。
const ButtonStyle _kSegmentStyle = ButtonStyle(
  visualDensity: VisualDensity.compact,
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  minimumSize: WidgetStatePropertyAll(Size(0, 36)),
  padding: WidgetStatePropertyAll(
    EdgeInsets.symmetric(horizontal: 10, vertical: 4),
  ),
  textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 12)),
);

/// 首页顶部工具栏（两行）。
///
/// - 第一行：左搜索框，右「更新时间 / A-Z」双选排序；
/// - 第二行：左云同步胶囊 + 书籍计数，右「方格 / 列表」双选排列。
///
/// 通知异常提示条不在这里：它由 `BookListScreen` 作为第三行渲染。
class BookListToolbar extends StatelessWidget {
  final TextEditingController searchController;
  final ValueChanged<String> onSearchChanged;
  final BookSortMode sortMode;
  final ValueChanged<BookSortMode> onSortChanged;
  final BookLayoutMode layoutMode;
  final ValueChanged<BookLayoutMode> onLayoutChanged;

  /// 书籍总数（不受搜索过滤影响）。
  final int bookCount;

  /// 点击同步胶囊（进入设置 → 云同步）。
  final VoidCallback onOpenSyncSettings;

  /// 内容区左右内边距（宽屏 28 / 窄屏 16）。
  final double horizontalPadding;

  const BookListToolbar({
    super.key,
    required this.searchController,
    required this.onSearchChanged,
    required this.sortMode,
    required this.onSortChanged,
    required this.layoutMode,
    required this.onLayoutChanged,
    required this.bookCount,
    required this.onOpenSyncSettings,
    required this.horizontalPadding,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    // 只在「云同步是否已配置」变化时重建；同步进度文案由 SyncStatusChip 自己监听。
    final syncConfigured = context.select<CloudSyncProvider, bool>(
      (provider) => provider.isConfigured,
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(horizontalPadding, 16, horizontalPadding, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: _buildSearch(context),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              _buildSort(),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 10,
                  runSpacing: 4,
                  children: [
                    if (syncConfigured)
                      SyncStatusChip(onTap: onOpenSyncSettings),
                    Text(
                      '$bookCount 本',
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _buildLayout(),
            ],
          ),
        ],
      ),
    );
  }

  /// 胶囊搜索框：放大镜 + 可清空，支持多关键词。
  Widget _buildSearch(BuildContext context) {
    final colors = context.narrColors;
    return TextField(
      controller: searchController,
      onChanged: onSearchChanged,
      onTapOutside: unfocusOnTapOutside,
      textInputAction: TextInputAction.search,
      style: TextStyle(fontSize: 13.5, color: colors.textPrimary),
      decoration: InputDecoration(
        hintText: '搜索书名 / 分类（空格分隔）',
        prefixIcon: const Icon(Icons.search, size: 20),
        prefixIconConstraints: const BoxConstraints(
          minWidth: 40,
          minHeight: 40,
        ),
        suffixIcon: searchController.text.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.clear, size: 18),
                tooltip: '清空搜索',
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  searchController.clear();
                  onSearchChanged('');
                },
              ),
        suffixIconConstraints: const BoxConstraints(
          minWidth: 40,
          minHeight: 40,
        ),
        isDense: true,
        filled: true,
        fillColor: Theme.of(context).colorScheme.surfaceContainer,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 10,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(999),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(999),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(999),
          borderSide: const BorderSide(
            color: NarrChatTheme.primary,
            width: 1.2,
          ),
        ),
      ),
    );
  }

  /// 排序双选框：更新时间（默认）/ A-Z。
  Widget _buildSort() {
    return SegmentedButton<BookSortMode>(
      segments: [
        for (final mode in BookSortMode.values)
          ButtonSegment(value: mode, label: Text(mode.label)),
      ],
      selected: {sortMode},
      showSelectedIcon: false,
      onSelectionChanged: (selection) => onSortChanged(selection.first),
      style: _kSegmentStyle,
    );
  }

  /// 排列双选框：方格（默认）/ 列表。
  Widget _buildLayout() {
    return SegmentedButton<BookLayoutMode>(
      segments: const [
        ButtonSegment(
          value: BookLayoutMode.grid,
          icon: Icon(Icons.grid_view_rounded, size: 18),
          tooltip: '方格排列',
        ),
        ButtonSegment(
          value: BookLayoutMode.list,
          icon: Icon(Icons.view_list_rounded, size: 18),
          tooltip: '列表排列',
        ),
      ],
      selected: {layoutMode},
      showSelectedIcon: false,
      onSelectionChanged: (selection) => onLayoutChanged(selection.first),
      style: _kSegmentStyle,
    );
  }
}
