import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/widgets/ime_caret_sync.dart';

void main() {
  late ScrollController scrollController;
  late TextEditingController textController;
  late FocusNode focusNode;

  setUp(() {
    scrollController = ScrollController();
    textController = TextEditingController();
    focusNode = FocusNode();
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    scrollController.dispose();
    textController.dispose();
    focusNode.dispose();
  });

  /// 构造：ImeCaretSync 包裹一个可滚动区域，顶部是文本编辑框，下方是占位高内容。
  Widget buildApp() {
    return ImeCaretSync(
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            controller: scrollController,
            child: Column(
              children: [
                TextField(
                  controller: textController,
                  focusNode: focusNode,
                  maxLines: null,
                ),
                const SizedBox(height: 2000),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 多行文本，光标置于末尾（局部 Y 明显大于 0，模拟长文本编辑场景）。
  void setupMultilineCaret() {
    textController.text = '第一行\n第二行\n第三行\n第四行\n第五行\n第六行\n第七行';
    textController.selection = TextSelection.collapsed(
      offset: textController.text.length,
    );
  }

  /// 拦截文本输入平台通道，收集「组合区矩形 / 可编辑区尺寸变换」消息。
  List<MethodCall> installTextInputSpy(WidgetTester tester) {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.textInput,
      (MethodCall call) async {
        if (call.method == 'TextInput.setMarkedTextRect' ||
            call.method == 'TextInput.setEditableSizeAndTransform') {
          calls.add(call);
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.textInput, null);
    });
    return calls;
  }

  /// 最后一次 setMarkedTextRect 的 y（真实光标局部 Y）。
  double? lastMarkedRectY(List<MethodCall> calls) {
    for (final call in calls.reversed) {
      if (call.method == 'TextInput.setMarkedTextRect') {
        return ((call.arguments as Map)['y'] as num).toDouble();
      }
    }
    return null;
  }

  /// 最后一次 setEditableSizeAndTransform 的垂直位移（Matrix4 列主序 storage[13]=ty）。
  double? lastTransformTy(List<MethodCall> calls) {
    for (final call in calls.reversed) {
      if (call.method == 'TextInput.setEditableSizeAndTransform') {
        final transform = ((call.arguments as Map)['transform'] as List).cast<num>();
        return transform[13].toDouble();
      }
    }
    return null;
  }

  testWidgets('Windows 下聚焦时向引擎发送「真实光标」局部矩形（而非 offset=0）', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    setupMultilineCaret();
    final calls = installTextInputSpy(tester);

    await tester.pumpWidget(buildApp());
    await tester.pump();

    focusNode.requestFocus();
    await tester.pump();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // 关键：setMarkedTextRect 的 y 应为真实光标位置（多行末尾，局部 Y 明显 > 0），
    // 而不是框架默认的文本开头 offset=0 —— 这才能让 IME 框锚定在光标处。
    final y = lastMarkedRectY(calls);
    expect(y, isNotNull);
    expect(y, greaterThan(50));

    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Windows 下滚动后引擎收到更新后的可编辑区变换', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    setupMultilineCaret();
    final calls = installTextInputSpy(tester);

    await tester.pumpWidget(buildApp());
    await tester.pump();

    focusNode.requestFocus();
    await tester.pump();
    await tester.pumpAndSettle();

    final tyBefore = lastTransformTy(calls);
    expect(tyBefore, isNotNull);

    // 向下滚动 400：编辑框上移，其「局部→全局」变换的 ty 应变小（为负）。
    scrollController.jumpTo(400);
    await tester.pump(); // 应用滚动 + 执行帧末的 IME 重锚定
    await tester.pump();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final tyAfter = lastTransformTy(calls);
    expect(tyAfter, isNotNull);
    expect(tyAfter, lessThan(tyBefore! - 300));
    // 同时确认不改动滚动位置。
    expect(scrollController.offset, closeTo(400, 0.001));

    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Windows 下未聚焦文本输入框时滚动不受影响、不抛异常', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await tester.pumpWidget(buildApp());
    await tester.pump();

    scrollController.jumpTo(300);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(scrollController.offset, closeTo(300, 0.001));

    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('非 Windows 平台不干预滚动行为', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await tester.pumpWidget(buildApp());
    await tester.pump();

    focusNode.requestFocus();
    await tester.pump();
    expect(focusNode.hasFocus, isTrue);
    await tester.pumpAndSettle();

    scrollController.jumpTo(400);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(scrollController.offset, closeTo(400, 0.001));

    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });
}
