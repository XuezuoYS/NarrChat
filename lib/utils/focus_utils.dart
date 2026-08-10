import 'package:flutter/widgets.dart';

/// 点击输入框外部时取消焦点（收起光标与输入法）。
///
/// Flutter 的 `TextField` 默认仅在部分桌面/Web 平台点击外部时取消焦点，
/// 在触屏平台（Android 等）上不会主动取消焦点，导致键盘收回后
/// 光标仍在输入框内闪烁。将本函数赋给 `TextField.onTapOutside`
/// 可在任意平台统一实现「点击外部取消输入状态」。
///
/// 通过 `FocusManager` 而不是 `FocusScope.of(context)` 实现，避免依赖
/// 具体 BuildContext，任何场景（含对话框）均可直接复用。
void unfocusOnTapOutside(PointerDownEvent event) {
  FocusManager.instance.primaryFocus?.unfocus();
}
