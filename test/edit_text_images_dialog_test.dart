import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/image_import_service.dart';
import 'package:narrchat/widgets/edit_text_images_dialog.dart';
import 'package:narrchat/widgets/image_preview.dart';

import 'helpers/fakes.dart';

void main() {
  testWidgets('识图：显示初始图片，可删除 / 添加，保存返回文本与图片', (tester) async {
    EditTextImagesResult? captured;
    final fake = FakeImageImportService(
      results: [const ImageImportResult(paths: ['img/b.png'])],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: TextButton(
                onPressed: () async {
                  captured = await showEditTextImagesDialog(
                    ctx,
                    title: '修改并重新提问',
                    initial: '你好',
                    initialImages: ['img/a.png'],
                    allowImages: true,
                    imageImport: fake,
                    maxImageSizeMB: 16,
                    convertJpgToJpeg: true,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('修改并重新提问'), findsOneWidget);
    expect(find.text('添加图片'), findsOneWidget);
    // 初始一张图片缩略图。
    expect(find.byType(ImageThumbnail), findsOneWidget);

    // 删除初始图片。
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.byType(ImageThumbnail), findsNothing);

    // 添加图片 → 走导入服务。
    await tester.tap(find.text('添加图片'));
    await tester.pumpAndSettle();
    expect(fake.calls, 1);
    expect(fake.lastSizeLimitMb, 16);
    expect(fake.lastConvertJpgToJpeg, isTrue); // 透传「jpg→jpeg 转换」开关
    expect(find.byType(ImageThumbnail), findsOneWidget);

    // 编辑文本并保存。
    await tester.enterText(find.byType(TextField), '修改后的输入');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(captured, isNotNull);
    expect(captured!.text, '修改后的输入');
    expect(captured!.images, ['img/b.png']);
  });

  testWidgets('非识图：隐藏图片区与「添加图片」按钮，仅文本编辑', (tester) async {
    EditTextImagesResult? captured;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: TextButton(
                onPressed: () async {
                  captured = await showEditTextImagesDialog(
                    ctx,
                    title: '修改并重新提问',
                    initial: '原始文本',
                    allowImages: false,
                    imageImport: FakeImageImportService(),
                    maxImageSizeMB: 16,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('添加图片'), findsNothing);
    expect(find.byType(ImageThumbnail), findsNothing);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(captured, isNotNull);
    expect(captured!.text, '原始文本');
    expect(captured!.images, isEmpty);
  });
}
