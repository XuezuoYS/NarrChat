import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/screens/image_gallery_page.dart';
import 'package:narrchat/services/storage_service.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/storage_management_panel.dart';
import 'package:provider/provider.dart';

import 'helpers/fakes.dart';

void main() {
  Widget wrap(
    StorageService service, {
    Future<String?> Function()? pick,
  }) {
    return Provider<StorageService>.value(
      value: service,
      child: MaterialApp(
        theme: NarrChatTheme.light,
        home: Scaffold(
          body: SingleChildScrollView(
            child: StorageManagementPanel(directoryPicker: pick),
          ),
        ),
      ),
    );
  }

  testWidgets('渲染：数据库导出区 + 图片管理入口（含统计）', (tester) async {
    final service = FakeStorageService(
      db: StorageDbInfo(
        path: 'C:/data/narrchat.db',
        size: 2048,
        modified: DateTime(2026, 1, 1),
      ),
      images: [
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
      ],
    );
    await tester.pumpWidget(wrap(service));
    await tester.pumpAndSettle();

    expect(find.text('存储管理'), findsOneWidget);
    expect(find.text('导出数据库'), findsOneWidget);
    expect(find.textContaining('共 2 张'), findsOneWidget);
    // 不再是内联列表（无行名文本，而是入口卡）。
    expect(find.text('b.png'), findsNothing);
    expect(find.byType(ImageGalleryPage), findsNothing);
  });

  testWidgets('空图片：入口显示暂无', (tester) async {
    await tester.pumpWidget(wrap(FakeStorageService()));
    await tester.pumpAndSettle();
    expect(find.textContaining('暂无本地图片'), findsOneWidget);
  });

  testWidgets('点击图片管理入口：进入图片库二级页面', (tester) async {
    final service = FakeStorageService(
      images: [
        StorageImageInfo(
          relPath: 'img/a.png',
          name: 'a.png',
          size: 10,
          modified: DateTime(2026, 1, 1),
        ),
      ],
    );
    await tester.pumpWidget(wrap(service));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();

    expect(find.byType(ImageGalleryPage), findsOneWidget);
  });

  testWidgets('导出数据库：选目录 + 自定义名后调用导出并提示', (tester) async {
    final service = FakeStorageService(
      db: StorageDbInfo(
        path: 'C:/data/narrchat.db',
        size: 2048,
        modified: DateTime(2026, 1, 1),
      ),
    );
    final outDir = Directory.systemTemp.createTempSync('storage_out_');
    addTearDown(() {
      if (outDir.existsSync()) outDir.deleteSync(recursive: true);
    });

    await tester.pumpWidget(wrap(service, pick: () async => outDir.path));
    await tester.pumpAndSettle();

    await tester.tap(find.text('导出数据库'));
    await tester.pumpAndSettle();

    // 自定义文件名对话框。
    await tester.enterText(find.byType(TextField), 'backup');
    await tester.tap(find.text('导出'));
    await tester.pumpAndSettle();

    expect(service.exportedTo, outDir.path);
    expect(service.exportedName, 'backup.db'); // 自动补全 .db
    expect(find.textContaining('已导出'), findsOneWidget);
  });
}
