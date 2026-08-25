import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 通用分页条：展示总行数与当前页码，并提供上一页/下一页。
///
/// 与业务解耦，任何需要「按页加载」的列表均可复用：
/// - [page]：当前页（0 基）；
/// - [pageSize]：每页行数；
/// - [totalCount]：总行数（用于计算总页数）；
/// - [onPageChanged]：用户翻页时回调新的页号；
/// - [loading]：加载中时禁用翻页。
class PaginationBar extends StatelessWidget {
  const PaginationBar({
    super.key,
    required this.page,
    required this.pageSize,
    required this.totalCount,
    required this.onPageChanged,
    this.loading = false,
  });

  final int page;
  final int pageSize;
  final int totalCount;
  final ValueChanged<int> onPageChanged;
  final bool loading;

  int get _totalPages => pageSize <= 0 ? 0 : (totalCount + pageSize - 1) ~/ pageSize;

  bool get _hasPrev => page > 0;
  bool get _hasNext => page + 1 < _totalPages;

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '共 $totalCount 行 · 第 ${_totalPages == 0 ? 0 : page + 1}/$_totalPages 页',
          style: TextStyle(fontSize: 12, color: colors.textSecondary),
        ),
        IconButton(
          icon: const Icon(Icons.chevron_left, size: 18),
          tooltip: '上一页',
          onPressed: _hasPrev && !loading ? () => onPageChanged(page - 1) : null,
        ),
        IconButton(
          icon: const Icon(Icons.chevron_right, size: 18),
          tooltip: '下一页',
          onPressed: _hasNext && !loading ? () => onPageChanged(page + 1) : null,
        ),
      ],
    );
  }
}
