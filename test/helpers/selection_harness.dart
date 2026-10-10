import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// 选中（`SelectionArea` / `SelectableRegion`）相关用例的公共脚手架。
///
/// 选中结果不在公共 API 上暴露（`SelectableRegionState.getSelectedContent` 是
/// 内部委托的方法），故以**系统剪贴板**为外部锚点读取：选中 → 触发
/// `CopySelectionTextIntent.copy` → 拦截 `Clipboard.setData`
/// （与 `chat_bubble_test` 的既有做法一致）。

/// 段落内第 [offset] 个字符所在行的**行内**点（全局坐标）。
///
/// 用 `RenderParagraph.getOffsetForCaret` 换算，避免手算字体度量；并向右下各
/// 偏移一点：返回的矩形**上边界**恰好落在行顶（实测 y ≈ -0.02px），该点位于
/// 命中区外，指针事件根本到不了选中区域（拖动会「什么都不选中」）。
Offset textOffsetToPosition(WidgetTester tester, String text, int offset) {
  final paragraph = tester.renderObject<RenderParagraph>(
    find.descendant(of: find.text(text), matching: find.byType(RichText)),
  );
  const caret = Rect.fromLTWH(0.0, 0.0, 2.0, 20.0);
  return paragraph.localToGlobal(
    paragraph.getOffsetForCaret(TextPosition(offset: offset), caret) +
        Offset(1, caret.height / 2),
  );
}

/// 拦截 `Clipboard.setData`，返回按调用顺序收集到的复制文本（用例内自行断言）。
List<String> mockClipboard(WidgetTester tester) {
  final copied = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add('${(call.arguments as Map)['text']}');
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null),
  );
  return copied;
}

/// 触发「复制当前选中内容」动作（选择工具条 / Ctrl+C 的底层动作）。
///
/// [insideRegion] 必须命中选中区域**内部**的某处：`SelectionArea` 的 `Actions`
/// 注册在区域子树上，从区域外调用找不到该动作。
void copySelection(WidgetTester tester, Finder insideRegion) {
  Actions.invoke(
    tester.element(insideRegion),
    CopySelectionTextIntent.copy,
  );
}
