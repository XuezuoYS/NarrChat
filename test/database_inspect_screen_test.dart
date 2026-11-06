import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/screens/database_inspect_screen.dart';
import 'package:narrchat/services/debug_database_service.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/markdown_preview.dart';

import 'helpers/fakes.dart';

/// 调试页的库浏览器：先选库（ChoiceChip），再选表，再翻页看内容。
///
/// R3 是多库，页面顶部多了一层"库选择器"，其余交互（展开表、翻页、
/// 点单元格看全文）与 R2 一致。
const DebugDbInfo _library = DebugDbInfo(
  id: 'library',
  label: '书籍目录库',
  path: '/x/narrchat_library.db',
  expectedVersion: 22,
  actualVersion: 22,
  sizeBytes: 100,
  exists: true,
);

const DebugDbInfo _bookDb = DebugDbInfo(
  id: 'book:b1',
  label: '书 b1',
  path: '/x/books/narrbook_b1.db',
  expectedVersion: 22,
  actualVersion: 22,
  sizeBytes: 200,
  exists: true,
);

Widget _host(FakeDebugDatabaseService service) => MaterialApp(
      theme: NarrChatTheme.light,
      home: DatabaseInspectScreen(service: service),
    );

DebugTablePage _buildPage(String dbId, String name, int page, int pageSize) {
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

void main() {
  testWidgets('展示库选择器与表列表，展开后可查看结构与本页内容', (tester) async {
    final service = FakeDebugDatabaseService(
      databases: const [_library, _bookDb],
      tables: const [DebugTableSummary(name: 'books', rowCount: 25)],
      pageBuilder: _buildPage,
    );

    await tester.pumpWidget(_host(service));
    await tester.pumpAndSettle();

    // 库选择器：只列真实存在的库，默认选第一个。
    expect(find.text('书籍目录库'), findsOneWidget);
    expect(find.text('书 b1'), findsOneWidget);
    expect(service.lastDbId, 'library');

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

  testWidgets('切换库：重新拉取该库的表并收起已展开的表', (tester) async {
    final service = FakeDebugDatabaseService(
      databases: const [_library, _bookDb],
      tables: const [DebugTableSummary(name: 'books', rowCount: 1)],
      pageBuilder: _buildPage,
    );

    await tester.pumpWidget(_host(service));
    await tester.pumpAndSettle();
    await tester.tap(find.text('books'));
    await tester.pumpAndSettle();
    expect(find.text('结构（列）'), findsOneWidget);

    await tester.tap(find.text('书 b1'));
    await tester.pumpAndSettle();

    expect(service.lastDbId, 'book:b1');
  });

  testWidgets('点击下一页加载下一页数据', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final service = FakeDebugDatabaseService(
      databases: const [_library],
      tables: const [DebugTableSummary(name: 'books', rowCount: 25)],
      pageBuilder: _buildPage,
    );

    await tester.pumpWidget(_host(service));
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
      databases: const [_library],
      tables: const [DebugTableSummary(name: 'mods', rowCount: 0)],
      pageBuilder: (dbId, name, page, pageSize) => DebugTablePage(
        name: name,
        columns: const [
          DebugColumn(name: 'name', type: 'TEXT', notNull: true, isPrimaryKey: false),
        ],
        indexes: const [],
        rows: const [],
        totalCount: 0,
        page: page,
        pageSize: pageSize,
      ),
    );

    await tester.pumpWidget(_host(service));
    await tester.pumpAndSettle();
    await tester.tap(find.text('mods'));
    await tester.pumpAndSettle();

    expect(find.text('无数据'), findsOneWidget);
  });

  testWidgets('没有任何库文件时给出空提示，不渲染表列表', (tester) async {
    final service = FakeDebugDatabaseService(
      databases: const [
        DebugDbInfo(
          id: 'library',
          label: '书籍目录库',
          path: '/x/narrchat_library.db',
          expectedVersion: 22,
          actualVersion: 0,
          sizeBytes: 0,
          exists: false,
        ),
      ],
      tables: const [DebugTableSummary(name: 'books', rowCount: 0)],
    );

    await tester.pumpWidget(_host(service));
    await tester.pumpAndSettle();

    expect(find.text('书籍目录库'), findsNothing);
    expect(find.text('books'), findsNothing);
  });

  testWidgets('点击单元格弹出完整内容对话框', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    const longTitle = '这是一个非常长的标题，用于测试单元格的省略显示与点击查看完整内容的交互';
    final service = FakeDebugDatabaseService(
      databases: const [_library],
      tables: const [DebugTableSummary(name: 'books', rowCount: 1)],
      pageBuilder: (dbId, name, page, pageSize) => DebugTablePage(
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

    await tester.pumpWidget(_host(service));
    await tester.pumpAndSettle();
    await tester.tap(find.text('books'));
    await tester.pumpAndSettle();

    // 对话框尚未打开（无选中容器）。
    expect(find.byType(SelectableTextArea), findsNothing);

    // 点击长文本单元格 → 打开完整内容对话框。
    await tester.tap(find.text(longTitle));
    await tester.pumpAndSettle();

    expect(find.byType(SelectableTextArea), findsOneWidget);
    expect(find.text('列：title'), findsOneWidget);
    expect(find.text('关闭'), findsOneWidget);
  });
}
