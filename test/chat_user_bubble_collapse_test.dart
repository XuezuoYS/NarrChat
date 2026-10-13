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
  Future<void> pumpScrollableThread(
    WidgetTester tester, {
    bool trailingReply = true,
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
        userInput: twentyLines,
        // 末尾（AI 还没回复）时这一条就是列表最末条目 —— 列表自带的阅读锚定
        // 也会盯它的高度变化，这里用来验证「锚定 + 气泡补偿」不会叠加成两倍。
        aiNarrative: trailingReply ? '第 7 轮的剧情正文。' * 40 : '',
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

  /// 超长用户气泡的可见正文区（[CollapsibleContent]）。
  Finder longBubbleBody() => find.ancestor(
        of: find.text(twentyLines),
        matching: find.byType(CollapsibleContent),
      );

  testWidgets('对话页：展开 / 收起时气泡顶部原地不动（瞬时补偿，无滚动动画）',
      (tester) async {
    await pumpScrollableThread(tester);

    final body = longBubbleBody();
    expect(body, findsOneWidget, reason: '只有这一个用户气泡超长');
    final position = chatScrollPosition(tester);

    // 先把这条气泡挪到视口上方区域（贴底时它在视口之外，看不到就谈不上锁定）。
    position.jumpTo(
      (position.pixels + (tester.getRect(body).top - 300))
          .clamp(position.minScrollExtent, position.maxScrollExtent),
    );
    await tester.pump();

    final before = tester.getRect(body).top;
    final pixelsBefore = position.pixels;
    expect(before, greaterThan(0), reason: '气泡顶部在视口内');

    // 展开：**一帧**之后顶部就必须还在原处（若走滚动动画，这一帧只会挪一部分）。
    await tester.tap(find.byIcon(Icons.keyboard_arrow_down_rounded));
    await tester.pump();
    expect(tester.getRect(body).top, closeTo(before, 0.5),
        reason: '展开后气泡顶部原地不动');
    expect(position.pixels, greaterThan(pixelsBefore + 100),
        reason: '滚动偏移已按展开增量补回去（内容不被推着上移）');
    expect(tester.getRect(body).height, greaterThan(200), reason: '正文已铺开');

    // 再等一帧（帧末校正落定）位置依旧。
    await tester.pump();
    expect(tester.getRect(body).top, closeTo(before, 0.5));

    // 收起：同样原地不动，且回到原来的偏移。
    await tester.tap(find.byIcon(Icons.keyboard_arrow_up_rounded));
    await tester.pump();
    await tester.pump();
    expect(tester.getRect(body).top, closeTo(before, 0.5), reason: '收起后同样原地');
    expect(position.pixels, closeTo(pixelsBefore, 0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('对话页：贴底展开末尾那条用户气泡（AI 尚未回复）同样原地不动',
      (tester) async {
    // 硬场景：这一条既是「贴底」又是「列表最末条目」——列表自身的阅读锚定会
    // 补偿它的高度增长，气泡自己也补一次，稍不注意就是双倍位移。
    await pumpScrollableThread(tester, trailingReply: false);

    final body = longBubbleBody();
    final position = chatScrollPosition(tester);
    expect(position.pixels, closeTo(position.minScrollExtent, 0.5),
        reason: '初始贴底');

    final before = tester.getRect(body).top;
    expect(before, greaterThan(0), reason: '气泡顶部在视口内');
    final delta = tester
            .renderObject<RenderCollapsibleContent>(
                find.byType(CollapsibleContent))
            .naturalHeight -
        tester
            .renderObject<RenderCollapsibleContent>(
                find.byType(CollapsibleContent))
            .collapsedHeight;

    await tester.tap(find.byIcon(Icons.keyboard_arrow_down_rounded));
    await tester.pump();
    await tester.pump();
    expect(tester.getRect(body).top, closeTo(before, 0.5),
        reason: '贴底展开后气泡顶部仍原地不动（补偿不叠加成双倍）');
    // 偏移恰好是**一倍**展开增量：列表自身锚定的那份补偿已被帧末校正扣掉
    // （双倍的话气泡顶部会反向下移 delta）。
    expect(position.pixels, closeTo(delta, 1.0), reason: '补偿恰好一倍');
    expect(tester.takeException(), isNull);
    // 收起路径（含再次锁定）见上一条用例：这里展开后控件在视口之外，点不到。
  });
}
