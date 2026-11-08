import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/screens/cover_crop_page.dart';
import 'package:narrchat/services/cover_image_renderer.dart';
import 'package:narrchat/services/app_notice_center.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/utils/cover_crop_geometry.dart';

import 'helpers/notice_harness.dart';

/// 封面裁剪页：固定 2:3 取景框、手势（捏合缩放+旋转 / 拖动平移）、确认渲染。
void main() {
  late _FakeRenderer renderer;
  late ui.Image image;

  setUp(() {
    renderer = _FakeRenderer();
  });

  // 说明：测试图由 dart:ui 直接生成，尺寸很小；不在这里 dispose——
  // 用例结束时页面可能仍挂着 RawImage（失败用例刻意停在页面上），
  // 提前释放会让引擎在下一帧访问已释放资源。

  /// 造一张纯色方块图（不需要真实解码，直接走 dart:ui）。
  Future<ui.Image> makeImage(WidgetTester tester, int width, int height) async {
    return (await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawRect(
        ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        ui.Paint()..color = const ui.Color(0xFF3366FF),
      );
      final picture = recorder.endRecording();
      try {
        return await picture.toImage(width, height);
      } finally {
        picture.dispose();
      }
    }))!;
  }

  /// pump 主机页面并压上裁剪页，返回「裁剪结果」的 Future。
  Future<Future<Uint8List?>> pumpCropPage(
    WidgetTester tester, {
    Size size = const Size(1200, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final navigatorKey = GlobalKey<NavigatorState>();
    final noticeCenter = AppNoticeCenter();
    addTearDown(noticeCenter.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: NarrChatTheme.light,
        navigatorKey: navigatorKey,
        builder: floatingNoticeBuilder(center: noticeCenter),
        home: const Scaffold(),
      ),
    );
    final result = navigatorKey.currentState!.push<Uint8List>(
      MaterialPageRoute<Uint8List>(
        builder: (_) => CoverCropPage(image: image, renderer: renderer),
      ),
    );
    await tester.pumpAndSettle();
    return result;
  }

  /// 双指捏合：两指从 [from] 间距拉到 [to] 间距（同时放大）。
  Future<void> pinch(
    WidgetTester tester, {
    double from = 60,
    double to = 180,
  }) async {
    final center = tester.getCenter(find.byKey(const Key('cover_crop_canvas')));
    final left = await tester.startGesture(
      center - Offset(from / 2, 0),
      pointer: 7,
    );
    final right = await tester.startGesture(
      center + Offset(from / 2, 0),
      pointer: 8,
    );
    await tester.pump();
    await left.moveTo(center - Offset(to / 2, 0));
    await right.moveTo(center + Offset(to / 2, 0));
    await tester.pump();
    await left.up();
    await right.up();
    await tester.pump();
  }

  testWidgets('打开即是固定 2:3 取景框，直接确定返回渲染字节', (tester) async {
    image = await makeImage(tester, 300, 300);
    final result = await pumpCropPage(tester);

    expect(find.byKey(const Key('cover_crop_canvas')), findsOneWidget);
    final geometry = renderer.lastGeometry;
    expect(geometry, isNull, reason: '还没确认时不渲染');

    await tester.tap(find.byKey(const Key('cover_crop_confirm')));
    await tester.pumpAndSettle();

    expect(renderer.calls, 1);
    final used = renderer.lastGeometry!;
    expect(used.viewportSize.width * 3, closeTo(used.viewportSize.height * 2, 0.01),
        reason: '取景框必须是 2:3');
    expect(used.zoom, 1);
    expect(used.angle, 0);
    expect(used.offset, Offset.zero);
    expect(await result, renderer.bytes);
    expect(find.byType(CoverCropPage), findsNothing, reason: '确认后应退出裁剪页');
  });

  testWidgets('取消返回 null 且不调用渲染器', (tester) async {
    image = await makeImage(tester, 300, 300);
    final result = await pumpCropPage(tester);

    await tester.tap(find.byKey(const Key('cover_crop_cancel')));
    await tester.pumpAndSettle();

    expect(renderer.calls, 0);
    expect(await result, isNull);
    expect(find.byType(CoverCropPage), findsNothing);
  });

  testWidgets('预览保持原图比例：图片不被取景框的 2:3 压扁', (tester) async {
    // 3:2 横图：cover 适配后高度撑满取景框、宽度溢出（横向被裁）。
    image = await makeImage(tester, 300, 200);
    await pumpCropPage(tester);

    final size = tester.getSize(find.byType(RawImage));
    expect(
      size.width / size.height,
      closeTo(3 / 2, 1e-6),
      reason: '图片盒子的比例必须等于原图比例，不能被取景框压成 2:3',
    );
    expect(size.height, closeTo(630, 0.01), reason: 'cover 适配后高度正好铺满');
    expect(
      size.width,
      greaterThan(420),
      reason: '宽度超出取景框（多出来的部分由 ClipRect 裁掉）',
    );
  });

  testWidgets('电脑滚轮：向上滚放大、向下滚缩小（且真的看得见）', (tester) async {
    image = await makeImage(tester, 300, 300);
    final result = await pumpCropPage(tester);

    final before = tester.getSize(find.byType(RawImage)).width;
    final center = tester.getCenter(find.byKey(const Key('cover_crop_canvas')));
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    pointer.hover(center);

    await tester.sendEventToBinding(pointer.scroll(const Offset(0, -120)));
    await tester.pump();
    final zoomedIn = tester.getSize(find.byType(RawImage)).width;
    expect(zoomedIn, greaterThan(before), reason: '向上滚应放大');

    await tester.sendEventToBinding(pointer.scroll(const Offset(0, -120)));
    await tester.pump();
    final zoomedMore = tester.getSize(find.byType(RawImage)).width;
    expect(zoomedMore, greaterThan(zoomedIn), reason: '继续向上滚继续放大');

    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 120)));
    await tester.pump();
    final zoomedOut = tester.getSize(find.byType(RawImage)).width;
    expect(zoomedOut, lessThan(zoomedMore), reason: '向下滚应缩小');

    await tester.tap(find.byKey(const Key('cover_crop_confirm')));
    await tester.pumpAndSettle();
    expect(renderer.lastGeometry!.zoom, greaterThan(1), reason: '两次放大一次缩小后仍大于 1');
    expect(await result, renderer.bytes);
  });

  testWidgets('旋转滑块：设值即改角度，画面与导出同步', (tester) async {
    image = await makeImage(tester, 300, 300);
    final result = await pumpCropPage(tester);

    final sliderFinder = find.byKey(const Key('cover_crop_rotation_slider'));
    final slider = tester.widget<Slider>(sliderFinder);
    expect(slider.min, -180);
    expect(slider.max, 180);
    expect(slider.value, 0);

    slider.onChanged!(30);
    await tester.pump();

    expect(
      tester.widget<Slider>(sliderFinder).value,
      closeTo(30, 1e-6),
      reason: '滑块数值跟着几何走',
    );
    expect(find.text('30°'), findsOneWidget);
    // 拖动中不补角：缩放条不能被带着动（用户反馈「旋转时缩放条会动」）。
    expect(
      tester
          .widget<Slider>(find.byKey(const Key('cover_crop_zoom_slider')))
          .value,
      1,
      reason: '旋转过程中缩放倍数保持用户设定值',
    );

    // 松手（onChangeEnd）才补角：此时缩放条跳到「刚好铺满」所需的倍数。
    tester.widget<Slider>(sliderFinder).onChangeEnd!(30);
    await tester.pump();
    final settledZoom = tester
        .widget<Slider>(find.byKey(const Key('cover_crop_zoom_slider')))
        .value;
    expect(settledZoom, greaterThan(1), reason: '30° 斜着需要放大才不会露白');

    await tester.tap(find.byKey(const Key('cover_crop_confirm')));
    await tester.pumpAndSettle();

    final geometry = renderer.lastGeometry!;
    expect(
      geometry.angle,
      closeTo(30 * math.pi / 180, 1e-9),
      reason: '导出用的角度必须与滑块一致',
    );
    expect(
      geometry.zoom,
      closeTo(geometry.minZoom, 1e-9),
      reason: '导出前一定已经补到刚好铺满',
    );
    expect(await result, renderer.bytes);
  });

  testWidgets('旋转松手后自动补角：拖动中漏白、松开后画面放大铺满', (tester) async {
    image = await makeImage(tester, 300, 300);
    final result = await pumpCropPage(tester);

    final rotationFinder = find.byKey(const Key('cover_crop_rotation_slider'));
    final zoomFinder = find.byKey(const Key('cover_crop_zoom_slider'));
    final rotation = tester.widget<Slider>(rotationFinder);

    rotation.onChanged!(30);
    await tester.pump();
    final leakedWidth = tester.getSize(find.byType(RawImage)).width;
    expect(
      tester.widget<Slider>(zoomFinder).value,
      1,
      reason: '拖动中允许四角漏白，不补角',
    );

    rotation.onChangeEnd!(30);
    await tester.pump();
    expect(
      tester.widget<Slider>(zoomFinder).value,
      greaterThan(1),
      reason: '松手后补角，缩放条跟着跳到所需倍数',
    );
    expect(
      tester.getSize(find.byType(RawImage)).width,
      greaterThan(leakedWidth),
      reason: '补角就是真的把画面放大了',
    );

    await tester.tap(find.byKey(const Key('cover_crop_confirm')));
    await tester.pumpAndSettle();
    final geometry = renderer.lastGeometry!;
    expect(geometry.zoom, closeTo(geometry.minZoom, 1e-9));
    expect(await result, renderer.bytes);
  });

  testWidgets('双击旋转条：角度回到 0°', (tester) async {
    image = await makeImage(tester, 300, 300);
    final result = await pumpCropPage(tester);

    final rotationFinder = find.byKey(const Key('cover_crop_rotation_slider'));
    tester.widget<Slider>(rotationFinder).onChanged!(40);
    await tester.pump();
    expect(tester.widget<Slider>(rotationFinder).value, closeTo(40, 1e-6));

    final rect = tester.getRect(rotationFinder);
    final point = Offset(rect.left + rect.width * 0.72, rect.center.dy);
    await tester.tapAt(point);
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tapAt(point);
    await tester.pump();
    await tester.pump();

    expect(
      tester.widget<Slider>(rotationFinder).value,
      0,
      reason: '双击旋转条应还原到 0°',
    );

    await tester.tap(find.byKey(const Key('cover_crop_confirm')));
    await tester.pumpAndSettle();
    expect(renderer.lastGeometry!.angle, 0);
    expect(await result, renderer.bytes);
  });

  testWidgets('双击缩放条：回到「刚好铺满」', (tester) async {
    image = await makeImage(tester, 300, 300);
    final result = await pumpCropPage(tester);

    final zoomFinder = find.byKey(const Key('cover_crop_zoom_slider'));
    tester.widget<Slider>(zoomFinder).onChanged!(3);
    await tester.pump();
    expect(tester.widget<Slider>(zoomFinder).value, closeTo(3, 1e-9));

    final rect = tester.getRect(zoomFinder);
    final point = Offset(rect.left + rect.width * 0.7, rect.center.dy);
    await tester.tapAt(point);
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tapAt(point);
    await tester.pump();
    await tester.pump();

    expect(
      tester.widget<Slider>(zoomFinder).value,
      closeTo(1, 1e-9),
      reason: '双击缩放条应还原到刚好铺满（角度 0 时就是 1×）',
    );

    await tester.tap(find.byKey(const Key('cover_crop_confirm')));
    await tester.pumpAndSettle();
    expect(renderer.lastGeometry!.zoom, closeTo(1, 1e-9));
    expect(await result, renderer.bytes);
  });

  testWidgets('画布覆盖整块区域：取景框外的遮罩区也能拖动', (tester) async {
    image = await makeImage(tester, 160, 90);
    final result = await pumpCropPage(tester);

    final canvas = find.byKey(const Key('cover_crop_canvas'));
    final size = tester.getSize(canvas);
    expect(
      size.width,
      greaterThan(800),
      reason: '画布应是整块可用区域，而不是只有 2:3 取景框那么大',
    );

    // 从取景框左侧外面的位置开始拖（那里是压暗遮罩区）。
    final rect = tester.getRect(canvas);
    await tester.dragFrom(
      Offset(rect.left + 60, rect.center.dy),
      const Offset(80, 0),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('cover_crop_confirm')));
    await tester.pumpAndSettle();
    expect(
      renderer.lastGeometry!.offset.dx,
      greaterThan(20),
      reason: '框外区域也是手势区，拖得动图片',
    );
    expect(await result, renderer.bytes);
  });

  testWidgets('缩放滑块：设值即缩放（桌面没有滚轮时的替代路径）', (tester) async {
    image = await makeImage(tester, 300, 300);
    final result = await pumpCropPage(tester);

    final sliderFinder = find.byKey(const Key('cover_crop_zoom_slider'));
    final slider = tester.widget<Slider>(sliderFinder);
    expect(slider.value, 1);
    expect(slider.min, 1, reason: '1 = 当前角度下刚好铺满');
    expect(slider.max, CoverCropGeometry.maxZoom);

    slider.onChanged!(2.5);
    await tester.pump();

    expect(
      tester.widget<Slider>(sliderFinder).value,
      closeTo(2.5, 1e-9),
    );
    expect(find.text('2.5×'), findsOneWidget);
    // 预览跟着放大：cover 适配后的宽度（630）× 2.5。
    expect(
      tester.getSize(find.byType(RawImage)).width,
      closeTo(630 * 2.5, 0.01),
    );

    await tester.tap(find.byKey(const Key('cover_crop_confirm')));
    await tester.pumpAndSettle();
    expect(renderer.lastGeometry!.zoom, closeTo(2.5, 1e-9));
    expect(await result, renderer.bytes);
  });

  testWidgets('90° 按钮：角度按整格变化（左转 / 右转）', (tester) async {
    image = await makeImage(tester, 300, 300);
    final result = await pumpCropPage(tester);

    await tester.tap(find.byKey(const Key('cover_crop_rotate_right')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('cover_crop_confirm')));
    await tester.pumpAndSettle();

    expect(
      renderer.lastGeometry!.angle,
      closeTo(math.pi / 2, 1e-6),
      reason: '右转 90°',
    );
    expect(await result, renderer.bytes);
  });

  testWidgets('单指拖动：按累计位移移动图片（不会弹回中心）', (tester) async {
    // 16:9 横图：横向有余量，可以拖动。
    image = await makeImage(tester, 160, 90);
    final result = await pumpCropPage(tester);

    final center = tester.getCenter(find.byKey(const Key('cover_crop_canvas')));
    final before = tester.getTopLeft(find.byType(RawImage));
    final gesture = await tester.startGesture(
      center,
      kind: PointerDeviceKind.mouse,
    );
    // 分三小步移动：旧实现每次都从手势起点重算、只加最后一帧的位移，
    // 于是画面只挪一小步就停住（看起来就是「锁在中心」）。
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    final after = tester.getTopLeft(find.byType(RawImage));
    expect(after.dx - before.dx, greaterThan(60), reason: '位移要累计，不能只算最后一帧');

    await tester.tap(find.byKey(const Key('cover_crop_confirm')));
    await tester.pumpAndSettle();
    expect(renderer.lastGeometry!.offset.dx, greaterThan(60));
    expect(await result, renderer.bytes);
  });

  testWidgets('双指捏合放大 + 单指拖动：缩放变大、位移可动，仍不露白', (tester) async {
    image = await makeImage(tester, 300, 300);
    final result = await pumpCropPage(tester);

    await pinch(tester);
    await tester.drag(
      find.byKey(const Key('cover_crop_canvas')),
      const Offset(60, -40),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('cover_crop_confirm')));
    await tester.pumpAndSettle();

    final used = renderer.lastGeometry!;
    expect(used.zoom, greaterThan(1.5), reason: '捏合应放大（60→180 约 3 倍）');
    expect(used.offset, isNot(Offset.zero), reason: '放大后拖动应产生位移');
    // 不变量：四个角仍在图片里（用与几何测试同一套判据）。
    final halfViewW = used.viewportSize.width / 2;
    final halfViewH = used.viewportSize.height / 2;
    final halfImageW = used.displaySize.width / 2;
    final halfImageH = used.displaySize.height / 2;
    for (final corner in <Offset>[
      Offset(-halfViewW, -halfViewH),
      Offset(halfViewW, -halfViewH),
      Offset(halfViewW, halfViewH),
      Offset(-halfViewW, halfViewH),
    ]) {
      final dx = corner.dx - used.offset.dx;
      final dy = corner.dy - used.offset.dy;
      final localX = dx * math.cos(used.angle) + dy * math.sin(used.angle);
      final localY = -dx * math.sin(used.angle) + dy * math.cos(used.angle);
      expect(localX.abs(), lessThanOrEqualTo(halfImageW + 1e-6));
      expect(localY.abs(), lessThanOrEqualTo(halfImageH + 1e-6));
    }
    expect(await result, renderer.bytes);
  });

  testWidgets('重置：缩放 / 角度 / 位移回到初始状态', (tester) async {
    image = await makeImage(tester, 300, 300);
    final result = await pumpCropPage(tester);

    await pinch(tester);
    await tester.tap(find.byKey(const Key('cover_crop_rotate_left')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('cover_crop_reset')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('cover_crop_confirm')));
    await tester.pumpAndSettle();

    final used = renderer.lastGeometry!;
    expect(used.zoom, 1);
    expect(used.angle, 0);
    expect(used.offset, Offset.zero);
    expect(await result, renderer.bytes);
  });

  testWidgets('渲染失败：留在裁剪页并给出错误提示', (tester) async {
    image = await makeImage(tester, 300, 300);
    renderer.fail = true;
    await pumpCropPage(tester);

    await tester.tap(find.byKey(const Key('cover_crop_confirm')));
    await tester.pumpAndSettle();

    expect(renderer.calls, 1);
    expect(find.byType(CoverCropPage), findsOneWidget, reason: '失败不退出');
    expect(find.textContaining('封面裁剪失败'), findsOneWidget);
    // 失败后按钮恢复可点，用户还能重试或取消。
    final confirm = tester.widget<FilledButton>(
      find.byKey(const Key('cover_crop_confirm')),
    );
    expect(confirm.onPressed, isNotNull);
    // 收尾：清掉悬浮通知的驻留定时器，避免「Timer is still pending」。
    await flushNotices(tester);
  });
}

/// 记录调用与几何的渲染替身。
class _FakeRenderer implements CoverRenderer {
  final Uint8List bytes = Uint8List.fromList([1, 2, 3, 4]);
  int calls = 0;
  CoverCropGeometry? lastGeometry;
  bool fail = false;

  @override
  Future<Uint8List> render({
    required ui.Image image,
    required CoverCropGeometry geometry,
  }) async {
    calls++;
    lastGeometry = geometry;
    if (fail) throw StateError('渲染失败');
    return bytes;
  }
}
