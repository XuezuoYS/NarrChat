import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/default_cover_style.dart';
import 'package:narrchat/services/image_store.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/book_cover.dart';

import 'helpers/image_fixtures.dart';

/// 默认封面组件：插画1 / 无插画（生成灰底书名封面）/ 自定义封面。
void main() {
  late Directory userData;

  setUp(() {
    userData = Directory.systemTemp.createTempSync('narrchat_book_cover_');
    ImageStore.testUserDataRoot = userData.path;
  });

  tearDown(() {
    ImageStore.testUserDataRoot = null;
    try {
      userData.deleteSync(recursive: true);
    } catch (_) {
      // 临时目录清理失败不影响结论。
    }
  });

  Widget build(Widget child) {
    return MaterialApp(
      theme: NarrChatTheme.light,
      home: Scaffold(body: Center(child: child)),
    );
  }

  testWidgets('插画1：使用默认插画资源，不在封面上重复书名', (tester) async {
    await tester.pumpWidget(
      build(const BookCover(width: 120, title: '测试书')),
    );

    final image = tester.widget<Image>(find.byType(Image));
    // 封面会按显示宽度限制解码尺寸，`Image.asset(cacheWidth: …)` 内部包装成
    // ResizeImage；解包后再校验默认资源。
    final provider = image.image;
    expect(provider, isA<ResizeImage>());
    final resized = provider as ResizeImage;
    expect(resized.imageProvider, isA<AssetImage>());
    expect(
      (resized.imageProvider as AssetImage).assetName,
      kDefaultBookCoverAsset,
    );
    expect(find.text('测试书'), findsNothing);
  });

  testWidgets('无插画：生成灰底封面并显示书名', (tester) async {
    await tester.pumpWidget(
      build(
        const BookCover(
          width: 120,
          title: '灰皮书',
          style: DefaultCoverStyle.noIllustration,
        ),
      ),
    );

    expect(find.byType(Image), findsNothing);
    expect(find.text('灰皮书'), findsOneWidget);
  });

  testWidgets('无插画：小尺寸缩略图显示书名首字', (tester) async {
    await tester.pumpWidget(
      build(
        const BookCover(
          width: 36,
          title: '灰皮书',
          style: DefaultCoverStyle.noIllustration,
        ),
      ),
    );

    expect(find.byType(Image), findsNothing);
    expect(find.text('灰'), findsOneWidget);
    expect(find.text('灰皮书'), findsNothing);
  });

  testWidgets('有自定义封面：优先显示文件图片，不再加载默认插画', (tester) async {
    final bytes = await makePngBytes(tester, width: 4, height: 6);
    final rel = (await tester.runAsync(
      () => writeImageFixture(userData, bytes),
    ))!;

    await tester.pumpWidget(
      build(BookCover(width: 120, title: '测试书', coverImg: rel)),
    );
    await tester.pump();

    final image = tester.widget<Image>(find.byType(Image));
    expect(image.fit, BoxFit.cover);
    final provider = image.image;
    expect(provider, isA<ResizeImage>());
    expect((provider as ResizeImage).imageProvider, isA<FileImage>());
    expect(find.text('未设置封面'), findsNothing);
    expect(find.text('图片已损坏'), findsNothing);
  });

  testWidgets('自定义封面文件丢失：回落默认插画（首页不出现灰块）', (tester) async {
    await tester.pumpWidget(
      build(const BookCover(width: 120, title: '测试书', coverImg: 'img/gone.png')),
    );
    await tester.pump();

    final image = tester.widget<Image>(find.byType(Image));
    final provider = image.image;
    expect(provider, isA<ResizeImage>());
    expect((provider as ResizeImage).imageProvider, isA<AssetImage>());
    expect(find.text('图片已损坏'), findsNothing);
    expect(find.text('未设置封面'), findsNothing);
  });
}
