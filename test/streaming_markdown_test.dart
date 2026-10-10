import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/markdown_preview.dart';
import 'package:narrchat/widgets/streaming_markdown.dart';

/// 流式 Markdown 预览：**按块增量渲染**。
///
/// 核心不变量是「已封闭块的 widget 实例被复用」——实例同一 ⇒
/// `Element.updateChild` 命中同一实例短路 ⇒ 子树不 rebuild ⇒ 不重新解析、不重新
/// 排版。所以断言方式与 `chat_stream_rebuild_scope_test` 一致：比实例同一性，
/// 并进一步比对 `MarkdownBody` 实例（它只在 `MarkdownPreview.build` 重跑时才会
/// 重新构造，是「未重建」的直接证据）。
///
/// ⚠️ 宿主刻意只用 [ValueNotifier] 驱动正文更新、`MaterialApp` 只 pump 一次：
/// 每次 `pumpWidget` 重建 `MaterialApp` 都会带出新 `ThemeData`，从而让所有
/// 主题依赖者（含冻结块）重建，掩盖本文件要验证的缓存行为。
Widget _host(
  ValueNotifier<String> data, {
  String trailing = '',
  bool selectable = true,
}) =>
    MaterialApp(
      theme: NarrChatTheme.light,
      home: Scaffold(
        body: SingleChildScrollView(
          child: ValueListenableBuilder<String>(
            valueListenable: data,
            builder: (context, value, _) => StreamingMarkdown(
              data: value,
              trailing: trailing,
              selectable: selectable,
              base: const TextStyle(fontSize: 15, height: 1.65),
            ),
          ),
        ),
      ),
    );

/// pump 宿主并返回驱动正文的 notifier（写入后 `pumpAndSettle` 即增量）。
Future<ValueNotifier<String>> _pump(
  WidgetTester tester,
  String initial, {
  String trailing = '',
  bool selectable = true,
}) async {
  final data = ValueNotifier<String>(initial);
  addTearDown(data.dispose);
  await tester.pumpWidget(
    _host(data, trailing: trailing, selectable: selectable),
  );
  await tester.pumpAndSettle();
  return data;
}

List<MarkdownPreview> _previews(WidgetTester tester) =>
    tester.widgetList<MarkdownPreview>(find.byType(MarkdownPreview)).toList();

List<MarkdownBody> _bodies(WidgetTester tester) =>
    tester.widgetList<MarkdownBody>(find.byType(MarkdownBody)).toList();

/// 页面上所有富文本按树顺序拼接的纯文本（用于「与整段渲染等价」比对）。
String _plainText(WidgetTester tester) {
  final parts = <String>[
    for (final rich in tester.widgetList<RichText>(find.byType(RichText)))
      rich.text.toPlainText(),
  ];
  return parts.join('␟');
}

void main() {
  testWidgets('已封闭段落冻结复用，只有尾部残块随增量重建', (tester) async {
    final data = await _pump(tester, '第一段。\n\n第二段。\n\n第三段');

    final previewsBefore = _previews(tester);
    expect(previewsBefore.length, 3, reason: '两个已封闭块 + 一个尾部残块');
    expect(previewsBefore[0].data, '第一段。\n\n');
    expect(previewsBefore[1].data, '第二段。\n\n');
    expect(previewsBefore[2].data, '第三段');
    final bodiesBefore = _bodies(tester);
    expect(bodiesBefore.length, 3);

    // 下一增量：只有尾部残块继续增长。
    data.value = '第一段。\n\n第二段。\n\n第三段继续增长';
    await tester.pumpAndSettle();

    final previewsAfter = _previews(tester);
    expect(previewsAfter.length, 3);
    expect(
      identical(previewsAfter[0], previewsBefore[0]),
      isTrue,
      reason: '已封闭块必须复用同一 widget 实例（否则会重新解析重排）',
    );
    expect(identical(previewsAfter[1], previewsBefore[1]), isTrue);
    expect(identical(previewsAfter[2], previewsBefore[2]), isFalse);
    expect(previewsAfter[2].data, '第三段继续增长');

    // 冻结块的 MarkdownBody 实例也未变 ⇒ build 未重跑 ⇒ 未重新解析。
    final bodiesAfter = _bodies(tester);
    expect(bodiesAfter.length, 3);
    expect(identical(bodiesAfter[0], bodiesBefore[0]), isTrue);
    expect(identical(bodiesAfter[1], bodiesBefore[1]), isTrue);
    expect(find.textContaining('第三段继续增长'), findsOneWidget);
  });

  testWidgets('新增段落完成时：旧块保持冻结，尾部升级为冻结块', (tester) async {
    final data = await _pump(tester, '第一段。\n\n第二段还没写完');
    final previewsBefore = _previews(tester);
    expect(previewsBefore.length, 2);
    final firstBody = _bodies(tester).first;

    // 尾部残块写完（出现空行）→ 升级为冻结块。
    data.value = '第一段。\n\n第二段还没写完。\n\n';
    await tester.pumpAndSettle();

    final previewsAfter = _previews(tester);
    expect(previewsAfter.length, 2);
    expect(previewsAfter[0].data, '第一段。\n\n');
    expect(previewsAfter[1].data, '第二段还没写完。\n\n');
    expect(
      identical(previewsAfter[0], previewsBefore[0]),
      isTrue,
      reason: '首段不受影响',
    );
    expect(
      identical(_bodies(tester).first, firstBody),
      isTrue,
      reason: '首段未重新解析',
    );
  });

  testWidgets('尾部残块不冻结（无空行时与整段渲染行为一致）', (tester) async {
    final data = await _pump(tester, '一段还在写的话');
    final first = _previews(tester);
    expect(first.length, 1);
    expect(first[0].data, '一段还在写的话');

    data.value = '一段还在写的话，继续';
    await tester.pumpAndSettle();
    final second = _previews(tester);
    expect(second.length, 1);
    expect(
      identical(second[0], first[0]),
      isFalse,
      reason: '没有空行就没有块边界，尾部每帧重排（不误冻结）',
    );
    expect(second[0].data, '一段还在写的话，继续');
  });

  testWidgets('data 非前缀延伸（换轮 / 改写）时缓存整体重建', (tester) async {
    final data = await _pump(tester, '第一段。\n\n第二段。\n\n第三段');
    expect(_previews(tester).length, 3);
    final firstBody = _bodies(tester).first;

    data.value = '全新一轮的正文';
    await tester.pumpAndSettle();
    final previews = _previews(tester);
    expect(previews.length, 1);
    expect(previews.single.data, '全新一轮的正文');
    expect(
      identical(_bodies(tester).single, firstBody),
      isFalse,
      reason: '旧段落不得留在页面上',
    );
  });

  testWidgets('块间隔与整段渲染一致：渲染文本与 MarkdownPreview 等价', (tester) async {
    const data = '第一段**加粗**。\n\n- 甲\n- 乙\n\n'
        '第三段`代码`。\n\n第四段还没写完';

    await _pump(tester, data, trailing: '▍');
    final streamingText = _plainText(tester);
    final streamingPreviewCount = _previews(tester).length;
    expect(streamingPreviewCount, 3, reason: '两段 + 一个列表/段落块 + 尾部');

    await tester.pumpWidget(
      MaterialApp(
        theme: NarrChatTheme.light,
        home: const Scaffold(
          body: SingleChildScrollView(
            child: MarkdownPreview(
              data: '$data▍',
              base: TextStyle(fontSize: 15, height: 1.65),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(_previews(tester).length, 1);
    expect(
      streamingText,
      _plainText(tester),
      reason: '按块拆分的渲染文本必须与整段解析逐块一致',
    );
    // 正向对照：内容确实都渲染出来了（避免「两边都空」的假通过）。
    expect(streamingText, contains('第四段还没写完▍'));
    expect(streamingText, contains('乙'));
  });

  testWidgets('光标只在尾部残块末尾，且不参与块切分', (tester) async {
    final data = await _pump(tester, '第一段。\n\n', trailing: '▍');
    var previews = _previews(tester);
    expect(previews.length, 2);
    expect(previews[0].data, '第一段。\n\n');
    expect(previews[1].data, '▍', reason: '块已封闭时光标自成一段');
    expect(find.textContaining('▍'), findsOneWidget);

    data.value = '第一段。\n\n第二段';
    await tester.pumpAndSettle();
    previews = _previews(tester);
    expect(previews.length, 2);
    expect(previews[0].data, '第一段。\n\n');
    expect(
      previews[1].data,
      '第二段▍',
      reason: '光标必须紧跟尾部残块，且不参与块切分',
    );
    expect(find.textContaining('▍'), findsOneWidget);
    expect(
      find.textContaining('第一段。'),
      findsOneWidget,
      reason: '光标不得被拼进已冻结的块',
    );
  });

  testWidgets('整段正文只有一个选中区（可跨块连续选中）', (tester) async {
    await _pump(tester, '第一段。\n\n第二段。\n\n第三段');
    expect(_previews(tester).length, 3);
    expect(
      find.byType(SelectionArea),
      findsOneWidget,
      reason: '拆成多块后仍只能有一个选区容器',
    );

    await _pump(
      tester,
      '第一段。\n\n第二段。\n\n第三段',
      selectable: false,
    );
    expect(_previews(tester).length, 3);
    expect(find.byType(SelectionArea), findsNothing);
  });

  testWidgets('空数据不渲染任何 Markdown', (tester) async {
    await _pump(tester, '');
    expect(find.byType(StreamingMarkdown), findsOneWidget);
    expect(find.byType(MarkdownBody), findsNothing);
  });

  testWidgets('base 变化（主题切换）后冻结块以新样式重建', (tester) async {
    final data = ValueNotifier<String>('第一段。\n\n第二段。\n\n第三段');
    addTearDown(data.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: NarrChatTheme.light,
        home: Scaffold(
          body: SingleChildScrollView(
            child: ValueListenableBuilder<String>(
              valueListenable: data,
              builder: (context, value, _) => StreamingMarkdown(
                data: value,
                base: const TextStyle(fontSize: 15, height: 1.65),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final before = _previews(tester);
    expect(before.length, 3);
    expect(before.first.base?.fontSize, 15);

    await tester.pumpWidget(
      MaterialApp(
        theme: NarrChatTheme.light,
        home: Scaffold(
          body: SingleChildScrollView(
            child: ValueListenableBuilder<String>(
              valueListenable: data,
              builder: (context, value, _) => StreamingMarkdown(
                data: value,
                base: const TextStyle(fontSize: 20, height: 1.65),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final after = _previews(tester);
    expect(after.length, 3);
    expect(
      identical(after[0], before[0]),
      isFalse,
      reason: '基样式变化后冻结块必须按新样式重建',
    );
    expect(after[0].base?.fontSize, 20);
  });
}
