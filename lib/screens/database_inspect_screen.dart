import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/debug_database_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_empty_hint.dart';
import '../widgets/data_pagination.dart';

/// 「数据库结构」页：只读查看当前用户库的表结构、索引与内容（按页）。
///
/// 顶部列出全部数据表及总行数；展开某张表显示其列结构（列名/类型/是否主键/
/// 是否非空/默认值）、索引，以及内容（每页最多 20 行，超出经分页条翻页）。
class DatabaseInspectScreen extends StatefulWidget {
  const DatabaseInspectScreen({super.key, required this.service});

  final DebugDatabaseService service;

  @override
  State<DatabaseInspectScreen> createState() => _DatabaseInspectScreenState();
}

class _DatabaseInspectScreenState extends State<DatabaseInspectScreen> {
  late final Future<List<DebugTableSummary>> _tablesFuture;

  @override
  void initState() {
    super.initState();
    _tablesFuture = widget.service.listTables();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    return Scaffold(
      backgroundColor: colors.background,
      appBar: AppBar(title: const Text('数据库结构')),
      body: FutureBuilder<List<DebugTableSummary>>(
        future: _tablesFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: AppEmptyHint(
                  icon: Icons.error_outline,
                  text: '数据库加载失败',
                ),
              ),
            );
          }
          final tables = snapshot.data ?? const <DebugTableSummary>[];
          if (tables.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: AppEmptyHint(
                  icon: Icons.storage_outlined,
                  text: '暂无数据表',
                ),
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              for (final summary in tables)
                _TableTile(service: widget.service, summary: summary),
            ],
          );
        },
      ),
    );
  }
}

/// 单张表的可展开卡片：主体为 [ExpansionTile]，展开后按页加载并展示结构/内容。
class _TableTile extends StatefulWidget {
  const _TableTile({required this.service, required this.summary});

  final DebugDatabaseService service;
  final DebugTableSummary summary;

  @override
  State<_TableTile> createState() => _TableTileState();
}

class _TableTileState extends State<_TableTile> {
  static const int _pageSize = 20;
  static const double _maxCellWidth = 220;

  final ScrollController _horizontalController = ScrollController();

  DebugTablePage? _page;
  bool _loading = false;
  bool _loaded = false;

  @override
  void dispose() {
    _horizontalController.dispose();
    super.dispose();
  }

  Future<void> _load(int page) async {
    setState(() => _loading = true);
    try {
      final result = await widget.service.loadTable(
        widget.summary.name,
        page: page,
        pageSize: _pageSize,
      );
      if (!mounted) return;
      setState(() {
        _page = result;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _onExpansion(bool expanded) {
    if (expanded && !_loaded) {
      _loaded = true;
      _load(0);
    }
  }

  void _onPageChanged(int page) => _load(page);

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      title: Text(widget.summary.name),
      subtitle: Text('${widget.summary.rowCount} 行'),
      onExpansionChanged: _onExpansion,
      children: [_buildContent(context)],
    );
  }

  Widget _buildContent(BuildContext context) {
    final colors = context.narrColors;
    if (_page == null) {
      return _loading
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(child: CircularProgressIndicator()),
            )
          : const SizedBox.shrink();
    }
    final table = _page!;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      alignment: Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionLabel('结构（列）'),
          ...table.columns.map(_columnRow),
          if (table.indexes.isNotEmpty) ...[
            const SizedBox(height: 12),
            const _SectionLabel('索引'),
            ...table.indexes.map(_indexRow),
          ],
          const SizedBox(height: 12),
          _SectionLabel('内容（第 ${table.page + 1} 页）'),
          if (table.rows.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                '无数据',
                style: TextStyle(fontSize: 12, color: colors.textSecondary),
              ),
            )
          else
            _dataTable(context, table),
          const SizedBox(height: 8),
          Center(
            child: PaginationBar(
              page: table.page,
              pageSize: table.pageSize,
              totalCount: table.totalCount,
              loading: _loading,
              onPageChanged: _onPageChanged,
            ),
          ),
        ],
      ),
    );
  }

  Widget _columnRow(DebugColumn col) {
    final colors = context.narrColors;
    final flags = <String>[
      if (col.isPrimaryKey) '主键',
      if (col.notNull) '非空',
      if (col.defaultValue != null) '默认 ${col.defaultValue}',
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 2,
            child: Text(
              col.name,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: colors.textPrimary,
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              col.type.isEmpty ? '—' : col.type,
              style: TextStyle(fontSize: 12, color: colors.textSecondary),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              flags.join(' · '),
              style: TextStyle(fontSize: 12, color: colors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _indexRow(DebugIndex index) {
    final colors = context.narrColors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Text(
        '${index.name}${index.unique ? ' (唯一)' : ''}· ${index.columns.join(', ')}',
        style: TextStyle(fontSize: 12, color: colors.textPrimary),
      ),
    );
  }

  Widget _dataTable(BuildContext context, DebugTablePage table) {
    // 限制高度以便纵向可滚动；横向用可拖动的 Scrollbar 滚动，避免列数过多溢出。
    return SizedBox(
      height: 380,
      child: Scrollbar(
        controller: _horizontalController,
        thumbVisibility: true,
        child: SingleChildScrollView(
          controller: _horizontalController,
          scrollDirection: Axis.horizontal,
          child: SingleChildScrollView(
            child: DataTable(
              columnSpacing: 16,
              columns: [
                for (final c in table.columns)
                  DataColumn(
                    label: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: _maxCellWidth),
                      child: Text(
                        c.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
              ],
              rows: [
                for (final row in table.rows)
                  DataRow(
                    cells: [
                      for (final c in table.columns)
                        DataCell(
                          _tableCell(context, c.name, row[c.name]),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 单元格：限定最大宽度、最多 3 行、超长省略；点击弹出完整内容。
  Widget _tableCell(BuildContext context, String column, Object? value) {
    final text = _cellText(value);
    return GestureDetector(
      onTap: () => _showCellDialog(context, column, text),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _maxCellWidth),
        child: Text(
          text,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, color: context.narrColors.textPrimary),
        ),
      ),
    );
  }

  void _showCellDialog(BuildContext context, String column, String value) {
    showDialog<void>(
      context: context,
      builder: (_) => _CellDetailDialog(column: column, value: value),
    );
  }

  static String _cellText(Object? value) {
    if (value == null) return 'NULL';
    if (value is Uint8List) return '<BLOB ${value.length}B>';
    return value.toString();
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: context.narrColors.textPrimary,
        ),
      ),
    );
  }
}

/// 单元格完整内容查看对话框：显示列名与完整值（可选中复制）。
class _CellDetailDialog extends StatelessWidget {
  const _CellDetailDialog({required this.column, required this.value});

  final String column;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    return Dialog(
      insetPadding: const EdgeInsets.all(20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '列：$column',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Flexible(
              child: Container(
                margin: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: colors.background,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: colors.divider),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    value,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.5,
                      color: colors.textPrimary,
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('关闭'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
