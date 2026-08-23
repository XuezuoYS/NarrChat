import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/widgets/image_preview.dart';

void main() {
  testWidgets('查看器：提供「保存到本地」与关闭按钮', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: TextButton(
                onPressed: () => showImageViewer(ctx, 'img/x.png'),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('保存到本地'), findsOneWidget);
    expect(find.byIcon(Icons.close), findsOneWidget);
    // 右上角关闭按钮可退出。
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.text('保存到本地'), findsNothing);
  });

  testWidgets('查看器：单击非按钮空白区域退出', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: TextButton(
                onPressed: () => showImageViewer(ctx, 'img/x.png'),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('保存到本地'), findsOneWidget);

    // 点击左上角空白（远离关闭 / 保存按钮）→ 退出查看器。
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.text('保存到本地'), findsNothing);
  });
}
