import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/providers/cloud_sync_provider.dart';
import 'package:narrchat/services/sync/image_deletion.dart';
import 'package:narrchat/widgets/image_preview.dart';
import 'package:photo_view/photo_view.dart' show PhotoViewScaleState;
import 'package:provider/provider.dart';

import 'helpers/fakes.dart';

/// [ImageViewerPage]（photo_view 全屏查看器）测试。
///
/// 验证可靠可测的部分：查看器结构（「保存到本地 / 关闭 / 页码指示」）、多图支持
/// （页码 `N/M` 反映传入图片数，即需求点 2 的滑动切换框架）与长按/右键操作菜单
/// （另存为 / 复制 / 删除；删除含二次确认、更新页码并通知调用方）。
///
/// 说明：
/// - 这里直接构造并 push `ImageViewerPage`（应用内查看器路由）：`showImageViewer`
///   在 Windows 上会走独立窗口分支（FakeAsync 下跨窗口通道不响应），故不通过它。
/// - photo_view 的缩放 / 左右滑动切换需图片真实加载后才挂载手势；而
///   `ImageStore.resolveAbsolute` 在 widget 测试（FakeAsync）中会因真实文件 I/O
///   （`Directory.create`）不推进而挂起，故无法在 widget 测试中真正渲染图片库并拖拽换页。
///   这些交互是 photo_view 上游已测试的行为，此处以结构断言覆盖；
///   长按菜单挂在画布容器键 `image_viewer_canvas` 上，不依赖图片加载结果。
void main() {
  Widget buildApp(
    List<String> images, {
    ImageDeletionService? deletion,
    void Function(String relPath)? onDeleted,
  }) {
    return MultiProvider(
      providers: [
        Provider<ImageDeletionService>.value(
          value: deletion ?? FakeImageDeletionService(),
        ),
        // 删除后触发自动同步（未配置时内部忽略）。
        ChangeNotifierProvider.value(value: CloudSyncProvider()),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: TextButton(
                onPressed: () => Navigator.of(ctx).push(
                  MaterialPageRoute(
                    builder: (_) => ImageViewerPage(
                      images: images,
                      initialIndex: 0,
                      onDeleted: onDeleted,
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
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

  testWidgets('查看器：长按弹出操作菜单，删除需二次确认并移除当前项', (tester) async {
    final deletion = FakeImageDeletionService();
    await tester
        .pumpWidget(buildApp(['img/a.png', 'img/b.png'], deletion: deletion));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('1/2'), findsOneWidget);

    // 长按画布 → 操作菜单（另存为 / 复制图片 / 删除）。
    await tester.longPress(find.byKey(const Key('image_viewer_canvas')));
    await tester.pumpAndSettle();
    expect(find.text('另存为'), findsOneWidget);
    expect(find.text('复制图片'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);

    // 删除：先取消（删除服务不被调用，页码不变）。
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('删除图片'), findsOneWidget); // 二次确认对话框
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(deletion.calls, 0);
    expect(find.text('1/2'), findsOneWidget);

    // 再次长按并确认删除 → 移除当前项，页码改为 1/1。
    await tester.longPress(find.byKey(const Key('image_viewer_canvas')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除').last);
    await tester.pumpAndSettle();

    expect(deletion.deleted, ['img/a.png']);
    expect(deletion.calls, 1);
    expect(find.text('1/1'), findsOneWidget);
    expect(find.text('已删除'), findsOneWidget);
  });

  testWidgets('查看器：删除成功回调 onDeleted 通知调用方（列表移除该项）',
      (tester) async {
    final deleted = <String>[];
    await tester.pumpWidget(buildApp(
      ['img/a.png', 'img/b.png'],
      onDeleted: deleted.add,
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.longPress(find.byKey(const Key('image_viewer_canvas')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除').last);
    await tester.pumpAndSettle();
    expect(deleted, ['img/a.png']);
  });

  testWidgets('查看器：删除最后一张后关闭查看器', (tester) async {
    final deletion = FakeImageDeletionService();
    await tester.pumpWidget(buildApp(['img/a.png'], deletion: deletion));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.longPress(find.byKey(const Key('image_viewer_canvas')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除').last);
    await tester.pumpAndSettle();
    expect(deletion.deleted, ['img/a.png']);
    // 变更为关闭查看器：不再展示「保存到本地」。
    expect(find.text('保存到本地'), findsNothing);
  });

  // 移动端 QQ 式单击/双击决策（纯函数，隔离可测）。
  // 说明：photo_view 的缩放/滑动/手势需图片真实加载后才挂载，而 widget 测试中
  // `ImageStore.resolveAbsolute`（真实文件 I/O）无法推进，故用纯函数覆盖「缩放状态→行为」
  // 的核心判断；真实触屏手势行为需上 Android 真机验证。
  group('移动端缩放单击/双击决策', () {
    test('未放大单击 → 退出', () {
      expect(shouldExitPreviewOnTap(PhotoViewScaleState.initial), isTrue);
    });

    test('任意放大状态单击 → 缩回（不退出）', () {
      expect(shouldExitPreviewOnTap(PhotoViewScaleState.covering), isFalse);
      expect(shouldExitPreviewOnTap(PhotoViewScaleState.zoomedIn), isFalse);
      expect(shouldExitPreviewOnTap(PhotoViewScaleState.zoomedOut), isFalse);
      expect(shouldExitPreviewOnTap(PhotoViewScaleState.originalSize), isFalse);
    });

    test('双击：未放大 → 铺满放大', () {
      expect(
        mobileDoubleTapCycle(PhotoViewScaleState.initial),
        PhotoViewScaleState.covering,
      );
    });

    test('双击：任意放大态 → 回到未放大', () {
      expect(mobileDoubleTapCycle(PhotoViewScaleState.covering),
          PhotoViewScaleState.initial);
      expect(mobileDoubleTapCycle(PhotoViewScaleState.zoomedIn),
          PhotoViewScaleState.initial);
      expect(mobileDoubleTapCycle(PhotoViewScaleState.zoomedOut),
          PhotoViewScaleState.initial);
      expect(mobileDoubleTapCycle(PhotoViewScaleState.originalSize),
          PhotoViewScaleState.initial);
    });
  });
}
