import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/screens/database_inspect_screen.dart';
import 'package:narrchat/services/debug_database_service.dart';
import 'package:narrchat/theme/app_theme.dart';

import 'helpers/fakes.dart';

void main() {
  testWidgets('展示表列表，展开后可查看结构与本页内容', (tester) async {
    final service = FakeDebugDatabaseService(
      tables: const [DebugTableSummary(name: 'books', rowCount: 25)],
      pageBuilder: _buildPage,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: NarrChatTheme.light,
        home: DatabaseInspectScreen(service: service),
      ),
    );
    await tester.pumpAndSettle();

    // 表列表 + 总行数。
    expect(find.text('books'), findsOneWidget);
    expect(find.text('25 行'), findsOneWidget);

    // 展开表 → 加载第 0 页并显示列结构、列头与行内容。
    await tester.tap(find.text('books'));
    await tester.pumpAndSettle();

    expect(find.text('结构（列）'), findsOneWidget);
    expect(find.text('索引'), findsNothing);
    expect(find.text('书1'), findsOneWidget);
    expect(find.text('书20'), findsOneWidget);
    expect(find.text('共 25 行 · 第 1/2 页'), findsOneWidget);
    // 数据表带可拖动横向滚动条。
    expect(find.byType(Scrollbar), findsOneWidget);
    expect(service.lastPage, 0);
    expect(service.lastPageSize, 20);
  });

  testWidgets('点击下一页加载下一页数据', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final service = FakeDebugDatabaseService(
      tables: const [DebugTableSummary(name: 'books', rowCount: 25)],
      pageBuilder: _buildPage,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: NarrChatTheme.light,
        home: DatabaseInspectScreen(service: service),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('books'));
    await tester.pumpAndSettle();

    final loadCountBefore = service.loadCount;
    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();

    expect(service.lastPage, 1);
    expect(service.loadCount, loadCountBefore + 1);
    expect(find.text('书21'), findsOneWidget);
    expect(find.text('共 25 行 · 第 2/2 页'), findsOneWidget);
  });

  testWidgets('空表显示无数据', (tester) async {
    final service = FakeDebugDatabaseService(
      tables: const [DebugTableSummary(name: 'mods', rowCount: 0)],
      pageBuilder: (name, page, pageSize) => DebugTablePage(
        name: name,
        columns: const [DebugColumn(name: 'name', type: 'TEXT', notNull: true, isPrimaryKey: false)],
        indexes: const [],
        rows: const [],
        totalCount: 0,
        page: page,
        pageSize: pageSize,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: NarrChatTheme.light,
        home: DatabaseInspectScreen(service: service),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('mods'));
    await tester.pumpAndSettle();

    expect(find.text('无数据'), findsOneWidget);
  });

  testWidgets('点击单元格弹出完整内容对话框', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    const longTitle = '这是一个非常长的标题，用于测试单元格的省略显示与点击查看完整内容的交互';
    final service = FakeDebugDatabaseService(
      tables: const [DebugTableSummary(name: 'books', rowCount: 1)],
      pageBuilder: (name, page, pageSize) => DebugTablePage(
        name: name,
        columns: const [
          DebugColumn(name: 'id', type: 'INTEGER', notNull: true, isPrimaryKey: true),
          DebugColumn(name: 'title', type: 'TEXT', notNull: true, isPrimaryKey: false),
        ],
        indexes: const [],
        rows: [
          {'id': 1, 'title': longTitle},
        ],
        totalCount: 1,
        page: page,
        pageSize: pageSize,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: NarrChatTheme.light,
        home: DatabaseInspectScreen(service: service),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('books'));
    await tester.pumpAndSettle();

    // 对话框尚未打开（无 SelectableText）。
    expect(find.byType(SelectableText), findsNothing);

    // 点击长文本单元格 → 打开完整内容对话框。
    await tester.tap(find.text(longTitle));
    await tester.pumpAndSettle();

    expect(find.byType(SelectableText), findsOneWidget);
    expect(find.text('列：title'), findsOneWidget);
    expect(find.text('关闭'), findsOneWidget);
  });
}

DebugTablePage _buildPage(String name, int page, int pageSize) {
  const total = 25;
  final start = page * pageSize;
  final count = (total - start).clamp(0, pageSize);
  return DebugTablePage(
    name: name,
    columns: const [
      DebugColumn(name: 'id', type: 'INTEGER', notNull: true, isPrimaryKey: true),
      DebugColumn(name: 'title', type: 'TEXT', notNull: true, isPrimaryKey: false),
    ],
    indexes: const [],
    rows: List.generate(
      count,
      (i) => {'id': start + i + 1, 'title': '书${start + i + 1}'},
    ),
    totalCount: total,
    page: page,
    pageSize: pageSize,
  );
}
