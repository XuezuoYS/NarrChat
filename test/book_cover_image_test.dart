import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/image_store.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/book_cover_image.dart';

import 'helpers/image_fixtures.dart';

/// 自定义封面图的三态：有图 / 未设置 / 图片已损坏，以及首页用的 fallback。
void main() {
  late Directory userData;

  setUp(() {
    userData = Directory.systemTemp.createTempSync('narrchat_cover_image_');
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

  /// 让 widget 里发起的真实文件 I/O 走完（FakeAsync 不会自己推进 dart:io），
  /// 再 pump 一帧让界面拿到结果。
  ///
  /// 现在封面展示优先走同步解析（`ImageStore.canResolveSync`），常规用例
  /// 只需 `pump`；这里保留给「必须异步解析」的路径兜底。
  Future<void> settleFileIo(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('没有封面（NULL）：灰底显示「未设置封面」，不加载图片', (tester) async {
    await tester.pumpWidget(
      build(const BookCoverImage(relPath: null, width: 96)),
    );
    await tester.pump();

    expect(find.text('未设置封面'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('空串同样当作没有封面', (tester) async {
    await tester.pumpWidget(
      build(const BookCoverImage(relPath: '', width: 96)),
    );
    await tester.pump();

    expect(find.text('未设置封面'), findsOneWidget);
  });

  testWidgets('文件找不到：灰底显示「图片已损坏」', (tester) async {
    await tester.pumpWidget(
      build(const BookCoverImage(relPath: 'img/missing.png', width: 96)),
    );
    await settleFileIo(tester);

    expect(find.text('图片已损坏'), findsOneWidget);
    expect(find.text('未设置封面'), findsNothing);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('非法路径（不在 img/ 下）：同样按「图片已损坏」处理', (tester) async {
    await tester.pumpWidget(
      build(const BookCoverImage(relPath: 'other/x.png', width: 96)),
    );
    await settleFileIo(tester);

    expect(find.text('图片已损坏'), findsOneWidget);
  });

  testWidgets('正常文件：显示文件图片，cover 居中（非 2:3 居中等比放大）', (tester) async {
    final bytes = await makePngBytes(tester, width: 4, height: 6);
    final rel = (await tester.runAsync(
      () => writeImageFixture(userData, bytes),
    ))!;

    await tester.pumpWidget(build(BookCoverImage(relPath: rel, width: 96)));
    await settleFileIo(tester);

    final image = tester.widget<Image>(find.byType(Image));
    expect(image.fit, BoxFit.cover);
    expect(image.alignment, Alignment.center);
    // 按显示宽度限制了解码尺寸 → 包装成 ResizeImage，解包后是文件来源。
    final provider = image.image;
    expect(provider, isA<ResizeImage>());
    // 路径分隔符随平台（Windows 是反斜杠），统一归一化后比末尾两段。
    expect(
      ((provider as ResizeImage).imageProvider as FileImage)
          .file
          .path
          .replaceAll('\\', '/'),
      endsWith('img/cover.png'),
    );
    expect(find.text('图片已损坏'), findsNothing);
    expect(find.text('未设置封面'), findsNothing);
  });

  testWidgets('有 fallback：没封面时显示 fallback，不出现灰底文案', (tester) async {
    await tester.pumpWidget(
      build(
        const BookCoverImage(
          relPath: null,
          width: 96,
          fallback: Text('默认封面'),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('默认封面'), findsOneWidget);
    expect(find.text('未设置封面'), findsNothing);
  });

  testWidgets('有 fallback：图片坏了也显示 fallback（首页永不出现灰块）', (tester) async {
    await tester.pumpWidget(
      build(
        const BookCoverImage(
          relPath: 'img/missing.png',
          width: 96,
          fallback: Text('默认封面'),
        ),
      ),
    );
    await settleFileIo(tester);

    expect(find.text('默认封面'), findsOneWidget);
    expect(find.text('图片已损坏'), findsNothing);
  });

  testWidgets('小尺寸（36px 列表缩略图）：只留图标，文字不出现也不溢出', (tester) async {
    await tester.pumpWidget(
      build(const BookCoverImage(relPath: null, width: 36)),
    );
    await tester.pump();

    expect(find.byIcon(Icons.image_outlined), findsOneWidget);
    expect(find.text('未设置封面'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
