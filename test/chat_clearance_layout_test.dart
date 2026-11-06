import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/widgets/reading_anchor.dart';

import 'helpers/chat_harness.dart';

/// 消息列的纵向留白形态（规格 §5.6 / §9 的落地版）。
///
/// 结论先说：纵向留白**不能**放在 `ListView.padding` 里。
/// - 顶部 24dp 是 `trailingSpacer` **条目**：放进 padding 的话它会被算进列表
///   内容高度，「跳到第 1 轮」永远差这一截（实测 24px）；
/// - 底部避让输入面板那段挂在**最后一行**的底部内边距上：只在 padding 里的话
///   不在任何被测量的条目里，阅读锚点看不见它，离底阅读时整屏会被面板顶走。
void main() {
  testWidgets('列表纵向不再用 padding，顶部留白是 24dp 条目', (tester) async {
    await pumpChatScreen(tester, seedRounds: 3, seedBodyRepeats: 4);
    await settle(tester);

    final list = tester.widget<ListView>(find.byType(ListView));
    expect(
      list.padding,
      const EdgeInsets.symmetric(horizontal: 20),
      reason: '纵向留白必须由条目 / 行内边距承担',
    );

    final topSpacer =
        find.byKey(const ValueKey('chat-item-spacer-top:trailingSpacer'));
    expect(topSpacer, findsOneWidget, reason: '顶部收尾留白是一条几何条目');
    expect(tester.getSize(topSpacer).height, 24);
  });

  testWidgets('底部留白挂在最后一行：输入面板长高，行高同步长高', (tester) async {
    await pumpChatScreen(tester, seedRounds: 3, seedBodyRepeats: 4);
    await settle(tester);

    // `reverse` 列表的 delegate 0 号 = 视觉底部 = 窗口最后一行（挂留白的那一行）。
    // 量 `ReadingAnchorItem`：它包着留白（内容测量在它内部、只量内容）。
    double rowHeight() =>
        tester.getRect(find.byType(ReadingAnchorItem).first).height;
    double composerHeight() =>
        tester.getRect(find.byKey(const Key('chat_composer_area'))).height;

    final rowBefore = rowHeight();
    final composerBefore = composerHeight();
    expect(rowBefore, greaterThan(0));

    // 多行输入把面板顶高（按钮行 + 输入卡一起长高）。
    await tester.enterText(
      find.byType(TextField).first,
      '第1行\n第2行\n第3行\n第4行',
    );
    // 面板高度是帧末测的，留白下一帧才跟着变：多给两帧收敛。
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }

    final composerGrowth = composerHeight() - composerBefore;
    expect(composerGrowth, greaterThan(20), reason: '多行输入应让面板长高');
    expect(
      rowHeight() - rowBefore,
      closeTo(composerGrowth, 1),
      reason: '底部避让量就等价于面板高度，必须落在最后一行里',
    );
  });
}
