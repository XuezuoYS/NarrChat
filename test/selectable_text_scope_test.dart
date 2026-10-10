import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/markdown_preview.dart';

import 'helpers/selection_harness.dart';

/// 统一选中容器（[SelectableTextArea]）与容器级作用域（[SelectableTextScope]）
/// 的隔离层契约。
///
/// 核心约定：两个 `SelectableRegion` 互为**硬边界**（父区域选不进子区域、
/// 子区域也选不出去，见 `widgets/selectable_region.dart:189-192`），所以
/// 「整块内容跨子项连续选中」必须让子项不再自建区域。本文件用 A/B 对照证明：
/// 同一个拖动在「各自建区域」时选区被截断，在作用域内可跨子项延续。
///
/// 选中结果以**系统剪贴板**为外部锚点读取（与 `chat_bubble_test` 同法）：
/// 选中 → `CopySelectionTextIntent.copy` → 拦截 `Clipboard.setData`。

const String _alphaText = 'alpha alpha alpha alpha alpha alpha alpha '
    'alpha alpha alpha alpha alpha alpha alpha alpha';
const String _betaText = 'beta beta beta beta beta beta beta '
    'beta beta beta beta beta beta beta beta';

/// 两段可选中正文上下排列（窄宽迫使多行，拖动会跨行跨块）。
Widget _stacked() => const SizedBox(
      width: 320,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          PlainTextPreview(data: _alphaText),
          SizedBox(height: 24),
          PlainTextPreview(data: _betaText),
        ],
      ),
    );

Widget _wrap(Widget child) => MaterialApp(
      theme: NarrChatTheme.light,
      home: Scaffold(body: Align(alignment: Alignment.topLeft, child: child)),
    );

/// 从 [_alphaText] 第 6 字选到 [_betaText] 第 6 字，返回复制到的文本
/// （无选中内容时返回 null）。
Future<String?> copyAcrossBlocks(
  WidgetTester tester,
  List<String> copied, {
  required PointerDeviceKind kind,
}) async {
  final start = textOffsetToPosition(tester, _alphaText, 6);
  final end = textOffsetToPosition(tester, _betaText, 6);
  final gesture = await tester.startGesture(start, kind: kind);
  addTearDown(gesture.removePointer);
  if (kind == PointerDeviceKind.mouse) {
    await tester.pump();
  } else {
    // 触屏需先越过长按阈值才开始选择。
    await tester.pump(const Duration(milliseconds: 600));
  }
  await gesture.moveTo(end);
  await tester.pump();
  await gesture.up();
  await tester.pump();

  copySelection(tester, find.text(_alphaText));
  await tester.pump();
  return copied.isEmpty ? null : copied.last;
}

void main() {
  testWidgets('作用域外：每个可选中容器各自建立一个区域', (tester) async {
    await tester.pumpWidget(_wrap(_stacked()));
    await tester.pumpAndSettle();

    expect(find.byType(SelectionArea), findsNWidgets(2));
    expect(find.byType(SelectableRegion), findsNWidgets(2));
  });

  testWidgets('作用域内：子项不再自建区域，整块只有一个且覆盖全部子项', (tester) async {
    await tester.pumpWidget(_wrap(SelectableTextScope(child: _stacked())));
    await tester.pumpAndSettle();

    expect(find.byType(SelectionArea), findsOneWidget);
    expect(find.byType(SelectableRegion), findsOneWidget);
    // 唯一的区域同时是两段正文的祖先（这正是「跨子项选中」的前提）。
    for (final text in const [_alphaText, _betaText]) {
      expect(
        find.ancestor(
          of: find.text(text),
          matching: find.byType(SelectableRegion),
        ),
        findsOneWidget,
        reason: '应位于统一区域内',
      );
    }
  });

  testWidgets('作用域内：鼠标拖动跨子项选中（对照：无作用域时选区被区域边界截断）',
      (tester) async {
    final copied = mockClipboard(tester);

    // 对照（改造前的形态）：两段正文各自一个区域。
    await tester.pumpWidget(_wrap(_stacked()));
    await tester.pumpAndSettle();
    final split = await copyAcrossBlocks(
      tester,
      copied,
      kind: PointerDeviceKind.mouse,
    );
    expect(split, isNotNull, reason: '对照场景也应产生选区（只是被截断）');
    expect(split, contains('alpha'));
    expect(
      split,
      isNot(contains('beta')),
      reason: '硬边界：子区域选不出父区域，选区止于第一段末尾',
    );

    // 作用域内：一个区域覆盖两段，选区跨越子项。
    await tester.pumpWidget(_wrap(SelectableTextScope(child: _stacked())));
    await tester.pumpAndSettle();
    final merged = await copyAcrossBlocks(
      tester,
      copied,
      kind: PointerDeviceKind.mouse,
    );
    expect(merged, isNotNull);
    expect(merged, contains('alpha'));
    expect(merged, contains('beta'), reason: '作用域内选区应延续到第二段');
    expect(
      merged!.indexOf('alpha'),
      lessThan(merged.indexOf('beta')),
      reason: '拼接顺序应按视觉顺序',
    );
  });

  testWidgets('作用域内：触屏长按拖动同样可跨子项选中', (tester) async {
    final copied = mockClipboard(tester);
    await tester.pumpWidget(_wrap(SelectableTextScope(child: _stacked())));
    await tester.pumpAndSettle();

    final selected = await copyAcrossBlocks(
      tester,
      copied,
      kind: PointerDeviceKind.touch,
    );
    expect(selected, isNotNull);
    expect(selected, contains('alpha'));
    expect(selected, contains('beta'));
  });

  testWidgets('作用域抑制默认右键 / 长按菜单（与 SelectableTextArea 同约定）',
      (tester) async {
    await tester.pumpWidget(_wrap(SelectableTextScope(child: _stacked())));
    await tester.pumpAndSettle();

    final region = tester.widget<SelectableRegion>(
      find.byType(SelectableRegion),
    );
    final state = tester.state<SelectableRegionState>(
      find.byType(SelectableRegion),
    );
    expect(region.contextMenuBuilder, isNotNull);
    final menu = region.contextMenuBuilder!(
      tester.element(find.text(_alphaText)),
      state,
    );
    expect(menu, isA<SizedBox>(), reason: '默认菜单被抑制，避免与气泡菜单冲突');
  });

  testWidgets('作用域内的 SelectableTextArea 是纯代理：不改变布局与文本外观',
      (tester) async {
    await tester.pumpWidget(_wrap(_stacked()));
    await tester.pumpAndSettle();
    final outsideSize = tester.getSize(find.text(_alphaText));

    await tester.pumpWidget(_wrap(SelectableTextScope(child: _stacked())));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.text(_alphaText)), outsideSize);
  });
}
