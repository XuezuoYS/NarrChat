import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

/// Windows 输入法（IME）候选窗/组合窗跟随光标的修复组件。
///
/// 背景：Flutter 在 Windows 上通过 IMM32 把 IME 候选窗定位到「光标全局坐标」，
/// 该坐标由引擎持有的两个信息算出：
/// - `composing_rect`：组合区/光标在可编辑区内的**局部矩形**（来自框架的
///   `TextInput.setMarkedTextRect`）；
/// - `editabletext_transform`：可编辑区局部 → 全局的变换矩阵（来自框架的
///   `TextInput.setEditableSizeAndTransform`）。
///
/// 已知缺陷（flutter/flutter#92050 等）：
/// 1. 框架 `EditableText._updateComposingRectIfNeeded` 在**未组合**时把
///    `setMarkedTextRect` 发成**文本开头 offset=0 的光标**，而不是真实光标。
///    长文本编辑框滚出视口顶部后，offset=0 早已在屏幕外 → 引擎把 IME 候选窗
///    定位到屏幕外 → 被 Windows 钳制到**屏幕最顶部**（此时光标其实在视口内）。
/// 2. 框架仅在聚焦/文本变化/图层合成回调时发送变换矩阵，滚动场景下不一定
///    及时更新。
///
/// 本组件包住任意可滚动区域（放在应用根部即可覆盖全局，含对话框）：
/// 在 Windows 上监听滚动、聚焦与光标变化，**直接**向引擎重发：
/// - `TextInput.setMarkedTextRect`：**真实光标**的局部矩形
///   （`selection.baseOffset` → `getLocalRectForCaret`，替代框架的 offset=0）；
/// - `TextInput.setEditableSizeAndTransform`：最新的可编辑区尺寸 + 变换矩阵。
///
/// 引擎收到这两条消息后会重算并把 IME 候选窗重定位到**光标处** —— 即让输入
/// 法的框跟随光标本身。本组件**不会改动任何滚动位置**。
///
/// 仅在 Windows 上生效，其它平台直接透传子组件、零副作用。
class ImeCaretSync extends StatefulWidget {
  const ImeCaretSync({super.key, required this.child});

  final Widget child;

  @override
  State<ImeCaretSync> createState() => _ImeCaretSyncState();
}

class _ImeCaretSyncState extends State<ImeCaretSync> {
  /// 同一帧内多个触发源只调度一次帧末动作。
  bool _pending = false;

  /// 正在跟踪的聚焦编辑框及其 controller（用于监听光标/文本变化）。
  TextEditingController? _trackedController;

  /// 上次发送给引擎的矩形/变换，避免重复发送。
  Rect? _lastSentRect;
  Matrix4? _lastSentTransform;

  static bool get _isWindows =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_handleFocusChanged);
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_handleFocusChanged);
    _trackedController?.removeListener(_scheduleSync);
    super.dispose();
  }

  /// 聚焦变化：跟踪聚焦编辑框的 controller（光标/文本变化时同步），
  /// 并立即同步一次（覆盖「聚焦时输入框顶部已在视口外」的场景）。
  void _handleFocusChanged() {
    if (!_isWindows) {
      _trackedController?.removeListener(_scheduleSync);
      _trackedController = null;
      return;
    }
    final EditableTextState? editable = _focusedEditable();
    final TextEditingController? controller = editable?.widget.controller;
    if (controller != _trackedController) {
      _trackedController?.removeListener(_scheduleSync);
      _trackedController = controller;
      controller?.addListener(_scheduleSync);
    }
    _scheduleSync();
  }

  bool _onNotification(ScrollNotification notification) {
    if (!_isWindows || notification.depth != 0) {
      return false;
    }
    _scheduleSync();
    return false;
  }

  void _scheduleSync() {
    if (!_isWindows || _pending) {
      return;
    }
    _pending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pending = false;
      final EditableTextState? editable = _focusedEditable();
      if (editable == null) {
        return;
      }
      _syncImeToCaret(editable);
    });
  }

  /// 当前持有焦点的文本编辑框（EditableText）State，无则返回 null。
  EditableTextState? _focusedEditable() {
    final FocusNode? focus = FocusManager.instance.primaryFocus;
    final BuildContext? focusContext = focus?.context;
    if (focusContext == null) {
      return null;
    }
    return focusContext.findAncestorStateOfType<EditableTextState>();
  }

  /// 把「真实光标局部矩形 + 可编辑区尺寸/变换」直接重发给引擎，
  /// 让引擎用最新数据把 IME 候选窗重新锚定到光标处。
  void _syncImeToCaret(EditableTextState editable) {
    try {
      final RenderEditable renderEditable = editable.renderEditable;
      if (!renderEditable.attached) {
        return;
      }
      final TextEditingValue value = editable.textEditingValue;
      if (!value.selection.isValid) {
        return;
      }
      // 真实光标（用 selection.baseOffset，而非框架未组合态的 offset=0）。
      final Rect caretRect = renderEditable.getLocalRectForCaret(
        TextPosition(offset: value.selection.baseOffset),
      );
      final Size size = renderEditable.size;
      final Matrix4 transform = renderEditable.getTransformTo(null);

      if (caretRect != _lastSentRect) {
        _lastSentRect = caretRect;
        SystemChannels.textInput
            .invokeMethod<void>('TextInput.setMarkedTextRect', <String, dynamic>{
              'x': caretRect.left,
              'y': caretRect.top,
              'width': caretRect.width,
              'height': caretRect.height,
            })
            .catchError((Object _) {});
      }
      if (transform != _lastSentTransform) {
        _lastSentTransform = transform;
        SystemChannels.textInput
            .invokeMethod<void>(
              'TextInput.setEditableSizeAndTransform',
              <String, dynamic>{
                'width': size.width,
                'height': size.height,
                'transform': transform.storage,
              },
            )
            .catchError((Object _) {});
      }
      // 顺带强制重绘，让框架自身的合成回调也走一遍（双保险）。
      editable.context.findRenderObject()?.markNeedsPaint();
    } catch (_) {
      // 几何/通道异常时静默忽略，不影响正常滚动。
    }
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: _onNotification,
      child: widget.child,
    );
  }
}
