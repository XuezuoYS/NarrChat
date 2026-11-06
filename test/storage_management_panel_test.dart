import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/screens/image_gallery_page.dart';
import 'package:narrchat/services/storage_service.dart';
import 'package:narrchat/services/sync/image_deletion.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/storage_management_panel.dart';
import 'package:provider/provider.dart';

import 'helpers/fakes.dart';
import 'helpers/notice_harness.dart';

/// 存储管理面板（R3）：多库占用总览 + 整组导出/导入 + 旧版备份清理 + 图片库入口。
void main() {
  const sampleOverview = StorageOverview(
    databases: [
      StorageFileInfo(
        id: 'library',
        label: '书籍目录库',
        path: 'C:/data/user_data/narrchat_library.db',
        sizeBytes: 2048,
        exists: true,
      ),
      StorageFileInfo(
        id: 'book:b1',
        label: '书 b1',
        path: 'C:/data/user_data/books/narrbook_b1.db',
        sizeBytes: 4096,
        exists: true,
      ),
      StorageFileInfo(
        id: 'legacy-backup',
        label: '旧版数据库备份（2.x）',
        path: 'C:/data/user_data/narrchat.db.r2.bak',
        sizeBytes: 1024,
        exists: true,
      ),
    ],
    imageCount: 2,
    imageBytes: 1536,
    bookCount: 1,
  );

  final sampleImages = [
    StorageImageInfo(
      relPath: 'img/b.png',
      name: 'b.png',
      size: 512,
      modified: DateTime(2026, 1, 2),
    ),
    StorageImageInfo(
      relPath: 'img/a.png',
      name: 'a.png',
      size: 1024,
      modified: DateTime(2026, 1, 1),
    ),
  ];

  Widget wrap(
    StorageService service, {
    Future<String?> Function()? pick,
    Future<String?> Function()? filePick,
  }) {
    return MultiProvider(
      providers: [
        Provider<StorageService>.value(value: service),
        // 图片库二级页依赖删除服务（删除 = 删文件 + 记录同步墓碑）。
        Provider<ImageDeletionService>.value(value: FakeImageDeletionService()),
      ],
      child: MaterialApp(
        theme: NarrChatTheme.light,
        builder: floatingNoticeBuilder(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: StorageManagementPanel(
              directoryPicker: pick,
              filePicker: filePick,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('窄列（261 宽）：各区不溢出', (tester) async {
    tester.view.physicalSize = const Size(261, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      wrap(FakeStorageService(overviewValue: sampleOverview)),
    );
    await tester.pumpAndSettle();

    expect(find.text('存储管理'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: '不得出现 RenderFlex overflow');
  });

  testWidgets('渲染：多库占用总览 + 图片入口 + 三个操作按钮', (tester) async {
    final service = FakeStorageService(
      overviewValue: sampleOverview,
      images: sampleImages,
    );
    await tester.pumpWidget(wrap(service));
    await tester.pumpAndSettle();

    expect(find.text('存储管理'), findsOneWidget);
    expect(find.text('本地数据'), findsOneWidget);
    expect(find.text('书籍目录库'), findsOneWidget);
    expect(find.text('书 b1'), findsOneWidget);

    // 占用合计 = 库 + 图片；面板展示"合计/明细"。
    expect(find.text('合计占用'), findsOneWidget);

    expect(find.text('导出整组数据'), findsOneWidget);
    expect(find.text('导入整组数据'), findsOneWidget);
    expect(find.text('删除旧版备份'), findsOneWidget);
    expect(find.text('图片库'), findsOneWidget);
    expect(find.textContaining('2 张'), findsWidgets, reason: '总览与入口各显示一次');
    // 不再是内联图片列表，而是入口卡。
    expect(find.text('b.png'), findsNothing);
    expect(find.byType(ImageGalleryPage), findsNothing);
  });

  testWidgets('空图片：入口显示暂无', (tester) async {
    await tester.pumpWidget(
      wrap(FakeStorageService(overviewValue: sampleOverview)),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('暂无图片'), findsOneWidget);
  });

  testWidgets('点击图片管理入口：进入图片库二级页面', (tester) async {
    final service = FakeStorageService(
      overviewValue: sampleOverview,
      images: sampleImages,
    );
    await tester.pumpWidget(wrap(service));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();

    expect(find.byType(ImageGalleryPage), findsOneWidget);
  });

  testWidgets('导出整组数据：选目录 + 自定义名后调用 exportArchive 并提示', (tester) async {
    final service = FakeStorageService(overviewValue: sampleOverview);
    final outDir = Directory.systemTemp.createTempSync('storage_out_');
    addTearDown(() {
      if (outDir.existsSync()) outDir.deleteSync(recursive: true);
    });

    await tester.pumpWidget(wrap(service, pick: () async => outDir.path));
    await tester.pumpAndSettle();

    await tester.tap(find.text('导出整组数据'));
    await tester.pumpAndSettle();

    // 自定义文件名对话框；默认名带 .zip，用户改成 narrchat。
    await tester.enterText(find.byType(TextField), 'narrchat');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(service.exportedTo, outDir.path);
    expect(service.exportedName, 'narrchat.zip'); // 自动补全 .zip
    expect(find.textContaining('已导出'), findsOneWidget);
    await flushNotices(tester);
  });

  testWidgets('导入整组数据：确认后调用 importArchive 并提示结果', (tester) async {
    final service = FakeStorageService(overviewValue: sampleOverview)
      ..importResult = const StorageImportResult(
        ok: true,
        message: '已还原 3 个文件',
        backupPath: 'C:/data/.import-backup-1',
        restoredFiles: 3,
      );

    await tester.pumpWidget(
      wrap(service, filePick: () async => 'C:/data/narrchat.zip'),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('导入整组数据'));
    await tester.pumpAndSettle();
    expect(find.text('导入整组数据'), findsWidgets);
    expect(find.text('开始导入'), findsOneWidget);

    await tester.tap(find.text('开始导入'));
    await tester.pumpAndSettle();

    expect(service.importedArchive, 'C:/data/narrchat.zip');
    expect(find.textContaining('已还原 3 个文件'), findsOneWidget);
    await flushNotices(tester);
  });

  testWidgets('导入整组数据：取消选择文件时不调导入', (tester) async {
    final service = FakeStorageService(overviewValue: sampleOverview);
    await tester.pumpWidget(wrap(service, filePick: () async => null));
    await tester.pumpAndSettle();

    await tester.tap(find.text('导入整组数据'));
    await tester.pumpAndSettle();

    expect(service.importedArchive, isNull);
    expect(find.text('开始导入'), findsNothing);
  });

  testWidgets('导入整组数据：选择非 .zip 文件时提示且不调导入', (tester) async {
    final service = FakeStorageService(overviewValue: sampleOverview);
    await tester.pumpWidget(wrap(service, filePick: () async => 'C:/data/x.txt'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('导入整组数据'));
    await tester.pumpAndSettle();

    expect(service.importedArchive, isNull);
    expect(find.text('请选择 .zip 导出包。'), findsOneWidget);
    await flushNotices(tester);
  });

  testWidgets('删除旧版备份：确认后调用 deleteLegacyBackup', (tester) async {
    final service = FakeStorageService(overviewValue: sampleOverview);
    await tester.pumpWidget(wrap(service));
    await tester.pumpAndSettle();

    await tester.tap(find.text('删除旧版备份'));
    await tester.pumpAndSettle();
    expect(find.text('删除旧版数据库备份'), findsOneWidget);

    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(service.deleteLegacyCalls, 1);
    expect(find.textContaining('旧版备份已删除'), findsOneWidget);
    await flushNotices(tester);
  });
}
