import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/utils/focus_utils.dart';

import 'helpers/chat_harness.dart';

/// 点击输入框外部取消焦点（共享工具 + 聊天主输入框）。
void main() {
  group('onTapOutside 共享工具', () {
    testWidgets('点击输入框外部取消焦点（触屏平台）', (tester) async {
      // 模拟触屏平台（Android）：Flutter 默认在此平台不会点击外部取消焦点，
      // 修复后应通过显式 onTapOutside 取消。
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      final controller = TextEditingController();
      addTearDown(controller.dispose);
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                TextField(
                  controller: controller,
                  focusNode: focusNode,
                  onTapOutside: unfocusOnTapOutside,
                ),
                const Spacer(),
              ],
            ),
          ),
        ),
      );

      // 点击输入框内部 → 正常聚焦。
      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(focusNode.hasFocus, isTrue);

      // 点击输入框外部（空白区域）→ 焦点被取消（光标停止闪烁）。
      await tester.tapAt(const Offset(200, 400));
      await tester.pump();
      expect(focusNode.hasFocus, isFalse);

      // 再次点击输入框内部 → 仍可正常重新聚焦（回归保护：不误拦截框内点击）。
      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(focusNode.hasFocus, isTrue);

      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('聊天主输入框', () {
    Future<void> pumpNarrowChat(WidgetTester tester) async {
      await pumpChatScreen(tester, size: const Size(600, 900));
    }

    /// 聊天主输入框（通过 hint 定位，避免误匹配侧边栏抽屉内的编辑框）。
    Finder chatInput() => find.widgetWithText(TextField, '输入你的行动或对话…');

    bool chatInputHasFocus(WidgetTester tester) {
      final editable = tester.widget<EditableText>(
        find.descendant(of: chatInput(), matching: find.byType(EditableText)),
      );
      return editable.focusNode.hasFocus;
    }

    testWidgets('触屏：聚焦后点击消息区空白处，输入框取消焦点', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await pumpNarrowChat(tester);

      // 点击输入框内部 → 聚焦（光标开始闪烁）。
      await tester.tap(chatInput());
      await tester.pump();
      expect(chatInputHasFocus(tester), isTrue);

      // 点击消息区空白处（输入框外部）→ 取消焦点（光标停止闪烁）。
      await tester.tapAt(const Offset(100, 300));
      await tester.pump();
      expect(chatInputHasFocus(tester), isFalse);

      // 再次点击输入框 → 可正常重新聚焦。
      await tester.tap(chatInput());
      await tester.pump();
      expect(chatInputHasFocus(tester), isTrue);

      debugDefaultTargetPlatformOverride = null;
    });
  });
}
