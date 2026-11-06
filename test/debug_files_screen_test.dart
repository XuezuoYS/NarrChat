import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/screens/database_inspect_screen.dart';
import 'package:narrchat/screens/debug_files_screen.dart';
import 'package:narrchat/screens/debug_image_screen.dart';
import 'package:narrchat/screens/debug_text_view_screen.dart';
import 'package:narrchat/services/debug_database_service.dart';
import 'package:narrchat/services/debug_file_service.dart';
import 'package:narrchat/theme/app_theme.dart';

import 'helpers/fakes.dart';

/// 调试页文件浏览：列目录、逐层进入、书名小字与各阅读器路由。
FakeDebugFileService _fileService() {
  return FakeDebugFileService(
    rootPath: '/data',
    directories: {
      '': [
        debugFileEntry('user_data', isDirectory: true),
        debugFileEntry('local_config', isDirectory: true),
      ],
      'user_data': [
        debugFileEntry('user_data/books', isDirectory: true),
        debugFileEntry(
          'user_data/narrchat_library.db',
          kind: DebugFileKind.sqlite,
        ),
      ],
      'user_data/books': [
        debugFileEntry(
          'user_data/books/narrbook_b1.db',
          kind: DebugFileKind.sqlite,
          sizeBytes: 120,
          modified: DateTime(2026, 1, 2, 3, 4),
        ),
        debugFileEntry(
          'user_data/books/narrbook_b2.db',
          kind: DebugFileKind.sqlite,
          sizeBytes: 130,
        ),
        debugFileEntry('user_data/books/notes.json', kind: DebugFileKind.json),
        debugFileEntry('user_data/books/cover.png', kind: DebugFileKind.image),
        debugFileEntry('user_data/books/readme.txt', kind: DebugFileKind.text),
        debugFileEntry('user_data/books/blob.bin', kind: DebugFileKind.binary),
      ],
    },
    texts: {
      'user_data/books/notes.json': '{"name":"深深","n":1}',
      'user_data/books/readme.txt': '主人早安',
    },
  );
}

const Map<String, String?> _titles = {
  '/data/user_data/books/narrbook_b1.db': '测试书',
};

Widget _host(
  FakeDebugFileService fileService,
  FakeDebugDatabaseService databaseService, {
  String relativePath = '',
}) {
  return MaterialApp(
    theme: NarrChatTheme.light,
    home: DebugFilesScreen(
      fileService: fileService,
      databaseService: databaseService,
      relativePath: relativePath,
    ),
  );
}

FakeDebugDatabaseService _databaseService() {
  return FakeDebugDatabaseService(
    tables: const [DebugTableSummary(name: 'book_meta', rowCount: 1)],
    bookTitles: _titles,
  );
}

void main() {
  testWidgets('根目录列出目录，可逐层进入并显示书名小字', (tester) async {
    final fileService = _fileService();
    final databaseService = _databaseService();

    await tester.pumpWidget(_host(fileService, databaseService));
    await tester.pumpAndSettle();

    expect(find.textContaining('应用数据根目录'), findsOneWidget);
    expect(find.text('user_data'), findsOneWidget);
    expect(find.text('local_config'), findsOneWidget);

    await tester.tap(find.text('user_data'));
    await tester.pumpAndSettle();
    expect(fileService.listedPaths, contains('user_data'));
    expect(find.text('narrchat_library.db'), findsOneWidget);

    await tester.tap(find.text('books'));
    await tester.pumpAndSettle();
    expect(fileService.listedPaths, contains('user_data/books'));
    expect(find.text('narrbook_b1.db'), findsOneWidget);
    expect(find.text('《测试书》'), findsOneWidget);
    // 没有书名的书库：明确显示「书名未知」。
    expect(find.text('书名未知'), findsOneWidget);
    expect(find.textContaining('120 B'), findsOneWidget);
    expect(
      databaseService.titlePaths,
      contains('/data/user_data/books/narrbook_b1.db'),
    );
  });

  testWidgets('点击书籍库进入单文件 sqliteView', (tester) async {
    final fileService = _fileService();
    final databaseService = _databaseService();

    await tester.pumpWidget(
      _host(fileService, databaseService, relativePath: 'user_data/books'),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('narrbook_b1.db'));
    await tester.pumpAndSettle();

    expect(find.byType(DatabaseInspectScreen), findsOneWidget);
    expect(databaseService.lastDbPath, '/data/user_data/books/narrbook_b1.db');
    expect(find.text('book_meta'), findsOneWidget);
  });

  testWidgets('JSON 与文本文件进入对应阅读器', (tester) async {
    final fileService = _fileService();
    final databaseService = _databaseService();

    await tester.pumpWidget(
      _host(fileService, databaseService, relativePath: 'user_data/books'),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('notes.json'));
    await tester.pumpAndSettle();
    expect(find.byType(DebugTextViewScreen), findsOneWidget);
    expect(find.textContaining('"name": "深深"'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.text('readme.txt'));
    await tester.pumpAndSettle();
    expect(find.byType(DebugTextViewScreen), findsOneWidget);
    expect(find.text('主人早安'), findsOneWidget);
  });

  testWidgets('图片文件进入图片查看器', (tester) async {
    final fileService = _fileService();
    final databaseService = _databaseService();

    await tester.pumpWidget(
      _host(fileService, databaseService, relativePath: 'user_data/books'),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('cover.png'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(DebugImageScreen), findsOneWidget);
  });

  testWidgets('二进制文件弹出基本信息提示', (tester) async {
    final fileService = _fileService();
    final databaseService = _databaseService();

    await tester.pumpWidget(
      _host(fileService, databaseService, relativePath: 'user_data/books'),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('blob.bin'));
    await tester.pumpAndSettle();

    expect(find.text('二进制文件无法预览。'), findsOneWidget);
    expect(find.text('关闭'), findsOneWidget);
    expect(find.textContaining('blob.bin'), findsWidgets);
  });

  testWidgets('空目录显示空提示', (tester) async {
    final fileService = FakeDebugFileService(directories: {'': const []});
    final databaseService = FakeDebugDatabaseService();

    await tester.pumpWidget(_host(fileService, databaseService));
    await tester.pumpAndSettle();

    expect(find.text('这个文件夹是空的'), findsOneWidget);
  });

  testWidgets('目录读取失败时显示原因，重试成功后显示内容', (tester) async {
    final fileService = _fileService();
    fileService.errors['user_data'] = StateError('磁盘坏了');
    final databaseService = _databaseService();

    await tester.pumpWidget(_host(fileService, databaseService));
    await tester.pumpAndSettle();
    await tester.tap(find.text('user_data'));
    await tester.pumpAndSettle();

    expect(find.textContaining('目录读取失败'), findsOneWidget);
    expect(find.textContaining('磁盘坏了'), findsOneWidget);

    fileService.errors.remove('user_data');
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(find.text('narrchat_library.db'), findsOneWidget);
  });
}
