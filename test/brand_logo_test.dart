import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/brand_logo.dart';

void main() {
  Widget build(Widget child) {
    return MaterialApp(
      theme: NarrChatTheme.light,
      home: Scaffold(body: Center(child: child)),
    );
  }

  testWidgets('仅显示应用图标的圆角图像', (tester) async {
    await tester.pumpWidget(build(const BrandLogo(size: 30)));

    final image = tester.widget<Image>(find.byType(Image));
    expect(image.width, 30);
    expect(image.height, 30);
    expect(
      (image.image as AssetImage).assetName,
      'assets/app_icon_rounded.png',
    );
    expect(find.text('NarrChat'), findsNothing);
  });

  testWidgets('附带标题文字时显示「NarrChat」', (tester) async {
    await tester.pumpWidget(build(const BrandLogo(title: 'NarrChat')));

    expect(find.byType(Image), findsOneWidget);
    expect(find.text('NarrChat'), findsOneWidget);
  });

  testWidgets('vertical 时文字排在 Logo 下方', (tester) async {
    await tester.pumpWidget(
      build(
        const BrandLogo(
          size: 30,
          title: 'NarrChat',
          axis: BrandLogoAxis.vertical,
        ),
      ),
    );

    final logo = tester.getRect(find.byType(Image));
    final text = tester.getRect(find.text('NarrChat'));
    expect(text.top, greaterThanOrEqualTo(logo.bottom));
    expect(text.left, closeTo(logo.left, 0.01));
  });
}
