import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/widgets/image_preview.dart';

/// [ImageViewerPage]（photo_view 全屏查看器）测试。
///
/// 验证可靠可测的部分：查看器结构（「保存到本地 / 关闭 / 页码指示」）与多图支持
/// （页码 `N/M` 反映传入图片数，即需求点 2 的滑动切换框架）。
///
/// 说明：photo_view 的缩放 / 左右滑动切换需图片真实加载后才挂载手势；而
/// `ImageStore.resolveAbsolute` 在 widget 测试（FakeAsync）中会因真实文件 I/O
/// （`Directory.create`）不推进而挂起，故无法在 widget 测试中真正渲染图片库并拖拽换页。
/// 这些交互是 photo_view 上游已测试的行为，此处以结构断言覆盖。
void main() {
  Widget buildApp(List<String> images) {
    return MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: TextButton(
              onPressed: () => showImageViewer(ctx, images, 0),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('查看器：提供「保存到本地」与关闭按钮，关闭可退出', (tester) async {
    await tester.pumpWidget(buildApp(['img/x.png']));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('保存到本地'), findsOneWidget);
    expect(find.text('1/1'), findsOneWidget); // 页码指示
    expect(find.byIcon(Icons.close), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.text('保存到本地'), findsNothing);
  });

  testWidgets('查看器：多图页码反映图片数量（需求点 2 的滑动框架）', (tester) async {
    await tester.pumpWidget(buildApp(['img/a.png', 'img/b.png', 'img/c.png']));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 初始显示第一张，页码为 1/3。
    expect(find.text('1/3'), findsOneWidget);
    // 多张图时仍提供保存 / 关闭。
    expect(find.text('保存到本地'), findsOneWidget);
    expect(find.byIcon(Icons.close), findsOneWidget);
  });
}
