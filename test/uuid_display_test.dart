import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/widgets/uuid_display.dart';

/// `UuidDisplay` 展示组件测试：显示值 / 复制到剪贴板 / 空值提示。
void main() {
  Widget wrap(Widget child) => MaterialApp(
        home: Scaffold(body: Center(child: child)),
      );

  testWidgets('有 uuid：显示等宽值，点击复制按钮写入剪贴板', (tester) async {
    final values = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          final map = call.arguments as Map<Object?, Object?>;
          values.add(map['text'] as String? ?? '');
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await tester.pumpWidget(
      wrap(const UuidDisplay(label: '书籍 UUID', uuid: 'u-1234-5678')),
    );
    expect(find.text('书籍 UUID'), findsOneWidget);
    expect(find.text('u-1234-5678'), findsOneWidget);
    expect(find.byTooltip('复制 UUID'), findsOneWidget);

    await tester.tap(find.byTooltip('复制 UUID'));
    await tester.pump();
    expect(values, ['u-1234-5678']);
  });

  testWidgets('uuid 为空：显示提示文本，不渲染复制按钮', (tester) async {
    await tester.pumpWidget(
      wrap(const UuidDisplay(label: '书籍 UUID', uuid: '')),
    );
    expect(find.text('保存后自动生成'), findsOneWidget);
    expect(find.byTooltip('复制 UUID'), findsNothing);
  });
}
