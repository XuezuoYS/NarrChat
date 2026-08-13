import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/book.dart';
import '../providers/book_provider.dart';
import '../providers/round_provider.dart';
import '../theme/app_theme.dart';

/// 横幅最大宽度：与对话内容区宽度一致，宽屏下居中不贴边（首页受外层 720 约束自动收窄）。
const double _kContentMaxWidth = 760;

/// 跨书进程提示栏：其他书籍正在生成时置顶展示计数横幅（x本书正在生成……），
/// 点击弹出「正在生成的书」对话框，选择对应书籍后回调 [onOpenBook] 跳转。
///
/// 对话页传入 [excludeBookId]（当前查看书，其自身不显示）；首页传 null 展示全部。
class GenerationBanner extends StatelessWidget {
  const GenerationBanner({
    super.key,
    this.excludeBookId,
    this.maxWidth = _kContentMaxWidth,
    required this.onOpenBook,
  });

  /// 需要排除的书籍 id（如当前对话页的书，其自身不显示在横幅）。
  final int? excludeBookId;

  /// 横幅最大宽度（默认对齐对话内容区 760）。
  final double maxWidth;

  /// 点击对话框中的某本书时回调（由调用方执行导航）。
  final void Function(Book book) onOpenBook;

  @override
  Widget build(BuildContext context) {
    final roundProvider = context.watch<RoundProvider>();
    final activeIds = roundProvider.activeGenerationBookIds
        .where((id) => id != excludeBookId)
        .toList();
    if (activeIds.isEmpty) return const SizedBox.shrink();

    // 圆角悬浮卡片：水平居中限宽 + 四周留白，宽屏下不与窗口/容器边缘齐平（不被截断）；
    // 无阴影（Material 零高程），仅圆角背景 + 水波纹点击反馈。
    // 用 Align(heightFactor:1) 而非 Center：高度随内容自适应，不纵向撑满
    //（对话页作为悬浮覆盖层时避免占满对话区高度）。
    return Align(
      alignment: Alignment.topCenter,
      heightFactor: 1,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: Material(
            // 不透明横幅背景（主题定制色，浅色淡琥珀 / 深色深琥珀）。
            color: context.narrColors.bannerBackground,
            borderRadius: BorderRadius.circular(10),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => _showGeneratingBooksDialog(context, activeIds),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 9,
                ),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '${activeIds.length}本书正在生成……',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: context.narrColors.textPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      Icons.chevron_right,
                      size: 16,
                      color: context.narrColors.textSecondary,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 「正在生成的书」对话框：列出正在生成的书（书名 + 进度），
  /// 点击对应条目回调 [onOpenBook]。
  void _showGeneratingBooksDialog(BuildContext context, List<int> activeIds) {
    final books = context.read<BookProvider>().books;
    final entries = <Book>[];
    for (final id in activeIds) {
      final book = _bookById(books, id);
      if (book != null) entries.add(book);
    }
    if (entries.isEmpty) return;

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('正在生成的书'),
        contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        content: SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final book in entries)
                ListTile(
                  leading: const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  title: Text(
                    book.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  ),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    onOpenBook(book);
                  },
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  /// 按 id 查书（未找到返回 null）。
  Book? _bookById(List<Book> books, int id) {
    for (final b in books) {
      if (b.id == id) return b;
    }
    return null;
  }
}
