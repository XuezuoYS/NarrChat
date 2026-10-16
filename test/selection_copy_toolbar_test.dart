import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/markdown_preview.dart';
import 'package:narrchat/widgets/selection_toolbar.dart';

import 'helpers/notice_harness.dart';
import 'helpers/selection_harness.dart';

/// 选中文本后**自动弹出**的「复制 / 全选」横排工具条（隔离层）。
///
/// 被测对象：`lib/widgets/markdown_preview.dart` 的 `_SelectionCopyToolbar`。
/// 断言重点：
/// - 触发口径：鼠标拖拽 / 双击、触屏双击（含双击后拖动）弹；触屏长按、鼠标右键、
///   原地单击不弹（那些手势归气泡业务菜单）；
/// - 形态：恒为横排横条（不是右键那样的竖排列表），白底、字号 14；
/// - 非模态：弹出后**原选区必须保留**（模态路由会夺焦点，框架失焦即清空选区）。

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

/// 最小宿主页（[pumpNoticeApp] 只提供 MaterialApp，页面本身需自带 Scaffold）。
Widget _body(Widget child) => Scaffold(
      body: Align(alignment: Alignment.topLeft, child: child),
    );

Widget _wrap(Widget child) =>
    MaterialApp(theme: NarrChatTheme.light, home: _body(child));

/// 从 [start] 拖到 [end] 后抬手。
Future<void> _dragSelect(
  WidgetTester tester,
  Offset start,
  Offset end, {
  required PointerDeviceKind kind,
}) async {
  final gesture = await tester.startGesture(start, kind: kind);
  addTearDown(gesture.removePointer);
  await tester.pump();
  await gesture.moveTo(end);
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
}

/// 触屏双击 [position] 处的词（与框架的双击窗口一致：两击间隔 < 300ms）。
Future<void> _doubleTapAt(WidgetTester tester, Offset position) async {
  await tester.tapAt(position, kind: PointerDeviceKind.touch);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tapAt(position, kind: PointerDeviceKind.touch);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('鼠标拖拽选中后自动弹出工具条，含「复制」与「全选」', (tester) async {
    await tester.pumpWidget(_wrap(const PlainTextPreview(data: _alphaText)));
    await tester.pumpAndSettle();

    await _dragSelect(
      tester,
      textOffsetToPosition(tester, _alphaText, 0),
      textOffsetToPosition(tester, _alphaText, 5),
      kind: PointerDeviceKind.mouse,
    );

    expect(find.text('复制'), findsOneWidget);
    expect(find.text('全选'), findsOneWidget);
  });

  testWidgets('点「复制」把选中文本写入剪贴板，并给出「已复制」提示', (tester) async {
    final copied = mockClipboard(tester);
    final center = await pumpNoticeApp(
      tester,
      home: _body(const PlainTextPreview(data: _alphaText)),
    );

    await _dragSelect(
      tester,
      textOffsetToPosition(tester, _alphaText, 0),
      textOffsetToPosition(tester, _alphaText, 5),
      kind: PointerDeviceKind.mouse,
    );
    expect(find.text('复制'), findsOneWidget);

    await tester.tap(find.text('复制'));
    await tester.pumpAndSettle();

    expect(copied, hasLength(1));
    expect(copied.single, contains('alpha'));
    expect(find.text('复制'), findsNothing, reason: '复制后工具条收起');
    expect(find.text('已复制'), findsOneWidget);

    drainNotices(center);
    await tester.pump();
  });

  testWidgets('触屏双击选词后自动弹出工具条', (tester) async {
    await tester.pumpWidget(_wrap(const PlainTextPreview(data: _alphaText)));
    await tester.pumpAndSettle();

    await _doubleTapAt(tester, textOffsetToPosition(tester, _alphaText, 2));

    expect(find.text('复制'), findsOneWidget);
  });

  testWidgets('鼠标双击选词后同样自动弹出工具条', (tester) async {
    await tester.pumpWidget(_wrap(const PlainTextPreview(data: _alphaText)));
    await tester.pumpAndSettle();

    final position = textOffsetToPosition(tester, _alphaText, 2);
    await tester.tapAt(position, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(position, kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();

    expect(find.text('复制'), findsOneWidget);
  });

  testWidgets('触屏双击后拖动扩展选区（按词），抬手同样弹工具条', (tester) async {
    final copied = mockClipboard(tester);
    await tester.pumpWidget(_wrap(const PlainTextPreview(data: _alphaText)));
    await tester.pumpAndSettle();

    final start = textOffsetToPosition(tester, _alphaText, 2);
    // 第一击：单击。
    await tester.tapAt(start, kind: PointerDeviceKind.touch);
    await tester.pump(const Duration(milliseconds: 50));
    // 第二击按住并拖动：框架按「词」粒度扩展选区（Android 上支持双击加拖动）。
    final gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.touch,
    );
    addTearDown(gesture.removePointer);
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.moveTo(textOffsetToPosition(tester, _alphaText, 20));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('复制'), findsOneWidget);
    await tester.tap(find.text('复制'));
    await tester.pumpAndSettle();

    expect(copied, hasLength(1));
    expect(
      RegExp('alpha').allMatches(copied.single).length,
      greaterThan(1),
      reason: '双击后拖动应选中多个词，而不是只选一个词',
    );
  });

  testWidgets('工具条弹出后原选区保留（可继续复制 / 拖手柄调整）', (tester) async {
    // 真机上前台运行时失焦会清空选区（`SelectableRegionState._handleFocusChanged`
    // 只在 `lifecycleState == resumed` 时 `clearSelection()`）；测试环境默认没有
    // 生命周期状态，这里显式还原，否则复现不出「工具条一弹、框选就没了」。
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    addTearDown(
      () => tester.binding
          .handleAppLifecycleStateChanged(AppLifecycleState.detached),
    );

    final copied = mockClipboard(tester);
    await tester.pumpWidget(_wrap(const PlainTextPreview(data: _alphaText)));
    await tester.pumpAndSettle();

    await _dragSelect(
      tester,
      textOffsetToPosition(tester, _alphaText, 0),
      textOffsetToPosition(tester, _alphaText, 5),
      kind: PointerDeviceKind.mouse,
    );
    expect(find.text('复制'), findsOneWidget);

    // 工具条必须是非模态的：弹出后选区仍在，此时直接「复制当前选中内容」
    // 仍应拿到原选区文本（模态路由会夺焦点 → 框架失焦即 clearSelection）。
    copySelection(tester, find.text(_alphaText));
    await tester.pump();

    expect(copied, hasLength(1), reason: '工具条弹出后选区必须保留');
    expect(copied.single, contains('alpha'));
  });

  testWidgets('工具条是横排的（两个按钮在同一行）', (tester) async {
    await tester.pumpWidget(_wrap(const PlainTextPreview(data: _alphaText)));
    await tester.pumpAndSettle();

    await _dragSelect(
      tester,
      textOffsetToPosition(tester, _alphaText, 0),
      textOffsetToPosition(tester, _alphaText, 5),
      kind: PointerDeviceKind.mouse,
    );

    final copyRect = tester.getRect(find.text('复制'));
    final selectAllRect = tester.getRect(find.text('全选'));
    expect(
      copyRect.center.dy,
      closeTo(selectAllRect.center.dy, 1),
      reason: '横条式工具条：两项在同一行，而不是右键菜单那样的竖排列表',
    );
    expect(copyRect.center.dx, lessThan(selectAllRect.center.dx));
  });

  testWidgets('工具条浮在选区上方（上方有空间时不压住正文）', (tester) async {
    // 顶部留白：给工具条留出「选区上方」的落点（空间不足时框架会翻到下方）。
    await tester.pumpWidget(
      MaterialApp(
        theme: NarrChatTheme.light,
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.only(top: 200),
            child: Align(
              alignment: Alignment.topLeft,
              child: const PlainTextPreview(data: _alphaText),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _dragSelect(
      tester,
      textOffsetToPosition(tester, _alphaText, 0),
      textOffsetToPosition(tester, _alphaText, 5),
      kind: PointerDeviceKind.mouse,
    );

    final selectionRect = tester.getRect(find.text(_alphaText));
    final toolbarRect = tester.getRect(find.text('复制'));
    expect(
      toolbarRect.bottom,
      lessThanOrEqualTo(selectionRect.top),
      reason: '工具条应在选区上方，而不是盖在选区上',
    );
  });

  testWidgets('横条样式：白底、字号 14、上下留白（与气泡菜单同一口径）', (tester) async {
    await tester.pumpWidget(_wrap(const PlainTextPreview(data: _alphaText)));
    await tester.pumpAndSettle();

    await _dragSelect(
      tester,
      textOffsetToPosition(tester, _alphaText, 0),
      textOffsetToPosition(tester, _alphaText, 5),
      kind: PointerDeviceKind.mouse,
    );

    // 字号取自实际渲染（TextButton 通过 DefaultTextStyle 下发，Text.style 是空的）。
    final paragraph = tester.renderObject<RenderParagraph>(find.text('复制'));
    expect(paragraph.text.style?.fontSize, 14);

    // 卡片是 [SelectionToolbar] 的第一个 Material（内部才是各按钮的 Material）。
    final card = tester.widget<Material>(
      find
          .descendant(
            of: find.byType(SelectionToolbar),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(
      card.color,
      NarrChatColors.light.surface,
      reason: '横条底色应为白色（浅色主题的 surface 即纯白），不是灰色',
    );

    final cardSize = tester.getSize(
      find
          .descendant(
            of: find.byType(SelectionToolbar),
            matching: find.byType(Material),
          )
          .first,
    );
    final buttonHeight = tester
        .getSize(find.widgetWithText(TextButton, '复制'))
        .height;
    expect(buttonHeight, greaterThanOrEqualTo(30), reason: '按钮上下留白');
    expect(
      cardSize.height,
      greaterThanOrEqualTo(buttonHeight + 8),
      reason: '卡片上下各 4 的留白',
    );
  });

  testWidgets('Windows 平台下同样是横排（框架自带工具栏在桌面是竖排列表）', (tester) async {
    // 框架的 `AdaptiveTextSelectionToolbar` 按 `Theme.of(context).platform` 分派：
    // Windows / Linux / macOS 走 `DesktopTextSelectionToolbar`，它内部是 `Column`
    // （竖排列表）——正是用户截图里的形态。本用例以桌面主题复现该条件，锁住
    // 「自绘横条与平台无关」。
    await tester.pumpWidget(
      MaterialApp(
        theme: NarrChatTheme.light.copyWith(platform: TargetPlatform.windows),
        home: _body(const PlainTextPreview(data: _alphaText)),
      ),
    );
    await tester.pumpAndSettle();

    await _dragSelect(
      tester,
      textOffsetToPosition(tester, _alphaText, 0),
      textOffsetToPosition(tester, _alphaText, 5),
      kind: PointerDeviceKind.mouse,
    );

    final copyRect = tester.getRect(find.text('复制'));
    final selectAllRect = tester.getRect(find.text('全选'));
    expect(
      copyRect.center.dy,
      closeTo(selectAllRect.center.dy, 1),
      reason: 'Windows 上也是横排横条，而不是竖排列表',
    );
  });

  testWidgets('收起后再次选中仍会弹出（不会只弹一次）', (tester) async {
    await tester.pumpWidget(_wrap(const PlainTextPreview(data: _alphaText)));
    await tester.pumpAndSettle();

    await _dragSelect(
      tester,
      textOffsetToPosition(tester, _alphaText, 0),
      textOffsetToPosition(tester, _alphaText, 5),
      kind: PointerDeviceKind.mouse,
    );
    expect(find.text('复制'), findsOneWidget);

    // 点「复制」收起工具条（选区保留），再选一次应当**重新弹出**。
    await tester.tap(find.text('复制'));
    await tester.pumpAndSettle();
    expect(find.text('复制'), findsNothing);

    await _dragSelect(
      tester,
      textOffsetToPosition(tester, _alphaText, 6),
      textOffsetToPosition(tester, _alphaText, 12),
      kind: PointerDeviceKind.mouse,
    );
    expect(find.text('复制'), findsOneWidget, reason: '第二次选中同样要弹');
  });

  testWidgets('触屏：双击 → 收起 → 再双击仍会弹出', (tester) async {
    await tester.pumpWidget(_wrap(const PlainTextPreview(data: _alphaText)));
    await tester.pumpAndSettle();

    final position = textOffsetToPosition(tester, _alphaText, 2);
    await _doubleTapAt(tester, position);
    expect(find.text('复制'), findsOneWidget);

    // 点别处收起（顺带清掉选区）。随后停一拍：真实使用里两次双击之间本就有停顿，
    // 否则框架会把连续的点击串成三击 / 四击（触屏三击不选词，反而清掉选区）。
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.text('复制'), findsNothing);
    await tester.pump(const Duration(milliseconds: 600));

    await _doubleTapAt(tester, position);
    expect(find.text('复制'), findsOneWidget, reason: '第二次双击同样要弹');
  });

  testWidgets('拖选区手柄（指针落在区域外）改完选区，抬手补弹工具条', (tester) async {
    await tester.pumpWidget(_wrap(const PlainTextPreview(data: _alphaText)));
    await tester.pumpAndSettle();

    await _dragSelect(
      tester,
      textOffsetToPosition(tester, _alphaText, 0),
      textOffsetToPosition(tester, _alphaText, 5),
      kind: PointerDeviceKind.mouse,
    );
    // 抓手柄前用户先点了别处 → 工具条已收起。
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.text('复制'), findsNothing);

    // 选区手柄是 Overlay 上的独立 widget，指针事件**不会**进选中区域子树：
    // 这里在正文下方（区域外）按下，并在按住期间改变选区（等价于拖手柄）。
    final gesture = await tester.startGesture(
      textOffsetToPosition(tester, _alphaText, 5) + const Offset(0, 60),
      kind: PointerDeviceKind.touch,
    );
    addTearDown(gesture.removePointer);
    await tester.pump();
    Actions.invoke(
      tester.element(find.text(_alphaText)),
      const SelectAllTextIntent(SelectionChangedCause.toolbar),
    );
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      find.text('复制'),
      findsOneWidget,
      reason: '拖手柄改完选区，抬手应补弹工具条',
    );
  });

  testWidgets('已有选中内容时原地单击不再弹工具条（单击只是收起选区）', (tester) async {
    await tester.pumpWidget(_wrap(const PlainTextPreview(data: _alphaText)));
    await tester.pumpAndSettle();

    await _dragSelect(
      tester,
      textOffsetToPosition(tester, _alphaText, 0),
      textOffsetToPosition(tester, _alphaText, 5),
      kind: PointerDeviceKind.mouse,
    );
    // 复制后工具条收起、选区保留（本组件不主动清选区）。
    await tester.tap(find.text('复制'));
    await tester.pumpAndSettle();
    expect(find.text('复制'), findsNothing);

    // 在正文上原地单击（未拖拽）：不该因为「上一次的选区还在」再弹一次。
    await tester.tapAt(
      textOffsetToPosition(tester, _alphaText, 3),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();

    expect(find.text('复制'), findsNothing);
  });

  testWidgets('触屏长按不弹选中工具条（长按归气泡业务菜单）', (tester) async {
    await tester.pumpWidget(_wrap(const PlainTextPreview(data: _alphaText)));
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(
      textOffsetToPosition(tester, _alphaText, 2),
      kind: PointerDeviceKind.touch,
    );
    addTearDown(gesture.removePointer);
    // 越过框架长按阈值（500ms）：长按会选中一个词，但工具条不该由本组件弹出。
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('复制'), findsNothing);
    expect(find.text('全选'), findsNothing);
  });

  testWidgets('鼠标右键不弹选中工具条（右键归业务菜单）', (tester) async {
    await tester.pumpWidget(_wrap(const PlainTextPreview(data: _alphaText)));
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(
      textOffsetToPosition(tester, _alphaText, 2),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    addTearDown(gesture.removePointer);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('复制'), findsNothing);
  });

  testWidgets('单击（无选中内容）不弹工具条', (tester) async {
    await tester.pumpWidget(_wrap(const PlainTextPreview(data: _alphaText)));
    await tester.pumpAndSettle();

    await tester.tapAt(
      textOffsetToPosition(tester, _alphaText, 2),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();

    expect(find.text('复制'), findsNothing);
  });

  testWidgets('作用域内跨块拖拽选中同样自动弹工具条，并可复制跨块文本', (tester) async {
    final copied = mockClipboard(tester);
    await tester.pumpWidget(_wrap(SelectableTextScope(child: _stacked())));
    await tester.pumpAndSettle();

    await _dragSelect(
      tester,
      textOffsetToPosition(tester, _alphaText, 6),
      textOffsetToPosition(tester, _betaText, 6),
      kind: PointerDeviceKind.mouse,
    );
    expect(find.text('复制'), findsOneWidget);

    await tester.tap(find.text('复制'));
    await tester.pumpAndSettle();

    expect(copied, hasLength(1));
    expect(copied.single, contains('alpha'));
    expect(copied.single, contains('beta'), reason: '选区跨块，复制内容应跨块');
  });

  testWidgets('点「全选」后工具条保持可用，接着复制得到整块内容', (tester) async {
    final copied = mockClipboard(tester);
    await tester.pumpWidget(_wrap(const PlainTextPreview(data: _alphaText)));
    await tester.pumpAndSettle();

    // 先只选中开头几个词（复制内容应明显少于全选）。
    await _dragSelect(
      tester,
      textOffsetToPosition(tester, _alphaText, 0),
      textOffsetToPosition(tester, _alphaText, 5),
      kind: PointerDeviceKind.mouse,
    );
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();

    expect(find.text('复制'), findsOneWidget, reason: '全选后工具条仍可用（可接着复制）');
    await tester.tap(find.text('复制'));
    await tester.pumpAndSettle();

    expect(copied, hasLength(1));
    expect(copied.single.trim(), _alphaText.trim());
  });

  testWidgets('工具条弹出后点击别处即收起（无遮罩，只是一次普通点击）', (tester) async {
    await tester.pumpWidget(_wrap(const PlainTextPreview(data: _alphaText)));
    await tester.pumpAndSettle();

    await _dragSelect(
      tester,
      textOffsetToPosition(tester, _alphaText, 0),
      textOffsetToPosition(tester, _alphaText, 5),
      kind: PointerDeviceKind.mouse,
    );
    expect(find.text('复制'), findsOneWidget);

    // 点工具条之外的任意处：TapRegion 收起工具条（不铺模态遮罩）。
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    expect(find.text('复制'), findsNothing);
  });
}
