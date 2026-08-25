import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/screens/image_gallery_page.dart';
import 'package:narrchat/services/storage_service.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:provider/provider.dart';

import 'helpers/fakes.dart';

/// 测试本地图片库二级页（小米相册式）：网格渲染、长按/按钮进入选择、多选删除、批量导出。
void main() {
  Widget wrap(
    StorageService service, {
    Future<String?> Function()? pick,
  }) {
    return Provider<StorageService>.value(
      value: service,
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

  testWidgets('多选删除：选择 → 删除 → 服务被调用 + 列表刷新', (tester) async {
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

    expect(service.deleteCalls, 2);
    expect(service.deleted, containsAll(['img/a.png', 'img/b.png']));
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
}
