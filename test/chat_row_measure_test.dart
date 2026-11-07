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
            roundIndex: 1,
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
              roundIndex: 1,
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
              roundIndex: 1,
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

  group('真实渲染行登记', () {
    Widget host(ChatRowRegistry registry, {bool showRows = true}) {
      Widget row(int round, double height) => ChatRowMeasure(
            key: ValueKey('row-$round'),
            itemKey: ChatItemKey('uuid-$round', ChatItemKind.user),
            roundIndex: round,
            onMeasured: (_, _) {},
            registry: registry,
            child: SizedBox(width: 100, height: height),
          );
      return MaterialApp(
        home: Scaffold(
          body: showRows
              ? Column(
                  children: [row(1, 100), row(2, 150), row(3, 120)],
                )
              : const SizedBox.shrink(),
        ),
      );
    }

    testWidgets('按视口顶部命中的真实行返回轮号', (tester) async {
      final registry = ChatRowRegistry();
      await tester.pumpWidget(host(registry));
      expect(registry.attachedCount, 3);

      final firstTop = tester.getTopLeft(find.byKey(const ValueKey('row-1'))).dy;
      expect(registry.roundIndexAt(firstTop + 5), 1);
      expect(registry.roundIndexAt(firstTop + 99.9), 1, reason: '行内靠底边仍算本轮');
      expect(registry.roundIndexAt(firstTop + 175), 2);
      expect(registry.roundIndexAt(firstTop + 300), 3);
    });

    testWidgets('视口超出内容两端时取最近行，不返回空', (tester) async {
      final registry = ChatRowRegistry();
      await tester.pumpWidget(host(registry));

      final firstTop = tester.getTopLeft(find.byKey(const ValueKey('row-1'))).dy;
      expect(registry.roundIndexAt(firstTop - 50), 1, reason: '顶端留白取第一行');
      expect(registry.roundIndexAt(firstTop + 1000), 3, reason: '底端留白取最后一行');
    });

    testWidgets('行卸载后注销登记，不再参与查询', (tester) async {
      final registry = ChatRowRegistry();
      await tester.pumpWidget(host(registry));
      expect(registry.attachedCount, 3);

      await tester.pumpWidget(host(registry, showRows: false));
      expect(registry.attachedCount, 0);
      expect(registry.roundIndexAt(0), isNull);
    });
  });
}
