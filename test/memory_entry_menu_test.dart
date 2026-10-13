import 'package:flutter/gestures.dart' show kSecondaryMouseButton, PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/utils/memory_entry_format.dart';
import 'package:narrchat/widgets/memory_summary_editor.dart';

import 'helpers/notice_harness.dart';
import 'helpers/selection_harness.dart';

/// 记忆条目卡片的**长按 / 右键扩展菜单**（隔离层）。
///
/// 菜单内容与落点口径的单一真源：
/// - 三项文案 = [kMemoryEntryCopyTimeLabel] / [kMemoryEntryCopyContentLabel] /
///   [kMemoryEntryJumpLabel]（本文件用同一常量断言，改文案不会让用例假绿）；
/// - 「复制时间」写入剪贴板的文本 = [memoryEntryTimeText]（合并条目即原样的
///   时间区间，时间缺失时与卡片展示一致）；
/// - 「跳转至对应条目」回调的轮次 = [MemoryEntry.round]，合并条目取区间**起始轮**。
///
/// 对话页集成层（跳转真的把对话区滚到该轮起点）见
/// `chat_memory_entry_jump_test.dart`；条目解析本身见 `memory_entry_format_test.dart`。

/// 条目卡片徽标文案（`第N轮` / `第11~15轮`）。
Finder _badge(String label) => find.text(label);

/// 一条记忆条目的时间与内容（合并条目的时间即区间文本）。
const String _singleTime = '2026年10月1日03:32:31';
const String _singleContent = '主角初入宗门。';
const String _mergedTime = '仙历十四年五月二十日 ~ 仙历十四年七月八日';
const String _mergedContent = '这期间的事。';

/// 预置两轮：第 1 轮为单轮条目，第 11~15 轮为合并条目。
const String _twoEntries = '- 1 | $_singleTime | $_singleContent\n'
    '- 11~15 | $_mergedTime | $_mergedContent';

/// 一张条目卡片的外框（承载长按 / 右键交互的 `Container`）。
///
/// 用条目内容文本往上找到它的卡片外框，避开徽标自身那层 `Container`。
Finder _entryCard(String contentText) => find
    .ancestor(
      of: find.text(contentText),
      matching: find.byWidgetPredicate(
        (w) => w is Container && w.decoration is BoxDecoration,
      ),
    )
    .first;

/// 弹出菜单里对应文案的菜单项外框（菜单定位的最近锚点）。
Finder _menuItem(String label) => find
    .ancestor(
      of: find.text(label),
      matching: find.byType(PopupMenuItem<MemoryEntryAction>),
    )
    .first;

/// 以固定尺寸 pump 一个 `MemorySummaryEditor`，返回被记录的跳转调用。
///
/// 不想让编辑区被裁切时，条目卡片必须落在可命中的坐标内
/// （点击/右键坐标由 [WidgetTester.getCenter] 反推父级局部偏移）：
/// 默认用固定高度的 `SizedBox`（不滚动）；需要「区块被滚出视口」的场景传
/// [scrollable] = true，改用固定高度的可滚动区域包住编辑器。
Future<List<({int roundIndex, Offset entryAt})>> _pumpEditor(
  WidgetTester tester, {
  String text = _twoEntries,
  Size size = const Size(420, 620),
  bool scrollable = false,
}) async {
  final controller = TextEditingController(text: text);
  addTearDown(controller.dispose);
  final jumps = <({int roundIndex, Offset entryAt})>[];
  final editor = MemorySummaryEditor(
    controller: controller,
    showToolbar: false,
    onJumpToRound: (roundIndex, entryAt) =>
        jumps.add((roundIndex: roundIndex, entryAt: entryAt)),
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: NarrChatTheme.light,
      // 悬浮通知宿主：复制成功提示走 `context.notices`，需有通知中心。
      builder: floatingNoticeBuilder(),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: scrollable
                ? SingleChildScrollView(child: editor)
                : editor,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return jumps;
}

/// 在 [target] 上模拟触屏长按（与 `tester.longPress` 等价的低层写法，
/// 便于按 `PointerDeviceKind.touch` 与 `BubblePointerListener` 对齐口径）。
///
/// [offsetInTarget] 非空时按「该控件左上角 + 偏移」落指，用来验证菜单跟随指针。
Future<void> _longPress(
  WidgetTester tester,
  Finder target, {
  Offset? offsetInTarget,
}) async {
  final gesture = await tester.startGesture(
    offsetInTarget == null
        ? tester.getCenter(target)
        : tester.getTopLeft(target) + offsetInTarget,
    kind: PointerDeviceKind.touch,
  );
  await tester.pump(const Duration(milliseconds: 700));
  await gesture.up();
  await tester.pumpAndSettle();
}

/// 在 [target] 上模拟桌面**右键**（`BubblePointerListener` 对鼠标右键立即响应）。
///
/// [offsetInTarget] 非空时按「该控件左上角 + 偏移」按下右键，用来验证菜单在
/// **鼠标处**弹出（用户右键的位置即菜单弹出位置）。
Future<void> _secondaryClick(
  WidgetTester tester,
  Finder target, {
  Offset? offsetInTarget,
}) async {
  final position = offsetInTarget == null
      ? tester.getCenter(target)
      : tester.getTopLeft(target) + offsetInTarget;
  await tester.sendEventToBinding(
    PointerDownEvent(
      pointer: 91,
      position: position,
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    ),
  );
  await tester.sendEventToBinding(
    PointerUpEvent(pointer: 91, position: position, kind: PointerDeviceKind.mouse),
  );
  await tester.pumpAndSettle();
}

/// 选中菜单项并等菜单关闭、动作落地。
Future<void> _pick(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('长按条目卡片弹出三项菜单：复制时间 / 复制内容 / 跳转至对应条目', (tester) async {
    await _pumpEditor(tester);

    expect(find.text(kMemoryEntryCopyTimeLabel), findsNothing, reason: '未操作时不应有菜单');

    await _longPress(tester, _badge('第1轮'));

    expect(find.text(kMemoryEntryCopyTimeLabel), findsOneWidget);
    expect(find.text(kMemoryEntryCopyContentLabel), findsOneWidget);
    expect(find.text(kMemoryEntryJumpLabel), findsOneWidget);
  });

  testWidgets('桌面右键条目卡片同样弹出菜单', (tester) async {
    await _pumpEditor(tester);

    await _secondaryClick(tester, _badge('第1轮'));

    expect(find.text(kMemoryEntryCopyTimeLabel), findsOneWidget);
    expect(find.text(kMemoryEntryCopyContentLabel), findsOneWidget);
    expect(find.text(kMemoryEntryJumpLabel), findsOneWidget);
  });

  testWidgets('复制时间：写入剪贴板的是该条目时间', (tester) async {
    final copied = mockClipboard(tester);
    await _pumpEditor(tester);

    await _longPress(tester, _badge('第1轮'));
    await _pick(tester, kMemoryEntryCopyTimeLabel);

    expect(copied, [_singleTime]);
    await flushNotices(tester);
  });

  testWidgets('复制内容：写入剪贴板的是该条目概括', (tester) async {
    final copied = mockClipboard(tester);
    await _pumpEditor(tester);

    await _longPress(tester, _badge('第1轮'));
    await _pick(tester, kMemoryEntryCopyContentLabel);

    expect(copied, [_singleContent]);
    await flushNotices(tester);
  });

  testWidgets('时间缺失的条目：复制时间给卡片上显示的「（未标注时间）」', (tester) async {
    final copied = mockClipboard(tester);
    await _pumpEditor(tester, text: '- 1 |  | 主角初入宗门。');

    await _longPress(tester, _badge('第1轮'));
    await _pick(tester, kMemoryEntryCopyTimeLabel);

    expect(copied, ['（未标注时间）']);
    await flushNotices(tester);
  });

  testWidgets('合并条目：复制时间给整段时间区间，复制内容给该区间概括', (tester) async {
    final copied = mockClipboard(tester);
    await _pumpEditor(tester);

    await _longPress(tester, _badge('第11~15轮'));
    await _pick(tester, kMemoryEntryCopyTimeLabel);
    expect(copied, [_mergedTime], reason: '合并条目的时间本就是区间文本，原样复制');

    await _longPress(tester, _badge('第11~15轮'));
    await _pick(tester, kMemoryEntryCopyContentLabel);
    expect(copied, [_mergedTime, _mergedContent]);

    await flushNotices(tester);
  });

  testWidgets('菜单在鼠标右键处弹出，随右键位置变化（不固定对齐卡片左上角）', (tester) async {
    const rightClickAt = Offset(300, 20);
    await _pumpEditor(tester);
    final card = tester.getRect(_entryCard(_singleContent));
    final pointer = tester.getTopLeft(_entryCard(_singleContent)) + rightClickAt;
    expect(card.width, greaterThan(rightClickAt.dx + 20),
        reason: '右键位置必须落在卡片内部（否则点到别处）');

    await _secondaryClick(tester, _entryCard(_singleContent),
        offsetInTarget: rightClickAt);

    // 菜单项外框是菜单的最近锚点（`showMenu` 内部另加 8px 屏幕安全区），
    // 故对齐时留 8px 余量；关键是它落在**指针**处，而不是卡片左上角。
    final menuTopLeft = tester.getTopLeft(_menuItem(kMemoryEntryCopyTimeLabel));
    expect(menuTopLeft.dx, closeTo(pointer.dx, 8));
    expect(menuTopLeft.dy, closeTo(pointer.dy, 8));
    // 与「对齐卡片左上角」的旧口径必须能区分开。
    expect((menuTopLeft.dx - card.left).abs(), greaterThan(50));

    await tester.tapAt(const Offset(4, 4)); // 关掉菜单
    await tester.pumpAndSettle();

    // 换一个右键位置：菜单跟着走。
    const rightClickAt2 = Offset(120, 44);
    final pointer2 =
        tester.getTopLeft(_entryCard(_singleContent)) + rightClickAt2;
    await _secondaryClick(tester, _entryCard(_singleContent),
        offsetInTarget: rightClickAt2);
    final menuTopLeft2 = tester.getTopLeft(_menuItem(kMemoryEntryCopyTimeLabel));
    expect(menuTopLeft2.dx, closeTo(pointer2.dx, 8));
    expect(menuTopLeft2.dy, closeTo(pointer2.dy, 8));
    expect((menuTopLeft2.dx - menuTopLeft.dx).abs(), greaterThan(100),
        reason: '两次右键位置不同，菜单水平位置应随之变化');
  });

  testWidgets('触屏长按在手指处弹出菜单（长按点而非卡片左上角）', (tester) async {
    await _pumpEditor(tester);
    final card = tester.getRect(_entryCard(_mergedContent));
    // 长按点选在卡片中下部：与卡片顶边拉开足够距离，便于区分两种口径。
    final finger = Offset(
      tester.getTopLeft(_entryCard(_mergedContent)).dx + card.width - 30,
      tester.getTopLeft(_entryCard(_mergedContent)).dy + 40,
    );

    await _longPress(
      tester,
      _entryCard(_mergedContent),
      offsetInTarget: Offset(card.width - 30, 40),
    );

    final menuTopLeft = tester.getTopLeft(_menuItem(kMemoryEntryCopyTimeLabel));
    expect(menuTopLeft.dx, closeTo(finger.dx, 8));
    expect(menuTopLeft.dy, closeTo(finger.dy, 8));
    expect((menuTopLeft.dy - card.top).abs(), greaterThan(20),
        reason: '菜单应落在手指处，而不是卡片顶边');
  });

  testWidgets('跳转至对应条目：回调收到该条目轮次与触发菜单的指针坐标', (tester) async {
    final jumps = await _pumpEditor(tester);
    final pointer =
        tester.getTopLeft(_entryCard(_singleContent)) + const Offset(200, 18);

    await _secondaryClick(tester, _entryCard(_singleContent),
        offsetInTarget: const Offset(200, 18));
    await _pick(tester, kMemoryEntryJumpLabel);

    expect(jumps, hasLength(1));
    expect(jumps.single.roundIndex, 1);
    // 契约里的位置 = 触发菜单的指针坐标（菜单弹出位置与之一致）。
    expect(jumps.single.entryAt.dx, closeTo(pointer.dx, 0.5));
    expect(jumps.single.entryAt.dy, closeTo(pointer.dy, 0.5));
  });

  testWidgets('条目所在区块滚出视口后，菜单仍弹在指针处（不飞到屏幕顶部）', (tester) async {
    // 20 条条目、视口只有 300px 高：上面的卡片必然被滚出视口。
    final text = [
      for (var i = 1; i <= 20; i++) '- $i | 第$i天 午时 | 第$i轮概括。',
    ].join('\n');
    await _pumpEditor(
      tester,
      text: text,
      size: const Size(420, 300),
      scrollable: true,
    );

    // 滚到底：此时「记忆总结区块」的顶部远在视口上方。
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -3000));
    await tester.pumpAndSettle();

    // 被点的卡片：视口内**完全可见的最靠上**一条；其上一条必须已滚出视口
    // （这就是「区块被滚出去了、组件原点已不可用」的前提）。
    //
    // 可见性必须对**滚动视口**（固定不动的 `SingleChildScrollView`）判定，
    // 不能对编辑器自身：编辑器整体已被滚出视口，它的原点也跟着跑到视口外。
    final viewport = tester.getRect(find.byType(SingleChildScrollView));
    var index = 0;
    for (var i = 1; i <= 20; i++) {
      final rect = tester.getRect(_entryCard('第$i轮概括。'));
      // 留 10px 余量：卡片顶边太贴视口上沿时长按可能落在视口外。
      if (rect.top >= viewport.top + 10 && rect.bottom <= viewport.bottom) {
        index = i;
        break;
      }
    }
    expect(index, greaterThanOrEqualTo(2), reason: '必须存在已滚出视口的更靠上卡片');
    // 前提确认：编辑器整体（含它上面的条目）已被滚到视口上方——用「组件原点」
    // 当锚点的旧口径在这里必然把菜单甩到屏幕外。
    expect(
      tester.getTopLeft(find.byType(MemorySummaryEditor)).dy,
      lessThan(viewport.top),
    );
    final finger = tester.getCenter(_badge('第$index轮'));
    expect(viewport.contains(finger), isTrue, reason: '长按点必须在视口内');

    await _longPress(tester, _badge('第$index轮'));
    final menuTop = tester.getTopLeft(_menuItem(kMemoryEntryCopyTimeLabel)).dy;

    // 菜单仍应出现在手指处（`showMenu` 会做屏幕边缘钳制，故只要求处于视口附近，
    // 而不是被甩到屏幕顶部 dy ≈ 0）。
    expect(menuTop, closeTo(finger.dy, 8));
    expect(menuTop, greaterThan(viewport.top - 20));
  });

  testWidgets('旧格式条目（`- 第N轮｜日期：xxx｜内容`）同样可复制与跳转', (tester) async {
    final copied = mockClipboard(tester);
    final jumps = await _pumpEditor(
      tester,
      text: '- 第3轮｜日期：第三天 午时｜初入宗门。',
    );

    await _longPress(tester, _badge('第3轮'));
    await _pick(tester, kMemoryEntryCopyTimeLabel);
    expect(copied, ['第三天 午时'], reason: '旧格式的「日期：」标签不入剪贴板');

    await _longPress(tester, _badge('第3轮'));
    await _pick(tester, kMemoryEntryCopyContentLabel);
    expect(copied, ['第三天 午时', '初入宗门。']);

    await _longPress(tester, _badge('第3轮'));
    await _pick(tester, kMemoryEntryJumpLabel);
    expect(jumps, hasLength(1));
    expect(jumps.single.roundIndex, 3);

    await flushNotices(tester);
  });

  testWidgets('跳转至对应条目：合并条目取区间起始轮（11~15 → 11）', (tester) async {
    final jumps = await _pumpEditor(tester);

    await _longPress(tester, _badge('第11~15轮'));
    await _pick(tester, kMemoryEntryJumpLabel);

    expect(jumps, hasLength(1));
    expect(jumps.single.roundIndex, 11, reason: '合并条目跳转落点 = 起始轮');
  });

  testWidgets('未提供跳转回调时不显示菜单项（无跳转落点的一方不伪装可跳转）', (tester) async {
    final controller = TextEditingController(text: _twoEntries);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: NarrChatTheme.light,
        builder: floatingNoticeBuilder(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 420,
              height: 620,
              child: MemorySummaryEditor(controller: controller, showToolbar: false),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _longPress(tester, _badge('第1轮'));

    expect(find.text(kMemoryEntryJumpLabel), findsNothing);
    expect(find.text(kMemoryEntryCopyTimeLabel), findsNothing);
  });
}
