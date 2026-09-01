import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/widgets/floor_jump_bar.dart';

import 'helpers/chat_harness.dart';
import 'helpers/fakes.dart';

/// 楼层跳转（FloorJumpBar）测试：按钮布局/箭头跳转/回车/缺口/流式/动画/Tooltip。
void main() {
  const book = Book(uuid: kHarnessBookUuid, title: '测试书');

  /// 预置 rounds 轮（单轮正文足够高，最后一轮起点可达视口顶），
  /// 并 pump 对话页。返回 RoundProvider（用于缺口删除等用例）。
  Future<dynamic> pumpChat(
    WidgetTester tester, {
    FakeBookDao? bookDao,
    FakeRoundDao? dao,
    int rounds = 6,
    Size size = const Size(1400, 900),
    FakeStreamingAiService? ai,
  }) async {
    final provider = await pumpChatScreen(
      tester,
      bookDao: bookDao ?? FakeBookDao(books: [book]),
      roundDao: dao ?? FakeRoundDao(),
      ai: ai ?? FakeStreamingAiService(),
      seedRounds: rounds,
      seedBodyRepeats: 200,
      size: size,
    );
    return provider;
  }

  /// 对话消息列表最外层（ListView 自带）的滚动状态。
  ScrollableState chatScrollable(WidgetTester tester) {
    return tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
  }

  /// 对话消息列表的滚动偏移。
  double chatOffset(WidgetTester tester) =>
      chatScrollable(tester).position.pixels;

  /// 对话消息列表的最大滚动偏移。
  double chatMax(WidgetTester tester) =>
      chatScrollable(tester).position.maxScrollExtent;

  Finder floorButton() => find.byIcon(Icons.layers_outlined);
  Finder floorBar() => find.byType(FloorJumpBar);

  /// 主输入框（按 hint 定位，与 chat_composer_test 一致）。
  Finder composerField() => find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.hintText == '输入你的行动或对话…',
      );

  /// 用慢速手势把对话列表滚动到底部（无惯性甩动，便于确定性断言）。
  Future<void> scrollChatToBottom(WidgetTester tester) async {
    final start = tester.getCenter(find.byType(ListView));
    final gesture = await tester.startGesture(start);
    for (var i = 0; i < 30; i++) {
      await gesture.moveBy(const Offset(0, -300));
      await tester.pump();
      if (chatOffset(tester) >= chatMax(tester) - 1) break;
    }
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// 悬浮条中间数字输入框。
  Finder numberField() => find.descendant(
        of: floorBar(),
        matching: find.byType(TextField),
      );

  /// 悬浮条左/右箭头按钮。
  Finder prevArrow() => find.descendant(
        of: floorBar(),
        matching: find.byIcon(Icons.chevron_left),
      );
  Finder nextArrow() => find.descendant(
        of: floorBar(),
        matching: find.byIcon(Icons.chevron_right),
      );

  /// 悬浮条中间数字当前显示的文本。
  String numberText(WidgetTester tester) =>
      tester.widget<TextField>(numberField()).controller!.text;

  Future<void> openFloorBar(WidgetTester tester) async {
    await tester.tap(floorButton());
    await tester.pumpAndSettle();
  }

  Future<void> tapPrev(WidgetTester tester) async {
    await tester.tap(prevArrow());
    await tester.pumpAndSettle();
  }

  Future<void> tapNext(WidgetTester tester) async {
    await tester.tap(nextArrow());
    await tester.pumpAndSettle();
  }

  /// 指定轮次的用户气泡顶（全局 y）与消息列表视口顶（全局 y）对齐断言。
  /// 用户气泡内部有 9px 垂直内边距：文本顶应位于视口顶下方 0~15px 内，
  /// 即该轮起点与视口顶对齐（而非内容中部）。
  void expectRoundStartAligned(WidgetTester tester, int roundIndex) {
    final listTop = tester.getTopLeft(find.byType(ListView)).dy;
    final roundTop = tester.getTopLeft(find.text('第 $roundIndex 轮的用户输入')).dy;
    expect(roundTop, greaterThanOrEqualTo(listTop - 1));
    expect(roundTop, lessThanOrEqualTo(listTop + 15),
        reason: '第 $roundIndex 轮起点应对齐视口顶（当前偏差 ${roundTop - listTop}px）');
  }

  testWidgets('宽屏：楼层跳转按钮位于滚动到底部按钮左侧', (tester) async {
    await pumpChat(tester);

    expect(floorButton(), findsOneWidget);
    final floorX = tester.getCenter(floorButton()).dx;
    final scrollX = tester.getCenter(find.byIcon(Icons.vertical_align_bottom)).dx;
    expect(floorX, lessThan(scrollX), reason: '楼层跳转应在滚动到底部左侧');
  });

  testWidgets('窄屏：按钮顺序为 楼层跳转 < 滚动到底部 < 打开侧栏', (tester) async {
    await pumpChat(tester, size: const Size(600, 900));

    final floorX = tester.getCenter(find.byTooltip('楼层跳转')).dx;
    final scrollX = tester.getCenter(find.byTooltip('滚动到底部')).dx;
    final sidebarX = tester.getCenter(find.byTooltip('打开右侧边栏')).dx;
    expect(floorX, lessThan(scrollX));
    expect(scrollX, lessThan(sidebarX));
  });

  testWidgets('预览请求体按钮位于楼层跳转左侧', (tester) async {
    await pumpChat(tester);

    final previewX = tester.getCenter(find.byTooltip('预览请求体')).dx;
    final floorX = tester.getCenter(floorButton()).dx;
    final scrollX = tester.getCenter(find.byTooltip('滚动到底部')).dx;
    expect(previewX, lessThan(floorX), reason: '预览按钮应在楼层跳转左侧');
    expect(floorX, lessThan(scrollX),
        reason: '楼层跳转应在滚动到底部左侧（原顺序不变）');
  });

  testWidgets('仅有第零轮时：预览按钮常驻，楼层跳转隐藏', (tester) async {
    await pumpChat(tester, rounds: 0);

    expect(find.byTooltip('预览请求体'), findsOneWidget);
    expect(find.byTooltip('楼层跳转'), findsNothing);
  });

  testWidgets('点击预览按钮：弹出「预览请求体」对话框（无发送副作用）', (tester) async {
    final provider = await pumpChat(tester, rounds: 0);
    await tester.enterText(composerField(), '继续剧情');

    await tester.tap(find.byTooltip('预览请求体'));
    await tester.pumpAndSettle();

    expect(find.text('预览请求体'), findsOneWidget);
    expect(find.text('【请求体 1】'), findsOneWidget);
    expect(find.text('【AI返回 1】'), findsNothing);

    // 仅预览、未发送：轮次应仍只有「第零轮」。
    expect(provider.rounds, hasLength(1));
    expect(provider.rounds.single.roundIndex, 0);
  });

  testWidgets('点击按钮在其上方弹出悬浮条，中间数字为当前（底部=最后一轮）轮次', (tester) async {
    await pumpChat(tester);
    // 测试环境无初始自动滚动：显式滚到底部 → 当前轮应为最后一轮。
    await scrollChatToBottom(tester);
    expect(chatOffset(tester), closeTo(chatMax(tester), 1));

    await openFloorBar(tester);
    expect(floorBar(), findsOneWidget);

    // 悬浮条中心位于楼层按钮中心上方。
    final barY = tester.getCenter(floorBar()).dy;
    final btnY = tester.getCenter(floorButton()).dy;
    expect(barY, lessThan(btnY), reason: '悬浮条应弹出在按钮上方');

    expect(numberText(tester), '6');
  });

  testWidgets('左箭头：轮中部 → 当前轮起点；轮起点 → 上一轮起点', (tester) async {
    await pumpChat(tester);
    await scrollChatToBottom(tester);

    await openFloorBar(tester);
    expect(numberText(tester), '6');

    // 底部处于第 6 轮中部：左箭头 → 第 6 轮起点。
    await tapPrev(tester);
    expectRoundStartAligned(tester, 6);
    expect(numberText(tester), '6');

    // 已处于第 6 轮起点：左箭头 → 第 5 轮起点。
    await tapPrev(tester);
    expectRoundStartAligned(tester, 5);
    expect(numberText(tester), '5');
  });

  testWidgets('右箭头：下一轮起点；最后一轮 → 列表末尾', (tester) async {
    await pumpChat(tester);
    await scrollChatToBottom(tester);

    await openFloorBar(tester);
    // 底部第 6 轮：左一次到第 6 轮起点，再左一次到第 5 轮起点。
    await tapPrev(tester);
    await tapPrev(tester);
    expectRoundStartAligned(tester, 5);
    expect(numberText(tester), '5');

    // 右箭头 → 第 6 轮起点。
    await tapNext(tester);
    expectRoundStartAligned(tester, 6);
    expect(numberText(tester), '6');

    // 已是最后一轮：右箭头 → 列表末尾（第 6 轮末尾）。
    await tapNext(tester);
    expect(chatOffset(tester), closeTo(chatMax(tester), 1));
  });

  testWidgets('回车跳转：输入数字回车 → 对应轮起点，悬浮条关闭', (tester) async {
    await pumpChat(tester);

    await openFloorBar(tester);
    await tester.enterText(numberField(), '2');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expectRoundStartAligned(tester, 2);
    expect(floorBar(), findsNothing, reason: '回车定点跳转后悬浮条应关闭');
  });

  testWidgets('边界：第 1 轮起点时左箭头禁用', (tester) async {
    await pumpChat(tester);

    // 输入 1 回车跳到第 1 轮起点。
    await openFloorBar(tester);
    await tester.enterText(numberField(), '1');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expectRoundStartAligned(tester, 1);

    // 重新打开：处于第 1 轮起点 → 左箭头禁用。
    await openFloorBar(tester);
    expect(numberText(tester), '1');
    final prevBtn = tester.widget<IconButton>(
      find.ancestor(of: prevArrow(), matching: find.byType(IconButton)),
    );
    expect(prevBtn.onPressed, isNull, reason: '第 1 轮起点无可跳转的上一轮');
  });

  testWidgets('关闭：点悬浮条外部或再次点击按钮', (tester) async {
    await pumpChat(tester);

    await openFloorBar(tester);
    expect(floorBar(), findsOneWidget);

    // 点消息区（避开底部悬浮面板）→ 关闭。
    await tester.tapAt(const Offset(300, 300));
    await tester.pumpAndSettle();
    expect(floorBar(), findsNothing);

    // 再点按钮打开，再点按钮收起。
    await openFloorBar(tester);
    expect(floorBar(), findsOneWidget);
    await tester.tap(floorButton());
    await tester.pumpAndSettle();
    expect(floorBar(), findsNothing);
  });

  testWidgets('打开悬浮条不改变按钮位置（bar 弹出在按钮上方、按钮不移动）', (tester) async {
    await pumpChat(tester);

    final floorBtn = find.byTooltip('楼层跳转');
    final scrollBtn = find.byTooltip('滚动到底部');
    final floorXBefore = tester.getCenter(floorBtn).dx;
    final scrollXBefore = tester.getCenter(scrollBtn).dx;

    // 打开悬浮条。
    await tester.tap(find.byIcon(Icons.layers_outlined));
    await tester.pumpAndSettle();
    expect(floorBar(), findsOneWidget);

    // 按钮位置不变（修复：悬浮条列向右扩展，不推挤按钮）。
    expect(tester.getCenter(floorBtn).dx, closeTo(floorXBefore, 1),
        reason: '展开悬浮条不应移动楼层跳转按钮');
    expect(tester.getCenter(scrollBtn).dx, closeTo(scrollXBefore, 1),
        reason: '展开悬浮条不应移动滚动到底部按钮');

    // bar 在按钮上方，且右缘与按钮右缘对齐（右对齐，向左扩展）。
    expect(tester.getCenter(floorBar()).dy, lessThan(tester.getCenter(floorBtn).dy),
        reason: 'bar 应在按钮上方');
    final barRight = tester.getTopRight(floorBar()).dx;
    final btnRight = tester.getTopRight(floorBtn).dx;
    expect(barRight, closeTo(btnRight, 2), reason: 'bar 应右对齐按钮右缘');
  });

  testWidgets('无聊天轮次（仅第零轮）时隐藏楼层跳转按钮', (tester) async {
    await pumpChat(tester, rounds: 0);

    expect(floorButton(), findsNothing);
  });

  testWidgets('roundIndex 缺口：输入被删轮号 → 就近跳到已存在的上一轮', (tester) async {
    final dao = FakeRoundDao();
    final provider = await pumpChat(tester, dao: dao);

    // 删除第 3 轮（DAO 不重编号，产生缺口：1,2,4,5,6）。
    final round3 = dao.rounds.firstWhere((r) => r.roundIndex == 3);
    await dao.deleteRound(round3.id!);
    await provider.loadRounds(kHarnessBookUuid);
    await tester.pumpAndSettle();

    await openFloorBar(tester);
    await tester.enterText(numberField(), '3');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    // 第 3 轮不存在 → 就近向下取第 2 轮。
    expectRoundStartAligned(tester, 2);
  });

  testWidgets('用户主动滑动消息区时自动收起悬浮条（自动向下滚动除外）', (tester) async {
    await pumpChat(tester);

    await openFloorBar(tester);
    expect(floorBar(), findsOneWidget);

    // 用户拖拽列表（pointer down + 滑动）→ 悬浮条收起。
    await tester.drag(find.byType(ListView), const Offset(0, 200));
    await tester.pumpAndSettle();
    expect(floorBar(), findsNothing, reason: '用户主动滑动应自动收起悬浮条');
  });

  testWidgets('流式自动跟随滚动不收起悬浮条，且中间数字跟随新内容更新', (tester) async {
    final ai = FakeStreamingAiService();
    final provider = await pumpChat(tester, ai: ai);

    // 滚到底部后开始流式生成（自动跟随保持视口在底部）。
    await scrollChatToBottom(tester);
    final sendFuture = provider.sendRound(userInput: '继续剧情', book: book);
    await tester.pump();
    ai.emit('第一段');
    await tester.pump();

    // 打开悬浮条（流式期间有无限转圈动画，不能用 pumpAndSettle）。
    await tester.tap(find.byIcon(Icons.layers_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(floorBar(), findsOneWidget);

    // 流式继续输出（自动向下滚动）→ 悬浮条保持打开。
    for (var i = 0; i < 5; i++) {
      ai.emit('更多内容 $i');
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump(const Duration(milliseconds: 50));
    expect(floorBar(), findsOneWidget, reason: '自动向下滚动不应收起悬浮条');

    ai.complete();
    for (var i = 0; i < 20 && provider.isSending; i++) {
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(await sendFuture, isTrue);
  });

  testWidgets('打开悬浮条带动画（淡入）', (tester) async {
    await pumpChat(tester);

    await tester.tap(floorButton());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    // 动画进行中：悬浮条祖先 FadeTransition 透明度 < 1。
    bool anyFading() {
      for (final e in find
          .ancestor(of: floorBar(), matching: find.byType(FadeTransition))
          .evaluate()) {
        if ((e.widget as FadeTransition).opacity.value < 1.0) return true;
      }
      return false;
    }

    expect(anyFading(), isTrue, reason: '打开应带动画（淡入中）');
    await tester.pumpAndSettle();
    expect(
      find
          .ancestor(of: floorBar(), matching: find.byType(FadeTransition))
          .evaluate()
          .isNotEmpty,
      isTrue,
    );
    // 动画完成：所有 FadeTransition 透明度为 1。
    for (final e in find
        .ancestor(of: floorBar(), matching: find.byType(FadeTransition))
        .evaluate()) {
      expect((e.widget as FadeTransition).opacity.value, 1.0);
    }
  });

  testWidgets('第 5 轮底部点左箭头 → 第 5 轮顶部（而非跳到第 4 轮）', (tester) async {
    await pumpChat(tester);

    // 先滚到顶部：构建/上报前几轮（第 4 轮起点已上报）。
    await tester.drag(find.byType(ListView), const Offset(0, 10000));
    await tester.pumpAndSettle();

    // 直接跳到第 6 轮起点（第 5 轮起点项未被构建/上报）。
    await openFloorBar(tester);
    await tester.enterText(numberField(), '6');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    // 向上拖 300px 进入第 5 轮下部（第 5 轮起点项仍未上报）。
    await tester.drag(find.byType(ListView), const Offset(0, 300));
    await tester.pumpAndSettle();

    // 打开悬浮条：当前轮应为 5（完整偏移模型，而非回退到第 4 轮）。
    await openFloorBar(tester);
    expect(numberText(tester), '5',
        reason: '第 5 轮下部应识别为第 5 轮（修复跳到第 4 轮）');

    // 左箭头 → 第 5 轮顶部。
    await tapPrev(tester);
    expectRoundStartAligned(tester, 5);
    expect(numberText(tester), '5');
  });

  testWidgets('悬浮条不使用 RenderFollowerLayer（修复红屏闪烁断言）', (tester) async {
    await pumpChat(tester);

    await openFloorBar(tester);
    expect(floorBar(), findsOneWidget);

    // 修复目标：悬浮条不再通过 CompositedTransformFollower 渲染——该组件
    // 的 paint transform 依赖图层树，在 Overlay/Tooltip(OverlayPortal) 布局时
    // 会触发「cannot be reliably computed」与「debugNeedsLayout」断言导致
    // chat 页红屏闪烁。
    expect(find.byType(CompositedTransformFollower), findsNothing,
        reason: '不应存在 RenderFollowerLayer（红屏崩溃根因）');

    // 悬停悬浮条箭头触发 Tooltip（内部 OverlayPortal 布局）不应抛异常。
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(tester.getCenter(prevArrow()));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'Tooltip 触发不应抛异常');
    expect(find.text('上一轮起点'), findsOneWidget, reason: 'Tooltip 应正常弹出');
  });
}
