import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/screens/database_inspect_screen.dart';
import 'package:narrchat/services/debug_database_service.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/markdown_preview.dart';

import 'helpers/fakes.dart';

/// 调试页的单文件 sqliteView：一个页面只看一个库文件，不再有选库器。
const String _dbPath = '/x/books/narrbook_b1.db';

Widget _host(FakeDebugDatabaseService service) => MaterialApp(
  theme: NarrChatTheme.light,
  home: DatabaseInspectScreen(
    service: service,
    dbPath: _dbPath,
    title: 'narrbook_b1.db',
  ),
);

DebugTablePage _buildPage(String dbPath, String name, int page, int pageSize) {
  const total = 25;
  final start = page * pageSize;
  final count = (total - start).clamp(0, pageSize);
  return DebugTablePage(
    name: name,
    columns: const [
      DebugColumn(
        name: 'id',
        type: 'INTEGER',
        notNull: true,
        isPrimaryKey: true,
      ),
      DebugColumn(
        name: 'title',
        type: 'TEXT',
        notNull: true,
        isPrimaryKey: false,
      ),
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

/// 第一次列表失败、第二次成功的替身，用于验证「重试」真的重新拉取。
class _FlakyListService extends FakeDebugDatabaseService {
  _FlakyListService({super.tables = const []});

  int calls = 0;

  @override
  Future<List<DebugTableSummary>> listTables(String dbPath) async {
    calls++;
    if (calls == 1) throw StateError('库损坏');
    return super.listTables(dbPath);
  }
}

void main() {
  testWidgets('展示库路径、表列表，展开后查看结构与本页内容', (tester) async {
    final service = FakeDebugDatabaseService(
      tables: const [DebugTableSummary(name: 'books', rowCount: 25)],
      pageBuilder: _buildPage,
    );

    await tester.pumpWidget(_host(service));
    await tester.pumpAndSettle();

    expect(find.text(_dbPath), findsOneWidget);
    expect(find.text('books'), findsOneWidget);
    expect(find.text('25 行'), findsOneWidget);
    expect(service.lastDbPath, _dbPath);

    await tester.tap(find.text('books'));
    await tester.pumpAndSettle();

    expect(find.text('结构（列）'), findsOneWidget);
    expect(find.text('索引'), findsNothing);
    expect(find.text('书1'), findsOneWidget);
    expect(find.text('书20'), findsOneWidget);
    expect(find.text('共 25 行 · 第 1/2 页'), findsOneWidget);
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
      tables: const [DebugTableSummary(name: 'mods', rowCount: 0)],
      pageBuilder: (dbPath, name, page, pageSize) => DebugTablePage(
        name: name,
        columns: const [
          DebugColumn(
            name: 'name',
            type: 'TEXT',
            notNull: true,
            isPrimaryKey: false,
          ),
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

  testWidgets('没有任何数据表时给出空提示', (tester) async {
    final service = FakeDebugDatabaseService();

    await tester.pumpWidget(_host(service));
    await tester.pumpAndSettle();

    expect(find.text('暂无数据表'), findsOneWidget);
    expect(find.text('books'), findsNothing);
  });

  testWidgets('表列表读取失败时显示原因，重试成功后显示表', (tester) async {
    final service = _FlakyListService(
      tables: const [DebugTableSummary(name: 'books', rowCount: 1)],
    );

    await tester.pumpWidget(_host(service));
    await tester.pumpAndSettle();

    expect(find.textContaining('数据库读取失败'), findsOneWidget);
    expect(find.textContaining('库损坏'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(service.calls, 2);
    expect(find.text('books'), findsOneWidget);
  });

  testWidgets('表内容读取失败时显示原因，重试成功后显示内容', (tester) async {
    var calls = 0;
    final service = FakeDebugDatabaseService(
      tables: const [DebugTableSummary(name: 'books', rowCount: 1)],
      pageBuilder: (dbPath, name, page, pageSize) {
        calls++;
        if (calls == 1) throw StateError('表损坏');
        return _buildPage(dbPath, name, page, pageSize);
      },
    );

    await tester.pumpWidget(_host(service));
    await tester.pumpAndSettle();
    await tester.tap(find.text('books'));
    await tester.pumpAndSettle();

    expect(find.textContaining('读取失败'), findsOneWidget);
    expect(find.textContaining('表损坏'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(calls, 2);
    expect(find.text('书1'), findsOneWidget);
  });

  testWidgets('点击单元格弹出完整内容对话框', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    const longTitle = '这是一个非常长的标题，用于测试单元格的省略显示与点击查看完整内容的交互';
    final service = FakeDebugDatabaseService(
      tables: const [DebugTableSummary(name: 'books', rowCount: 1)],
      pageBuilder: (dbPath, name, page, pageSize) => DebugTablePage(
        name: name,
        columns: const [
          DebugColumn(
            name: 'id',
            type: 'INTEGER',
            notNull: true,
            isPrimaryKey: true,
          ),
          DebugColumn(
            name: 'title',
            type: 'TEXT',
            notNull: true,
            isPrimaryKey: false,
          ),
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
