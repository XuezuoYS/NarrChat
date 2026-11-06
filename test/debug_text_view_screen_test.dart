import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/screens/debug_text_view_screen.dart';
import 'package:narrchat/services/debug_file_service.dart';
import 'package:narrchat/theme/app_theme.dart';

import 'helpers/fakes.dart';

/// 调试页 JSON / 纯文本阅读器。
Widget _host(
  FakeDebugFileService service,
  DebugFileEntry entry, {
  bool formatJson = false,
}) {
  return MaterialApp(
    theme: NarrChatTheme.light,
    home: DebugTextViewScreen(
      fileService: service,
      entry: entry,
      formatJson: formatJson,
    ),
  );
}

void main() {
  testWidgets('JSON 文件格式化显示', (tester) async {
    final service = FakeDebugFileService(
      texts: {'x.json': '{"name":"深深","n":1}'},
    );
    final entry = debugFileEntry('x.json', kind: DebugFileKind.json);

    await tester.pumpWidget(_host(service, entry, formatJson: true));
    await tester.pumpAndSettle();

    expect(find.textContaining('"name": "深深"'), findsOneWidget);
    expect(find.textContaining('"n": 1'), findsOneWidget);
  });

  testWidgets('JSON 解析失败时显示原文与原因', (tester) async {
    final service = FakeDebugFileService(texts: {'x.json': '{bad'});
    final entry = debugFileEntry('x.json', kind: DebugFileKind.json);

    await tester.pumpWidget(_host(service, entry, formatJson: true));
    await tester.pumpAndSettle();

    expect(find.textContaining('JSON 解析失败'), findsOneWidget);
    expect(find.text('{bad'), findsOneWidget);
  });

  testWidgets('纯文本原样显示', (tester) async {
    final service = FakeDebugFileService(texts: {'note.txt': '主人早安'});
    final entry = debugFileEntry('note.txt');

    await tester.pumpWidget(_host(service, entry));
    await tester.pumpAndSettle();

    expect(find.text('主人早安'), findsOneWidget);
  });

  testWidgets('空文件显示空提示', (tester) async {
    final service = FakeDebugFileService(texts: {'empty.txt': ''});
    final entry = debugFileEntry('empty.txt');

    await tester.pumpWidget(_host(service, entry));
    await tester.pumpAndSettle();

    expect(find.text('（空文件）'), findsOneWidget);
  });

  testWidgets('读取失败时显示原因，重试成功后显示内容', (tester) async {
    final service = FakeDebugFileService();
    service.errors['note.txt'] = const DebugFileException('文件不存在：note.txt');
    final entry = debugFileEntry('note.txt');

    await tester.pumpWidget(_host(service, entry));
    await tester.pumpAndSettle();

    expect(find.textContaining('文件读取失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    service.errors.remove('note.txt');
    service.texts['note.txt'] = '好啦';
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(find.text('好啦'), findsOneWidget);
  });
}
