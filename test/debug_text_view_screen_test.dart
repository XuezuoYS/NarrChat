import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/screens/debug_text_view_screen.dart';
import 'package:narrchat/services/debug_file_service.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/json_syntax_colors.dart';

import 'helpers/fakes.dart';
import 'helpers/span_helpers.dart';

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

/// 页面上由 `Text.rich` 渲染的正文（JSON 阅读器用 JsonView 渲染时才有）。
Finder _richText() =>
    find.byWidgetPredicate((widget) => widget is Text && widget.textSpan != null);

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

  testWidgets('JSON 文件按 JSON 语法着色（键名 / 字符串 / 数字）', (tester) async {
    final service = FakeDebugFileService(
      texts: {'x.json': '{"name":"深深","n":1}'},
    );
    final entry = debugFileEntry('x.json', kind: DebugFileKind.json);

    await tester.pumpWidget(_host(service, entry, formatJson: true));
    await tester.pumpAndSettle();

    final root = tester.widget<Text>(_richText()).textSpan!;
    expect(spanWithText(root, '"name"').style?.color, JsonSyntaxColors.light.key);
    expect(
      spanWithText(root, '"深深"').style?.color,
      JsonSyntaxColors.light.string,
    );
    expect(spanWithText(root, '1').style?.color, JsonSyntaxColors.light.number);
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

  testWidgets('纯文本文件即使内容像 JSON 也不做语法着色', (tester) async {
    final service = FakeDebugFileService(texts: {'note.txt': '{"a":1}'});
    final entry = debugFileEntry('note.txt');

    await tester.pumpWidget(_host(service, entry));
    await tester.pumpAndSettle();

    // 纯文本走普通 Text（没有 textSpan），不会被当成 JSON 上色。
    expect(_richText(), findsNothing);
    expect(find.text('{"a":1}'), findsOneWidget);
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
