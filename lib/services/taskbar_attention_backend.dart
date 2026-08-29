import 'dart:ffi';
import 'dart:io' show Platform, pid;

import 'package:ffi/ffi.dart';

/// 任务栏「后台任务完成」闪烁提醒后端（抽象）。
///
/// 类似 QQ 等 IM：生成在后台完成时让 Windows 任务栏按钮闪烁提示，
/// 窗口回到前台后停止。与系统通知（Toast）相互独立：通知关不关不影响闪烁。
abstract interface class TaskbarAttentionBackend {
  /// 开始任务栏闪烁（持续闪烁，直到窗口回到前台或 [stop]）。
  ///
  /// 仅 Windows 生效；其它平台、或找不到主窗口句柄时为空操作。
  Future<void> start();

  /// 停止任务栏闪烁（未在闪烁时为空操作）。
  Future<void> stop();
}

/// 基于 user32 `FindWindowExW` + `FlashWindowEx` 的 Windows 真实实现。
///
/// - 按 Flutter Windows runner 的固定窗口类名找到「主窗口」句柄
///   （图片查看器等子窗口由 desktop_multi_window 创建，类名不同，不会被命中）；
/// - 通过 `GetWindowThreadProcessId` 校验句柄属于当前进程（防止命中
///   同机其它 Flutter 应用的窗口）；
/// - `FlashWindowEx` 以 `FLASHW_ALL | FLASHW_TIMERNOFG` 持续闪烁，直到
///   窗口回到前台自动停止；[stop] 再发一次 `FLASHW_STOP` 显式收尾。
///
/// FFI 句柄与函数均为惰性解析：非 Windows 平台 / 未调用时不会加载 user32。
class Win32TaskbarAttentionBackend implements TaskbarAttentionBackend {
  static final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');
  static final _FindWindowExWDart _findWindowExW =
      _user32.lookupFunction<_FindWindowExWNative, _FindWindowExWDart>(
        'FindWindowExW',
      );
  static final _GetWindowThreadProcessIdDart _getWindowThreadProcessId =
      _user32.lookupFunction<
        _GetWindowThreadProcessIdNative,
        _GetWindowThreadProcessIdDart
      >('GetWindowThreadProcessId');
  static final _FlashWindowExDart _flashWindowEx =
      _user32.lookupFunction<_FlashWindowExNative, _FlashWindowExDart>(
        'FlashWindowEx',
      );

  /// Flutter Windows runner 的主窗口类名（windows/runner/win32_window.cpp）。
  static const String _kMainWindowClassName = 'FLUTTER_RUNNER_WIN32_WINDOW';

  // FLASHWINFO.dwFlags 取值（winuser.h）。
  static const int _kFlashStop = 0; // FLASHW_STOP
  static const int _kFlashAll = 0x3; // FLASHW_CAPTION | FLASHW_TRAY
  static const int _kFlashTimerNoFg = 0xc; // FLASHW_TIMER | FLASHW_TIMERNOFG

  /// 不限次数闪烁（uCount = ULONG_MAX）。
  static const int _kUnlimitedFlashes = 0xffffffff;

  /// 主窗口句柄缓存：首次成功查找后固定（主窗口句柄应用生命周期内不变）；
  /// 未找到时保持 0，后续每次重试，不缓存失败结果。
  int _hwnd = 0;

  @override
  Future<void> start() async {
    if (!Platform.isWindows) return;
    final hwnd = _resolveHwnd();
    if (hwnd == 0) return;
    _flash(hwnd, _kFlashAll | _kFlashTimerNoFg);
  }

  @override
  Future<void> stop() async {
    if (!Platform.isWindows) return;
    final hwnd = _resolveHwnd();
    if (hwnd == 0) return;
    _flash(hwnd, _kFlashStop);
  }

  int _resolveHwnd() {
    if (_hwnd != 0) return _hwnd;
    _hwnd = _findMainWindowHwnd();
    return _hwnd;
  }

  /// 在当前进程中查找 Flutter 主窗口句柄；找不到返回 0。
  ///
  /// 用 `FindWindowExW` 按类名逐个遍历同级窗口，并用进程 id 过滤，
  /// 确保只命中本应用的主窗口（同机其它 Flutter 应用同名类窗口被跳过）。
  int _findMainWindowHwnd() {
    final className = _kMainWindowClassName.toNativeUtf16();
    try {
      var hwnd = _findWindowExW(0, 0, className, nullptr);
      while (hwnd != 0) {
        final pidPtr = calloc<Uint32>();
        try {
          _getWindowThreadProcessId(hwnd, pidPtr);
          if (pidPtr.value == pid) return hwnd;
        } finally {
          calloc.free(pidPtr);
        }
        hwnd = _findWindowExW(0, hwnd, className, nullptr);
      }
      return 0;
    } finally {
      malloc.free(className);
    }
  }

  void _flash(int hwnd, int flags) {
    final info = calloc<_FlashWindowInfo>();
    try {
      final ref = info.ref;
      ref.cbSize = sizeOf<_FlashWindowInfo>();
      ref.hwnd = hwnd;
      ref.dwFlags = flags;
      ref.uCount = _kUnlimitedFlashes;
      ref.dwTimeout = 0; // 0 = 使用系统光标闪烁速率。
      _flashWindowEx(info);
    } finally {
      calloc.free(info);
    }
  }
}

/// FLASHWINFO（winuser.h）。
final class _FlashWindowInfo extends Struct {
  @Uint32()
  external int cbSize;

  @IntPtr()
  external int hwnd;

  @Uint32()
  external int dwFlags;

  @Uint32()
  external int uCount;

  @Uint32()
  external int dwTimeout;
}

typedef _FlashWindowExNative = Int32 Function(Pointer<_FlashWindowInfo> p);
typedef _FlashWindowExDart = int Function(Pointer<_FlashWindowInfo> p);

typedef _FindWindowExWNative = IntPtr Function(
  IntPtr parent,
  IntPtr childAfter,
  Pointer<Utf16> className,
  Pointer<Utf16> windowName,
);
typedef _FindWindowExWDart = int Function(
  int parent,
  int childAfter,
  Pointer<Utf16> className,
  Pointer<Utf16> windowName,
);

typedef _GetWindowThreadProcessIdNative = Uint32 Function(
  IntPtr hwnd,
  Pointer<Uint32> processIdOut,
);
typedef _GetWindowThreadProcessIdDart = int Function(
  int hwnd,
  Pointer<Uint32> processIdOut,
);
