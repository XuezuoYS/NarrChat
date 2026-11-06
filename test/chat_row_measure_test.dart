import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/chat/chat_item.dart';
import 'package:narrchat/chat/chat_row.dart';

/// 条目高度自上报：只在高度真的变化时帧末回报一次，身份随 Key 走。
void main() {
  const key = ChatItemKey('uuid-1', ChatItemKind.ai);

  testWidgets('布局后帧末上报实测高度', (tester) async {
    final reports = <(ChatItemKey, double)>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: ChatRowMeasure(
            itemKey: key,
            onMeasured: (k, h) => reports.add((k, h)),
            child: const SizedBox(width: 100, height: 120),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(reports, [(key, 120.0)]);
  });

  testWidgets('高度不变不重复上报', (tester) async {
    final reports = <double>[];
    Widget host(double height) => MaterialApp(
          home: Center(
            child: ChatRowMeasure(
              itemKey: key,
              onMeasured: (_, h) => reports.add(h),
              child: SizedBox(width: 100, height: height),
            ),
          ),
        );

    await tester.pumpWidget(host(120));
    await tester.pump();
    expect(reports, [120.0]);

    // 重建但高度不变：不该再报（否则每帧都在改几何）。
    await tester.pumpWidget(host(120));
    await tester.pump();
    expect(reports, [120.0]);

    // 高度变了才报。
    await tester.pumpWidget(host(160));
    await tester.pump();
    expect(reports, [120.0, 160.0]);
  });

  testWidgets('身份变了要按新 Key 重新上报（切版本 / 换分支）', (tester) async {
    final reports = <ChatItemKey>[];
    Widget host(ChatItemKey itemKey) => MaterialApp(
          home: Center(
            child: ChatRowMeasure(
              itemKey: itemKey,
              onMeasured: (k, _) => reports.add(k),
              child: const SizedBox(width: 100, height: 120),
            ),
          ),
        );

    await tester.pumpWidget(host(const ChatItemKey('uuid-1', ChatItemKind.ai)));
    await tester.pump();
    expect(reports, [const ChatItemKey('uuid-1', ChatItemKind.ai)]);

    await tester.pumpWidget(host(const ChatItemKey('uuid-1', ChatItemKind.failed)));
    await tester.pump();
    expect(reports, [
      const ChatItemKey('uuid-1', ChatItemKind.ai),
      const ChatItemKey('uuid-1', ChatItemKind.failed),
    ]);
  });
}
