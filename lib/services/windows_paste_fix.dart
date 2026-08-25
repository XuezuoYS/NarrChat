import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Windows 11 下「Win+V 剪贴板历史粘贴」失灵的修复。
///
/// 背景（flutter/flutter#143997）：Windows 11 的剪贴板历史（Win+V）选择某一项后，
/// 会往窗口发送一组**畸形的 Ctrl+V** 按键序列：每个事件的 `physical` 都是
/// `0x1600000000`，且 Ctrl-up 先于 V-down 到达，共 6 个事件。Flutter 引擎未把
/// 这组合成消息正确转换成框架可识别的按键事件，导致「Ctrl 按着时的 V down」
/// 永远不被派发，输入框的粘贴处理（默认粘贴 / 我们的 Ctrl+V 图片粘贴）都不会执行，
/// 于是什么都粘贴不上来。
///
/// 本类拦截 [PlatformDispatcher.onKeyData]，把这组畸形序列**重写成干净的 Ctrl+V**：
/// Ctrl-down → V-down → V-up → Ctrl-up，从而让输入框正常收到「粘贴」。
///
/// ⚠️ 关键约束：**绝不能吞掉「全零」KeyData（physical=0, logical=0）**。那是引擎在
/// 焦点切换时发送的 transit-mode 探测；一旦吞掉会让 `_transitMode` 保持 null，
/// 之后真实按键走 raw 通道时会触发断言、导致输入框不可编辑。因此一律原样透传。
///
/// 仅 Windows 生效（[inject] 内已按 [Platform.isWindows] 门控）；其它平台不拦截，
/// 对正常硬件按键（`physical != 0x1600000000`）也一律透传。
class WindowsPasteFix {
  WindowsPasteFix._();

  static final WindowsPasteFix instance = WindowsPasteFix._();

  // 已对照 Windows 11 真实 Win+V 输出 / Flutter 3.44.x 验证的按键 ID。
  static const int _junkPhysical = 0x1600000000;
  static const int _cleanPhysicalCtrl = 0x700e0; // Control Left
  static const int _cleanPhysicalV = 0x70019; // Key V
  static const int _logicalCtrl = 0x200000100; // Control Left
  static const int _logicalV = 0x76; // Key V
  static const int _maxInstallRetries = 5;

  int _step = 0;
  int _installAttempts = 0;

  /// 安装修复（在 `WidgetsFlutterBinding.ensureInitialized()` 之后调用）。
  ///
  /// 若 [PlatformDispatcher.onKeyData] 尚未就绪，用 postFrameCallback 重试若干次；
  /// 仍失败则放弃（不阻塞启动）。
  void inject() {
    if (!Platform.isWindows) return;
    _install();
  }

  void _install() {
    final original = PlatformDispatcher.instance.onKeyData;
    if (original == null) {
      _installAttempts++;
      if (_installAttempts >= _maxInstallRetries) {
        debugPrint('[WindowsPasteFix] onKeyData 仍为空，放弃安装。');
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) => _install());
      return;
    }
    // 始终透传到原始 callback；被吞掉的畸形事件返回 true 表示已处理。
    PlatformDispatcher.instance.onKeyData = (KeyData data) {
      final rewritten = rewrite(data);
      if (rewritten == null) return true;
      return original(rewritten);
    };
  }

  KeyData _copyWith(
    KeyData data, {
    required KeyEventType type,
    required int physical,
    required int logical,
  }) {
    return KeyData(
      timeStamp: data.timeStamp,
      type: type,
      physical: physical,
      logical: logical,
      character: null,
      synthesized: false,
      deviceType: data.deviceType,
    );
  }

  /// 重置状态机（测试用）。
  @visibleForTesting
  void resetState() => _step = 0;

  /// 重写单个 KeyData：
  /// - 全零探测 / 正常硬件键：原样透传并复位状态机；
  /// - Win+V 畸形序列（physical == [_junkPhysical]）：按 `_step` 状态机逐事件
  ///   重写为干净的 Ctrl+V；被「吞掉」的步骤返回 null（由调用方视为已处理）。
  @visibleForTesting
  KeyData? rewrite(KeyData data) {
    // 全零 transit-mode 探测：必须透传，否则输入框不可编辑。
    if (data.physical == 0 && data.logical == 0) return data;
    // 正常硬件按键：透传并复位。
    if (data.physical != _junkPhysical) {
      _step = 0;
      return data;
    }

    final down = data.type == KeyEventType.down;
    final up = data.type == KeyEventType.up;
    final isCtrl = data.logical == _logicalCtrl;
    final isV = data.logical == _logicalV;

    switch (_step) {
      case 0:
        // 期望：Ctrl down（synth=false）→ 发出干净 Ctrl down。
        if (isCtrl && down && !data.synthesized) {
          _step = 1;
          return _copyWith(
            data,
            type: KeyEventType.down,
            physical: _cleanPhysicalCtrl,
            logical: _logicalCtrl,
          );
        }
        break;
      case 1:
        // 期望：Ctrl up（synth=true）→ 吞掉（保持 Ctrl 逻辑按下）。
        if (isCtrl && up && data.synthesized) {
          _step = 2;
          return null;
        }
        break;
      case 2:
        // 期望：V down → 发出干净 V down。
        if (isV && down) {
          _step = 3;
          return _copyWith(
            data,
            type: KeyEventType.down,
            physical: _cleanPhysicalV,
            logical: _logicalV,
          );
        }
        break;
      case 3:
        // 期望：V up → 发出干净 V up。
        if (isV && up) {
          _step = 4;
          return _copyWith(
            data,
            type: KeyEventType.up,
            physical: _cleanPhysicalV,
            logical: _logicalV,
          );
        }
        break;
      case 4:
        // 期望：Ctrl down（synth=true）→ 吞掉（Windows 重复下发）。
        if (isCtrl && down && data.synthesized) {
          _step = 5;
          return null;
        }
        break;
      case 5:
        // 期望：Ctrl up（synth=true）→ 发出干净 Ctrl up，状态机归零。
        if (isCtrl && up && data.synthesized) {
          _step = 0;
          return _copyWith(
            data,
            type: KeyEventType.up,
            physical: _cleanPhysicalCtrl,
            logical: _logicalCtrl,
          );
        }
        break;
    }

    // 序列被打断：复位并透传。
    _step = 0;
    return data;
  }
}
