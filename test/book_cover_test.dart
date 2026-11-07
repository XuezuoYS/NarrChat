import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/default_cover_style.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/book_cover.dart';

/// 默认封面组件：插画1 / 无插画（生成灰底书名封面）。
void main() {
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
}
