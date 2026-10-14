import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/models/round.dart';
import 'package:narrchat/widgets/chat_bubble.dart';
import 'package:narrchat/widgets/collapsible_content.dart';

import 'helpers/chat_harness.dart';
import 'helpers/fakes.dart';

/// 对话页集成层：用户气泡的「超长自动收起」在真实页面（ListView + 选中作用域 +
/// 窄屏 / 宽屏布局）里同样可用，且收起后**只露 7 行**。
///
/// 气泡自身的收起 / 展开行为见 `chat_bubble_test.dart`；本文件覆盖「页面接线」
/// 与「真实视口下的行数」，两者都按渲染结果核对。
void main() {
  /// 还原线上那种消息：长段落软换行 + 空行分段（Markdown 渲染，段落带块间距）。
  final String longInput = '“说起来，你们这个搭配挺常见的。”我这样说，苏浅浅有些疑惑问我，'
      '我继续说：“就是运动系不良和乖乖女好学生的搭配，比如你和王浩啊，'
      '王浩校外有一些狐朋狗友你也应该知道，多少算半个不良来看。”\n\n'
      '苏浅浅听到这样说，无奈的笑了笑，说确实，毕竟这种人很擅长主动出击，'
      '而乖乖女又不善于拒绝，当然就会导致这样。\n\n'
      '很快，车就开到我租住的出租屋的楼下，我下了车对苏浅浅说：'
      '“感恩大小姐载我一程，感恩的心感谢有你捏。”然后就上楼了，'
      '苏浅浅被我的话逗笑了两声后让苏若开车回她自己租住的别墅了。';

  /// 20 行手打正文（单行短，不会自动换行）。
  final String twentyLines =
      List.generate(20, (i) => '第 ${i + 1} 行用户输入').join('\n');

  /// 可见正文区（[CollapsibleContent]）的矩形。
  Rect bodyRect(WidgetTester tester) =>
      tester.getRect(find.byType(CollapsibleContent));

  /// 用户气泡可见区里**完整露头**的行数。
  ///
  /// 行框坐标是段落局部的，得加上「段落相对正文的偏移」才是可见区里的位置；
  /// 页面上其它部件的段落按渲染树祖先关系筛掉。
  int userBubbleVisibleLines(WidgetTester tester) {
    bool isInside(RenderObject node, RenderObject ancestor) {
      for (RenderObject? p = node.parent; p != null; p = p.parent) {
        if (identical(p, ancestor)) return true;
      }
      return false;
    }

    final bodyBox = tester.renderObject<RenderBox>(
      find.byType(CollapsibleContent),
    );
    final height = bodyBox.size.height;
    var count = 0;
    for (final element in find
        .descendant(of: find.byType(ChatBubble), matching: find.byType(RichText))
        .evaluate()) {
      final paragraph = element.renderObject! as RenderParagraph;
      if (!isInside(paragraph, bodyBox)) continue;
      final top = paragraph.localToGlobal(Offset.zero, ancestor: bodyBox).dy;
      for (final box in paragraph.getBoxesForSelection(
        TextSelection(
          baseOffset: 0,
          extentOffset: paragraph.text.toPlainText().length,
        ),
      )) {
        if (top + box.top >= -0.5 && top + box.bottom <= height + 0.5) count++;
      }
    }
    return count;
  }

  Future<void> pumpWith(WidgetTester tester, String userInput,
      {Size size = const Size(1400, 900)}) async {
    final dao = FakeRoundDao();
    await dao.insertRound(
      Round(
        bookUuid: kHarnessBookUuid,
        roundIndex: 1,
        userInput: userInput,
        aiNarrative: '第 1 轮的剧情正文。',
        currentTime: '第一天 午时',
        createdAt: DateTime.now(),
      ),
    );
    await pumpChatScreen(tester, roundDao: dao, size: size);
    // 收起判定按帧末回报：多推两帧让「箭头出现 + 正文按新宽度重排」都落定。
    await tester.pump();
    await tester.pump();
  }

  testWidgets('对话页：超长用户气泡默认收起，点箭头展开为全文', (tester) async {
    await pumpWith(tester, twentyLines);

    // 页面上只有一个用户气泡（第 1 轮），收起后可见高度不超过 7 行。
    final collapsed = bodyRect(tester).height;
    expect(collapsed, lessThan(200), reason: '7 行 × 25px = 175');

    final expand = find.byIcon(Icons.keyboard_arrow_down_rounded);
    expect(expand, findsOneWidget, reason: '超长用户气泡下方出现展开箭头');

    await tester.tap(expand);
    await tester.pump();
    expect(bodyRect(tester).height, greaterThan(collapsed + 100));
    expect(find.byIcon(Icons.keyboard_arrow_up_rounded), findsOneWidget);

    // 收起只裁切展示：正文完整在渲染树内（Ctrl 全选可复制全文）。
    expect(find.text(twentyLines), findsOneWidget);

    await tester.tap(find.byIcon(Icons.keyboard_arrow_up_rounded));
    await tester.pump();
    expect(bodyRect(tester).height, closeTo(collapsed, 0.5));
    expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // 真实视口 + 真实长消息：收起后可见区里**正好 7 行**（不能多露一行）。
  for (final size in const [
    Size(1400, 900),
    Size(1000, 800),
    Size(600, 900),
    Size(420, 800),
  ]) {
    testWidgets(
        '对话页 ${size.width.toInt()}x${size.height.toInt()}：收起后正好 7 行',
        (tester) async {
      await pumpWith(tester, longInput, size: size);

      final body = bodyRect(tester);
      final render = tester.renderObject<RenderCollapsibleContent>(
        find.byType(CollapsibleContent),
      );
      expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsOneWidget,
          reason: '这个视口下正文确实超过 7 行');
      // 阈值由实际排版量出（第 7 行下沿），可见高度就等于它。
      expect(body.height, closeTo(render.collapsedHeight, 0.01));
      expect(userBubbleVisibleLines(tester), 7, reason: '可见区里正好 7 行');
      expect(tester.takeException(), isNull);
    });
  }

  /// 可滚动的多轮对话：末轮是超长用户输入（会收起），它后面还有 AI 回复
  /// ——真实对话里用户气泡下面总有 AI 回复，所以它不是列表末尾那一条。
  ///
  /// [roundSevenInput] 可换成更长的正文（超长气泡用例：展开增量数千 px）；
  /// [trailingReplyRepeats] 加大可让该轮气泡下方内容更多（把顶边顶到视口之外）。
  Future<void> pumpScrollableThread(
    WidgetTester tester, {
    bool trailingReply = true,
    String? roundSevenInput,
    int trailingReplyRepeats = 40,
  }) async {
    final dao = FakeRoundDao();
    for (var i = 1; i <= 6; i++) {
      await dao.insertRound(
        Round(
          bookUuid: kHarnessBookUuid,
          roundIndex: i,
          userInput: '第 $i 轮的用户输入',
          aiNarrative: '第 $i 轮的剧情正文。' * 40,
          currentTime: '第一天 午时',
          createdAt: DateTime.now(),
        ),
      );
    }
    await dao.insertRound(
      Round(
        bookUuid: kHarnessBookUuid,
        roundIndex: 7,
        userInput: roundSevenInput ?? twentyLines,
        // 末尾（AI 还没回复）时这一条就是列表最末条目 —— 列表自带的阅读锚定
        // 也会盯它的高度变化，这里用来验证「锚定 + 气泡补偿」不会叠加成两倍。
        aiNarrative:
            trailingReply ? '第 7 轮的剧情正文。' * trailingReplyRepeats : '',
        currentTime: '第一天 午时',
        createdAt: DateTime.now(),
      ),
    );
    await pumpChatScreen(tester, roundDao: dao);
    await tester.pump();
    await tester.pump();
  }

  /// 消息列（`ListView`）的滚动位置。
  ScrollPosition chatScrollPosition(WidgetTester tester) => tester
      .state<ScrollableState>(
        find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      )
      .position;

  /// 超长用户气泡的可见正文区（[CollapsibleContent]）：按**正文文本**定位，
  /// 页面上其它短消息的气泡也有同类型容器，不能用类型找。
  Finder longBubbleBodyOf(String text) => find.ancestor(
        of: find.text(text),
        matching: find.byType(CollapsibleContent),
      );

  /// 展开 / 收起的气泡高度差（= 正文自然高度 − 裁切阈值）。
  double expansionDelta(WidgetTester tester, Finder body) {
    final render = tester.renderObject<RenderCollapsibleContent>(body);
    return render.naturalHeight - render.collapsedHeight;
  }

  /// 把 [finder] 的中心滚到视口纵向 [y] 处（`reverse` 列表：偏移增大内容下移）。
  Future<void> scrollCenterTo(
    WidgetTester tester,
    Finder finder,
    double y,
  ) async {
    final position = chatScrollPosition(tester);
    position.jumpTo(
      (position.pixels + (y - tester.getRect(finder).center.dy))
          .clamp(position.minScrollExtent, position.maxScrollExtent),
    );
    await tester.pump();
  }

  Finder arrowDown() => find.byIcon(Icons.keyboard_arrow_down_rounded);
  Finder arrowUp() => find.byIcon(Icons.keyboard_arrow_up_rounded);

  testWidgets('对话页：展开锁顶部、收起锁底部（各让点击的那一端不动）',
      (tester) async {
    // 用 9 行正文（超 7 行一点点）：气泡整体都落在视口里，两个锚点都能直接量到。
    final nineLines = List.generate(9, (i) => '第 ${i + 1} 行用户输入').join('\n');
    await pumpScrollableThread(tester, roundSevenInput: nineLines);

    final body = longBubbleBodyOf(nineLines);
    expect(body, findsOneWidget, reason: '只有这一个用户气泡超长');
    final position = chatScrollPosition(tester);

    // 先把这条气泡挪进视口（贴底时它在视口之外，控件点不到）。
    await scrollCenterTo(tester, body, 300);

    final before = tester.getRect(body);
    final pixelsBefore = position.pixels;
    final delta = expansionDelta(tester, body);
    expect(delta, greaterThan(20), reason: '这一条确实比 7 行高出一截');

    // 展开：**顶部**原地不动（内容向下铺开 Δ），一帧即到位 = 无滚动动画。
    await tester.tap(arrowDown());
    await tester.pump();
    expect(tester.getRect(body).height, closeTo(before.height + delta, 1));
    expect(tester.getRect(body).top, closeTo(before.top, 0.5),
        reason: '展开锁顶部：顶边一动不动');
    expect(position.pixels, closeTo(pixelsBefore + delta, 1),
        reason: '偏移按展开增量补回去');
    expect(position.pixels, lessThan(position.maxScrollExtent - 1),
        reason: '补偿按新范围夹取，不会顶到列表端点');

    // 再等一帧：位置依旧（没有事后跳转）。
    await tester.pump();
    expect(tester.getRect(body).top, closeTo(before.top, 0.5));

    // 收起：**底部**原地不动（控件就在指尖下），顶部随正文收拢下移 Δ；
    // 底边锚定是 `reverse` 列表的天然行为，一个偏移都不用补。
    final topExpanded = tester.getRect(body).top;
    final bottomExpanded = tester.getRect(body).bottom;
    final arrowExpanded = tester.getRect(arrowUp()).center.dy;
    final pixelsExpanded = position.pixels;
    await tester.tap(arrowUp());
    await tester.pump();
    await tester.pump();
    expect(position.pixels, closeTo(pixelsExpanded, 0.5),
        reason: '收起锁底部：不补任何偏移');
    expect(tester.getRect(body).bottom, closeTo(bottomExpanded, 0.5),
        reason: '收起后气泡底边原地不动');
    expect(tester.getRect(arrowDown()).center.dy, closeTo(arrowExpanded, 0.5),
        reason: '控件原地不动（它就在指尖下）');
    expect(tester.getRect(body).top, closeTo(topExpanded + delta, 1),
        reason: '顶部随正文收拢下移 Δ');
    expect(tester.getRect(body).height, closeTo(before.height, 0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('对话页：顶边已在视口上方时展开，依然以顶部为锚点', (tester) async {
    // 展开的锚点是「气泡顶部」这件事与顶边是否可见无关：读者要的就是从消息
    // 开头往下读，所以顶边哪怕在视口外也照样锁住它。
    final nineLines = List.generate(9, (i) => '第 ${i + 1} 行用户输入').join('\n');
    // 该轮气泡下方内容给足（顶边才滚得到视口之上）。
    await pumpScrollableThread(
      tester,
      roundSevenInput: nineLines,
      trailingReplyRepeats: 120,
    );

    // 老消息要一路翻上去才会被构建。
    final drag = await tester.startGesture(
      tester.getCenter(find.byType(ListView)),
    );
    for (var i = 0; i < 40 && find.text(nineLines).evaluate().isEmpty; i++) {
      await drag.moveBy(const Offset(0, 300));
      await tester.pump();
    }
    await drag.up();
    await tester.pump();

    final body = longBubbleBodyOf(nineLines);
    expect(body, findsOneWidget, reason: '已翻到这一条');
    final position = chatScrollPosition(tester);
    // 把控件挪到视口上部（避开顶栏 / 常驻提示岛）→ 气泡顶边落到视口之上。
    await scrollCenterTo(tester, arrowDown(), 120);

    final before = tester.getRect(body);
    expect(before.top, lessThan(0), reason: '顶边已在视口上方');
    final pixelsBefore = position.pixels;
    final delta = expansionDelta(tester, body);

    await tester.tap(arrowDown());
    await tester.pump();
    expect(tester.getRect(body).top, closeTo(before.top, 0.5),
        reason: '展开锁顶部：顶边在视口外也不动');
    expect(position.pixels, closeTo(pixelsBefore + delta, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('对话页：贴底展开末尾那条用户气泡（AI 尚未回复）同样顶部原地不动',
      (tester) async {
    // 硬场景：这一条既是「贴底」又是「列表最末条目」——阅读锚定盯着它的高度增长
    // （贴底时刻意不补），锁顶边此刻必须自己补上；两边都补就是双倍位移。
    await pumpScrollableThread(tester, trailingReply: false);

    final body = longBubbleBodyOf(twentyLines);
    final position = chatScrollPosition(tester);
    expect(position.pixels, closeTo(position.minScrollExtent, 0.5),
        reason: '初始贴底');

    final before = tester.getRect(body);
    expect(before.top, greaterThan(0), reason: '气泡顶部在视口内');
    final delta = expansionDelta(tester, body);

    await tester.tap(arrowDown());
    await tester.pump();
    await tester.pump();
    expect(tester.getRect(body).top, closeTo(before.top, 0.5),
        reason: '贴底展开后气泡顶部仍原地不动（补偿不叠加成双倍）');
    // 偏移恰好是**一倍**展开增量：阅读锚定贴底不补，只有锁顶边补这一次
    // （双倍的话气泡顶部会反向下移 delta）。
    expect(position.pixels, closeTo(delta, 1.0), reason: '补偿恰好一倍');
    expect(tester.takeException(), isNull);
    // 展开后控件被顶到视口之外（顶部锁定的必然结果），收起路径见上一条用例。
  });

  testWidgets('对话页：超长气泡（展开增量数千 px）展开 / 收起都不跳到列表端点',
      (tester) async {
    // 旧实现按**旧**范围夹紧预补偿，再叠一次帧末无界校正：Δ 数千 px 时这两处
    // 都能把视图甩到列表端点 —— 用户看到的就是「一收起就直接翻到最顶部」。
    final hugeInput =
        List.generate(400, (i) => '第 ${i + 1} 行超长用户输入').join('\n');
    await pumpScrollableThread(tester, roundSevenInput: hugeInput);

    final body = longBubbleBodyOf(hugeInput);
    expect(body, findsOneWidget, reason: '只有这一个用户气泡超长');
    final position = chatScrollPosition(tester);

    // 展开：先把控件挪进视口中部。
    await scrollCenterTo(tester, arrowDown(), 600);
    final delta = expansionDelta(tester, body);
    expect(delta, greaterThan(3000), reason: '超长气泡：展开增量确实有数千 px');
    final before = tester.getRect(body);
    final pixelsBefore = position.pixels;

    await tester.tap(arrowDown());
    await tester.pump();
    expect(tester.getRect(body).top, closeTo(before.top, 0.5),
        reason: '顶边原地不动（内容向下铺开数千 px）');
    expect(position.pixels, closeTo(pixelsBefore + delta, 1),
        reason: '补偿按新范围夹取后完整生效，没有被旧范围吃掉');
    expect(position.pixels, lessThan(position.maxScrollExtent - 1),
        reason: '不顶到列表端点');

    // 读到气泡尾部（顶边已在视口上方数千 px）再收起：顶边不在视口里 → 不该补任何
    // 偏移（锁一个看不见的顶边等于把整屏内容平移 Δ，正是「一收起就跳到全页顶部」），
    // 读者视线所在的控件原地不动、其它内容也不跳。
    await scrollCenterTo(tester, arrowUp(), 500);
    expect(tester.getRect(body).top, lessThan(-3000),
        reason: '顶边已在视口上方数千 px（正是触发旧缺陷的姿态）');
    final pixelsAtTail = position.pixels;
    final arrowAtTail = tester.getRect(arrowUp()).center.dy;

    await tester.tap(arrowUp());
    await tester.pump();
    await tester.pump();
    expect(tester.getRect(body).height, closeTo(before.height, 1),
        reason: '正文已收回到 7 行');
    expect(position.pixels, closeTo(pixelsAtTail, 0.5),
        reason: '顶边不在视口里 → 偏移一动不动（既不上翻到顶部，也不跳到别处）');
    expect(tester.getRect(arrowDown()).center.dy, closeTo(arrowAtTail, 0.5),
        reason: '控件（读者视线所在）原地不动');
    expect(position.pixels, lessThan(position.maxScrollExtent - 1));
    // 收起后气泡仍在视口内可见（定位不混乱）。
    final viewportHeight = tester.getSize(find.byType(ListView)).height;
    final after = tester.getRect(body);
    expect(after.bottom, greaterThan(0), reason: '气泡没被顶出视口上方');
    expect(after.top, lessThan(viewportHeight), reason: '气泡没被顶出视口下方');
    expect(tester.takeException(), isNull);
  });

  testWidgets('对话页：顶边滚出视口后收起，整屏内容不位移（读者视线原地不动）',
      (tester) async {
    // 复现线上路径：展开 → 往下读到气泡尾部（顶边离开视口）→ 收起。
    // 旧实现无条件锁顶边：顶边在视口上方 Δ≈数千 px 时，锁住它等于平移整屏内容，
    // 读者眼前会换成完全不同的位置。
    final hugeInput =
        List.generate(200, (i) => '第 ${i + 1} 行超长用户输入').join('\n');
    await pumpScrollableThread(tester, roundSevenInput: hugeInput);

    final body = longBubbleBodyOf(hugeInput);
    final position = chatScrollPosition(tester);

    // 展开：此时顶边可见 → 锁顶边（内容向下铺开）。
    await scrollCenterTo(tester, arrowDown(), 600);
    final collapsedHeight = tester.getRect(body).height;
    final topBefore = tester.getRect(body).top;
    final pixelsBefore = position.pixels;
    final delta = expansionDelta(tester, body);
    expect(delta, greaterThan(1500));
    expect(topBefore, greaterThan(0), reason: '顶边在视口内');
    await tester.tap(arrowDown());
    await tester.pump();
    expect(tester.getRect(body).top, closeTo(topBefore, 0.5),
        reason: '顶边可见 → 锁顶边生效');
    expect(position.pixels, closeTo(pixelsBefore + delta, 1));

    // 读到尾部：顶边滚出视口。
    await scrollCenterTo(tester, arrowUp(), 500);
    expect(tester.getRect(body).top, lessThan(-1000), reason: '顶边已滚出视口');
    final pixelsAtTail = position.pixels;
    final tailAtExpanded = tester.getRect(body).bottom;
    final arrowAtExpanded = tester.getRect(arrowUp()).center.dy;

    await tester.tap(arrowUp());
    await tester.pump();
    await tester.pump();
    expect(position.pixels, closeTo(pixelsAtTail, 0.5),
        reason: '顶边不在视口里 → 不补偿：整屏内容原地不动');
    expect(tester.getRect(body).height, closeTo(collapsedHeight, 0.5),
        reason: '正文已收回到 7 行');
    expect(tester.getRect(body).bottom, closeTo(tailAtExpanded, 0.5),
        reason: '气泡底边（尾行与控件所在处）原地不动');
    expect(tester.getRect(arrowDown()).center.dy, closeTo(arrowAtExpanded, 0.5),
        reason: '控件原地不动（它就是读者点的地方）');
    expect(tester.takeException(), isNull);
  });

  testWidgets('对话页：鼠标点击箭头时手抖几像素，也要触发切换', (tester) async {
    // 消息列是可滚动列表，鼠标的拖动判定阈值只有 1px：按住鼠标时手抖 2~3px
    // 会被判成「拖动滚动」并取消点击 —— 线上表现为「点一下没反应，点几下才行」。
    await pumpWith(tester, twentyLines);

    final arrow = find.byIcon(Icons.keyboard_arrow_down_rounded);
    expect(arrow, findsOneWidget, reason: '超长气泡下方有展开箭头');
    final gesture = await tester.startGesture(
      tester.getCenter(arrow),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveBy(const Offset(0, 3));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(find.byIcon(Icons.keyboard_arrow_up_rounded), findsOneWidget,
        reason: '3px 位移仍算点击（不该被拖动判定抢走）');

    // 反向同样成立：带位移点击箭头也能收起。
    final up = find.byIcon(Icons.keyboard_arrow_up_rounded);
    final collapse = await tester.startGesture(
      tester.getCenter(up),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await collapse.moveBy(const Offset(-2, 4));
    await tester.pump();
    await collapse.up();
    await tester.pump();
    expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsOneWidget,
        reason: '带位移点击同样收起');
    expect(tester.takeException(), isNull);
  });

  testWidgets('对话页：按下滑动（真正的滚动拖动）不触发切换', (tester) async {
    // 判定放宽不能误伤滚动：位移超过点击容差就交回列表。
    await pumpWith(tester, twentyLines);

    final arrow = find.byIcon(Icons.keyboard_arrow_down_rounded);
    final gesture = await tester.startGesture(tester.getCenter(arrow));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 60));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    await tester.pump();
    expect(find.byIcon(Icons.keyboard_arrow_up_rounded), findsNothing,
        reason: '拖动（位移 60px）不触发展开');
    expect(tester.takeException(), isNull);
  });
}
