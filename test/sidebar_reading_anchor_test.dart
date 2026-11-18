import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/markdown_collapsible_editor.dart';
import 'package:narrchat/widgets/markdown_field.dart';
import 'package:narrchat/widgets/sidebar_panel.dart';

import 'helpers/notice_harness.dart';

/// 右侧栏阅读位置锚定测试（模块：SidebarPanel 的编辑切换 / 轮次替换）。
///
/// 预览与原始文本编辑高度不同；换轮次时生成字段长度也会变。断言同一段内容在
/// 切换前后的视口 Y 差不超过半屏（这里视口高 600 → 上限 300px）。

const String _targetHeading = '人物20目标';

/// 一份足够长、预览与编辑高度差异明显的人物列表。
String _characterState({int count = 40, String marker = _targetHeading}) {
  final sb = StringBuffer('# 主角\n');
  for (var i = 0; i < count; i++) {
    sb.writeln('## 人物$i${i == 20 ? marker.replaceFirst('人物20', '') : ''}');
    sb.writeln('- 属性A：值$i');
    sb.writeln('- 属性B：说明$i');
  }
  return sb.toString();
}

Round _round({int index = 1, String? worldState, String? characterState}) =>
    Round(
      uuid: 'gen-$index',
      bookUuid: 'book-1',
      roundIndex: index,
      worldState: worldState ?? '- 地点：青云宗\n- 掌门：苏清月',
      characterState: characterState ?? _characterState(),
      memorySummary: '- 第$index轮｜第一天｜概括',
      currentTime: '第 $index 天 午时',
    );

Future<ValueNotifier<Round?>> _pumpPanel(
  WidgetTester tester,
  Round round,
) async {
  final current = ValueNotifier<Round?>(round);
  await tester.pumpWidget(
    MaterialApp(
      theme: NarrChatTheme.light,
      builder: floatingNoticeBuilder(),
      home: Scaffold(
        body: SizedBox(
          width: 380,
          height: 600,
          child: ValueListenableBuilder<Round?>(
            valueListenable: current,
            builder: (context, value, _) => SidebarPanel(
              round: value,
              isHistoryView: false,
              onSaveField: (r, f, v) async => true,
              onBackToCurrent: () {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return current;
}

/// 指定模块的吸顶标题栏（【编辑】按钮所在处）。
Finder _sectionHeader(String label) => find.ancestor(
  of: find.text(label),
  matching: find.byType(SliverPersistentHeader),
);

/// 把某个预览文本滚到视口中线，便于比较切换前后的“同一段”。
Future<double> _centerOn(WidgetTester tester, Finder finder) async {
  await Scrollable.ensureVisible(
    tester.element(finder),
    alignment: 0.5,
    duration: Duration.zero,
  );
  await tester.pumpAndSettle();
  return tester.getTopLeft(finder).dy;
}

/// 原始文本编辑框中指定字符偏移对应的全局 y。
double _caretGlobalTop(WidgetTester tester, Finder textFieldScope, int offset) {
  final editable = find.descendant(
    of: textFieldScope,
    matching: find.byType(EditableText),
  );
  expect(editable, findsOneWidget);
  final state = tester.state<EditableTextState>(editable);
  final box = state.renderEditable;
  final caret = box.getLocalRectForCaret(TextPosition(offset: offset));
  return box.localToGlobal(caret.topLeft).dy;
}

void main() {
  testWidgets('进入编辑 / 保存退出：目标人物仍在半屏内', (tester) async {
    final state = _characterState();
    await _pumpPanel(tester, _round(characterState: state));

    final target = find.text(_targetHeading);
    expect(target, findsOneWidget);
    final beforeTop = await _centerOn(tester, target);

    // 预览 → 原始文本编辑。
    await tester.tap(
      find.descendant(of: _sectionHeader('角色状态'), matching: find.text('编辑')),
    );
    await tester.pumpAndSettle();

    final editor = find.byType(MarkdownCollapsibleEditor);
    final rawOffset = state.indexOf('## $_targetHeading');
    expect(rawOffset, greaterThan(0));
    final caretTop = _caretGlobalTop(tester, editor, rawOffset);
    expect(
      (caretTop - beforeTop).abs(),
      lessThan(300),
      reason:
          '进入编辑后，对应到目标人物的原始文本位置不应跑出半屏，'
          '实际差 ${(caretTop - beforeTop).abs().toStringAsFixed(1)}px',
    );

    // 编辑 → 预览（保存退出）。
    await tester.tap(
      find.descendant(of: _sectionHeader('角色状态'), matching: find.text('保存')),
    );
    await tester.pumpAndSettle();
    final afterTop = tester.getTopLeft(find.text(_targetHeading)).dy;
    expect(
      (afterTop - beforeTop).abs(),
      lessThan(300),
      reason:
          '退出编辑后目标人物应回到进入前的半屏范围内，'
          '实际差 ${(afterTop - beforeTop).abs().toStringAsFixed(1)}px',
    );
  });

  testWidgets('取消编辑退出：目标段落仍在半屏内', (tester) async {
    const marker = '目标世界段落';
    final world = StringBuffer('- 地点：青云宗\n');
    for (var i = 0; i < 120; i++) {
      world.writeln('## 章节$i${i == 60 ? marker : ''}');
      world.writeln('- 说明$i：内容足够长，保证侧栏可滚动。');
      world.writeln();
    }
    await _pumpPanel(tester, _round(worldState: world.toString()));

    final target = find.textContaining(marker, findRichText: true);
    expect(target, findsOneWidget);
    final beforeTop = await _centerOn(tester, target);

    await tester.tap(
      find.descendant(of: _sectionHeader('世界状态'), matching: find.text('编辑')),
    );
    await tester.pumpAndSettle();
    final editor = find.byType(MarkdownField);
    expect(
      find.descendant(of: editor, matching: find.byType(EditableText)),
      findsOneWidget,
    );

    await tester.tap(
      find.descendant(of: _sectionHeader('世界状态'), matching: find.text('取消')),
    );
    await tester.pumpAndSettle();

    final afterTop = tester
        .getTopLeft(find.textContaining(marker, findRichText: true))
        .dy;
    expect(
      (afterTop - beforeTop).abs(),
      lessThan(300),
      reason:
          '取消编辑后目标段落应留在半屏范围内，'
          '实际差 ${(afterTop - beforeTop).abs().toStringAsFixed(1)}px',
    );
  });

  testWidgets('生成后轮次内容长度变化：正在看的模块位置不跳半屏', (tester) async {
    final current = await _pumpPanel(tester, _round(index: 1));
    final target = find.text(_targetHeading);
    expect(target, findsOneWidget);
    final beforeTop = await _centerOn(tester, target);

    // 新轮次前面的世界状态显著变长（模拟生成完成后正文 / 状态落库）。
    final longWorld = List.generate(
      80,
      (i) => '- 世界变化$i：这一行用于拉开目标模块之前的高度。',
    ).join('\n');
    current.value = _round(index: 2, worldState: longWorld);
    await tester.pumpAndSettle();

    final afterTop = tester.getTopLeft(find.text(_targetHeading)).dy;
    expect(
      (afterTop - beforeTop).abs(),
      lessThan(300),
      reason:
          '轮次替换后目标人物不应跑出半屏，'
          '实际差 ${(afterTop - beforeTop).abs().toStringAsFixed(1)}px',
    );
  });
}
