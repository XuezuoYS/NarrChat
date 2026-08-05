import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/markdown_collapsible_editor.dart';

void main() {
  testWidgets('debug-scroll-tap', (tester) async {
    final sb = StringBuffer('# 女主角\n');
    for (var i = 0; i < 12; i++) {
      sb.writeln('## 角色$i');
      sb.writeln('- 属性A：值$i');
      sb.writeln('- 属性B：值$i');
    }
    final scrollController = ScrollController();
    final editorController = TextEditingController(text: sb.toString());
    addTearDown(scrollController.dispose);
    addTearDown(editorController.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: NarrChatTheme.light,
        home: Scaffold(
          body: SizedBox(
            width: 320,
            height: 500,
            child: ListView(
              controller: scrollController,
              padding: const EdgeInsets.all(12),
              children: [
                MarkdownCollapsibleEditor(controller: editorController),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    scrollController.jumpTo(scrollController.position.maxScrollExtent);
    await tester.pump();
    final before = scrollController.offset;
    debugPrint('max=${scrollController.position.maxScrollExtent} before=$before');
    debugPrint('角色11 rect: ${tester.getRect(find.text('角色11'))}');

    final g = await tester.startGesture(tester.getCenter(find.text('角色11')));
    await tester.pump(const Duration(milliseconds: 400));
    await g.up();
    await tester.pump();
    debugPrint('首帧后 offset=${scrollController.offset}');
    await tester.pumpAndSettle();
    debugPrint(
        'settle后 offset=${scrollController.offset} max=${scrollController.position.maxScrollExtent}');
    debugPrint(
        '属性A：值11 found=${find.textContaining('属性A：值11').evaluate().length}');
  });
}
