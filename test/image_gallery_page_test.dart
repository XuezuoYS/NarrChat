import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/providers/cloud_sync_provider.dart';
import 'package:narrchat/screens/image_gallery_page.dart';
import 'package:narrchat/services/storage_service.dart';
import 'package:narrchat/services/sync/image_deletion.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/image_viewer_window.dart'
    show ImageViewerDeletedEvents;
import 'package:provider/provider.dart';

import 'helpers/fakes.dart';

/// 测试图片库二级页（小米相册式）：网格渲染、长按/按钮进入选择、多选删除、批量导出、
/// 查看器窗口内删除的事件同步（缩略图即时移除且不回到滚动首部）。
void main() {
  Widget wrap(
    StorageService service, {
    ImageDeletionService? deletion,
    Future<String?> Function()? pick,
  }) {
    return MultiProvider(
      providers: [
        Provider<StorageService>.value(value: service),
        Provider<ImageDeletionService>.value(
          value: deletion ?? FakeImageDeletionService(),
        ),
        // 删除后触发自动同步（未配置时内部忽略）。
        ChangeNotifierProvider.value(value: CloudSyncProvider()),
      ],
      child: MaterialApp(
        theme: NarrChatTheme.light,
        home: ImageGalleryPage(directoryPicker: pick),
      ),
    );
  }

  /// 宽视口，避免窄屏下底部操作条溢出。
  void setWideViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('渲染图片网格（按修改时间）', (tester) async {
    setWideViewport(tester);
    final service = FakeStorageService(
      images: [
        StorageImageInfo(
          relPath: 'img/a.png',
          name: 'a.png',
          size: 10,
          modified: DateTime(2026, 1, 2),
        ),
        StorageImageInfo(
          relPath: 'img/b.png',
          name: 'b.png',
          size: 20,
          modified: DateTime(2026, 1, 1),
        ),
      ],
    );
    await tester.pumpWidget(wrap(service));
    await tester.pumpAndSettle();

    expect(find.byType(ImageGalleryPage), findsOneWidget);
    expect(find.byKey(const Key('gallery_tile:img/a.png')), findsOneWidget);
    expect(find.byKey(const Key('gallery_tile:img/b.png')), findsOneWidget);
    expect(find.text('2026年1月2日'), findsWidgets);
  });

  testWidgets('长按进入选择模式并选中该张', (tester) async {
    setWideViewport(tester);
    final service = FakeStorageService(
      images: [
        StorageImageInfo(
          relPath: 'img/a.png',
          name: 'a.png',
          size: 10,
          modified: DateTime(2026, 1, 2),
        ),
      ],
    );
    await tester.pumpWidget(wrap(service));
    await tester.pumpAndSettle();
    expect(find.text('完成'), findsNothing);

    await tester.longPress(find.byKey(const Key('gallery_tile:img/a.png')));
    await tester.pumpAndSettle();

    expect(find.text('完成'), findsOneWidget);
    expect(find.text('已选 1 张'), findsOneWidget);
  });

  testWidgets('多选删除：选择 → 删除 → 删除服务被调用（含墓碑）+ 列表刷新', (tester) async {
    setWideViewport(tester);
    final service = FakeStorageService(
      images: [
        StorageImageInfo(
          relPath: 'img/a.png',
          name: 'a.png',
          size: 10,
          modified: DateTime(2026, 1, 2),
        ),
        StorageImageInfo(
          relPath: 'img/b.png',
          name: 'b.png',
          size: 20,
          modified: DateTime(2026, 1, 1),
        ),
      ],
    );
    final deletion = FakeImageDeletionService(
      onDelete: (rel) async {
        service.images = service.images.where((i) => i.relPath != rel).toList();
      },
    );
    await tester.pumpWidget(wrap(service, deletion: deletion));
    await tester.pumpAndSettle();

    await tester.tap(find.text('选择'));
    await tester.pumpAndSettle();
    expect(find.text('完成'), findsOneWidget);

    await tester.tap(find.byKey(const Key('gallery_tile:img/a.png')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('gallery_tile:img/b.png')));
    await tester.pumpAndSettle();
    expect(find.text('已选 2 张'), findsOneWidget);

    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除').last);
    await tester.pumpAndSettle();

    expect(deletion.calls, 2);
    expect(deletion.deleted, containsAll(['img/a.png', 'img/b.png']));
    expect(find.text('暂无本地图片'), findsOneWidget);
  });

  testWidgets('批量导出：选择 → 导出到文件夹', (tester) async {
    setWideViewport(tester);
    final service = FakeStorageService(
      images: [
        StorageImageInfo(
          relPath: 'img/a.png',
          name: 'a.png',
          size: 10,
          modified: DateTime(2026, 1, 2),
        ),
        StorageImageInfo(
          relPath: 'img/b.png',
          name: 'b.png',
          size: 20,
          modified: DateTime(2026, 1, 1),
        ),
      ],
    );
    final outDir = Directory.systemTemp.createTempSync('gallery_export_');
    addTearDown(() {
      if (outDir.existsSync()) outDir.deleteSync(recursive: true);
    });

    await tester.pumpWidget(wrap(service, pick: () async => outDir.path));
    await tester.pumpAndSettle();

    await tester.tap(find.text('选择'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('gallery_tile:img/a.png')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('gallery_tile:img/b.png')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('导出'));
    await tester.pumpAndSettle();

    expect(service.exportedImages, containsAll(['img/a.png', 'img/b.png']));
    expect(service.exportedImagesTo, outDir.path);
    expect(find.textContaining('已导出'), findsOneWidget);
  });

  testWidgets('查看器窗口内删除：事件同步移除缩略图且停留在浏览位置（不回到首部）', (tester) async {
    setWideViewport(tester);
    // 120 张图撑起可滚动网格（10 列 × 12 行）。
    final service = FakeStorageService(
      images: [
        for (var i = 0; i < 120; i++)
          StorageImageInfo(
            relPath: 'img/p$i.png',
            name: 'p$i.png',
            size: 10,
            modified: DateTime(2026, 1, 2).subtract(Duration(minutes: i)),
          ),
      ],
    );
    await tester.pumpWidget(wrap(service));
    await tester.pumpAndSettle();

    final scrollable = tester.state<ScrollableState>(
      find.byType(Scrollable).first,
    );
    // 滚动到中部并计量偏移：若刷新回到首部则偏移归 0。
    scrollable.position.jumpTo(400);
    await tester.pump();
    expect(scrollable.position.pixels, 400);
    // 取当前视口内的一张缩略图（约第 5 行），删除前后可直接观察到。
    const deletedKey = Key('gallery_tile:img/p50.png');
    expect(find.byKey(deletedKey), findsOneWidget);

    // 模拟桌面查看器窗口删除该图 → 子窗口经跨窗口命令上报 → 主窗口事件送达：
    // 子窗口已删除本机文件，这里的替身存储同步移除该图。
    service.images = service.images
        .where((i) => i.relPath != 'img/p50.png')
        .toList();
    ImageViewerDeletedEvents.instance.reportDeleted(['img/p50.png']);
    await tester.pumpAndSettle();

    expect(find.byKey(deletedKey), findsNothing);
    expect(find.byKey(const Key('gallery_tile:img/p51.png')), findsOneWidget);
    // 事件移除只改列表不改滚动：仍停留在 400px 处（未回到首部，无需重新翻页）。
    expect(scrollable.position.pixels, 400);
  });
}
