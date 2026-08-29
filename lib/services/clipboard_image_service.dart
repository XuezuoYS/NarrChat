import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:pasteboard/pasteboard.dart';

/// 剪贴板图片写入器（查看器「复制图片」动作；可注入替身供测试，避免触碰真实剪贴板）。
abstract class ClipboardImageWriter {
  /// 将一张图片文件复制到系统剪贴板。
  ///
  /// - [absPath]：原图文件绝对路径（Windows 以 CF_HDROP 复制文件本身，保留原格式）；
  /// - [bytes]：文件字节（像素通道用；非 Windows 平台经 pasteboard 写入图片）。
  Future<void> writeImage({required String absPath, required Uint8List bytes});
}

/// 跨平台实现。
///
/// - **Windows**（两段式，满足「粘贴路径全正常 + Win+V 仅一条源格式记录」）：
///   1. 先写入 **CF_HDROP（原始图片文件，未转码）**——剪贴板历史（Win+V）据此
///      记录**一条「源文件格式」条目**（如 jpeg），这是历史唯一要出现的条目；
///   2. 500ms 后补写**像素三格式**（PNG 格式 + CF_DIBV5 + CF_DIB，同 Chromium）
///      + CF_HDROP：最终剪贴板同时有文件与像素——
///      应用内粘贴优先读文件（JPEG 原字节）、资源管理器粘贴原始文件、
///      即时通讯/图形编辑器粘贴像素图片，全部正常。
///
///   注：实测一次性混写「像素 + 文件」会被历史服务整批忽略（零条目）；
///       先像素后文件则产生「PNG + 源格式」两条——都不符合要求。
/// - **其它平台**：交给 pasteboard（Android 等原生剪贴板图片写入）。
class SystemClipboardImageWriter implements ClipboardImageWriter {
  const SystemClipboardImageWriter();

  @override
  Future<void> writeImage({required String absPath, required Uint8List bytes}) {
    if (Platform.isWindows) {
      return _writeWindows(absPath: absPath, bytes: bytes);
    }
    return Pasteboard.writeImage(bytes);
  }

  Future<void> _writeWindows({
    required String absPath,
    required Uint8List bytes,
  }) async {
    final dropFiles = buildWindowsDropFiles(absPath);
    WindowsClipboardImage? image;
    try {
      image = await encodeWindowsImage(bytes);
    } catch (_) {
      // 像素解码/编码失败（如异常 JPEG）：降级为仅复制原始文件——
      // 粘贴到资源管理器 / 本应用仍为原格式原字节，不会「完全无法复制」。
      if (!setWindowsClipboardFile(absPath)) {
        throw Exception('Windows 剪贴板写入失败');
      }
      return;
    }
    final img = image;
    // 单次混合写入（像素三格式 + CF_HDROP 原文件）：
    // - 实测「两条相同写入」会让历史服务在第二次处理时把已记录的条目
    //   移除/替换（条目随后消失）；单次写入只有一次更新做快照判定；
    // - 像素格式为**全分辨率**：超过 Win+V 历史上限的图片由系统自然跳过
    //   （与 QQ 一致），但剪贴板内容不受影响——粘贴仍全尺寸可用。
    if (!setWindowsClipboard(img, dropFiles: dropFiles)) {
      // 写入偶发失败（剪贴板被其它进程占用等）：稍候整体重试一次。
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (!setWindowsClipboard(img, dropFiles: dropFiles)) {
        throw Exception('Windows 剪贴板写入失败');
      }
    }
  }
}

/// 一次 Windows 图片复制所需的像素格式数据（PNG 注册格式 + CF_DIBV5 + CF_DIB）。
class WindowsClipboardImage {
  /// 注册格式「PNG」的原始 PNG 字节（图像类消费者 / Word 等）。
  final Uint8List png;

  /// CF_DIBV5 数据（[buildWindowsDibV5Rgba]，保留 alpha）。
  final Uint8List dibV5;

  /// CF_DIB 数据（[buildWindowsDibRgba]，alpha 恒 255；经典 GDI 消费者）。
  final Uint8List dib;

  const WindowsClipboardImage({
    required this.png,
    required this.dibV5,
    required this.dib,
  });
}

/// Windows 剪贴板写入函数签名（测试可注入替身，不触碰真实系统剪贴板）。
///
/// [dropFiles] 非空时，同一次剪贴板会话还会写入 CF_HDROP（原始图片文件）。
typedef WindowsClipboardSetter = bool Function(
  WindowsClipboardImage image,
  Uint8List? dropFiles,
);

WindowsClipboardSetter _windowsClipboardSetter = _defaultSetWindowsClipboard;

/// 测试注入口：替换 Windows 剪贴板写入实现（不触碰真实系统剪贴板）。
@visibleForTesting
set debugWindowsClipboardSetterOverride(WindowsClipboardSetter setter) =>
    _windowsClipboardSetter = setter;

/// 仅文件复制（CF_HDROP）写入器：像素编码失败时的降级路径。
typedef WindowsClipboardFileSetter = bool Function(String filePath);
WindowsClipboardFileSetter _windowsClipboardFileSetter =
    _defaultSetWindowsClipboardFile;

@visibleForTesting
set debugWindowsClipboardFileSetterOverride(
        WindowsClipboardFileSetter setter) =>
    _windowsClipboardFileSetter = setter;

/// 以一次剪贴板会话写入像素三格式（+ 可选 CF_HDROP 原始文件）；失败返回 false。
bool setWindowsClipboard(WindowsClipboardImage image, {Uint8List? dropFiles}) {
  if (!Platform.isWindows) return false;
  return _windowsClipboardSetter(image, dropFiles);
}

/// 将 [filePath]（原始图片文件）以 CF_HDROP 写入 Windows 系统剪贴板；失败返回 false。
bool setWindowsClipboardFile(String filePath) {
  if (!Platform.isWindows) return false;
  return _windowsClipboardFileSetter(filePath);
}

bool _defaultSetWindowsClipboard(WindowsClipboardImage image, Uint8List? dropFiles) =>
    _Win32Clipboard.set(image: image, dropFiles: dropFiles);

bool _defaultSetWindowsClipboardFile(String filePath) =>
    _Win32Clipboard.setDropFiles(buildWindowsDropFiles(filePath));

/// 把任意图片字节（PNG / JPEG / BMP 等）解码并编码为三种像素剪贴板格式
/// （**全分辨率、不压缩**）。
///
/// 说明：Windows 剪贴板历史（Win+V）对图片条目有大小上限（实测约 2~3MiB，
/// 与 QQ 等应用行为一致——超限图片同样不进历史，属系统限制、无需兼容）；
/// 但剪贴板内容本身不受影响：超限图片仍能正常复制/粘贴（应用内经 CF_HDROP
/// 拿到全尺寸原图，资源管理器粘贴原文件，纯图像目标粘贴全分辨率像素）。
Future<WindowsClipboardImage> encodeWindowsImage(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final image = frame.image;
  try {
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (png == null || rgba == null) {
      throw Exception('位图数据读取失败');
    }
    final pixels =
        rgba.buffer.asUint8List(rgba.offsetInBytes, rgba.lengthInBytes);
    return WindowsClipboardImage(
      png: png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
      dibV5: buildWindowsDibV5Rgba(
        width: image.width,
        height: image.height,
        pixels: pixels,
      ),
      dib: buildWindowsDibRgba(
        width: image.width,
        height: image.height,
        pixels: pixels,
      ),
    );
  } finally {
    image.dispose();
    codec.dispose();
  }
}

/// 将「宽 × 高 × 4」的**自顶向下 RGBA**像素组装为 CF_DIB（40 字节
/// BITMAPINFOHEADER + 自底向上 B G R A，alpha 恒 255）。
///
/// 经典格式：兼容所有 GDI 消费方；32bpp BI_RGB 的 alpha 字节许多解码器
/// 按 XRGB 忽略，置 255 保证粘贴到任何应用都完全不透明。
Uint8List buildWindowsDibRgba({
  required int width,
  required int height,
  required Uint8List pixels,
}) {
  assert(width > 0 && height > 0);
  assert(pixels.length >= width * height * 4);
  const headerSize = 40; // BITMAPINFOHEADER
  final rowStride = width * 4;
  final out = Uint8List(headerSize + rowStride * height);
  final data = ByteData.view(out.buffer);
  data.setUint32(0, headerSize, Endian.little); // biSize
  data.setInt32(4, width, Endian.little); // biWidth
  data.setInt32(8, height, Endian.little); // biHeight（正值 = 自底向上存储）
  data.setUint16(12, 1, Endian.little); // biPlanes
  data.setUint16(14, 32, Endian.little); // biBitCount
  data.setUint32(16, 0, Endian.little); // biCompression = BI_RGB
  data.setUint32(20, rowStride * height, Endian.little); // biSizeImage
  for (var y = 0; y < height; y++) {
    final src = (height - 1 - y) * rowStride; // 首行像素位于 DIB 底部
    final dst = headerSize + y * rowStride;
    for (var x = 0; x < width; x++) {
      final i = src + x * 4;
      final o = dst + x * 4;
      out[o] = pixels[i + 2]; // B
      out[o + 1] = pixels[i + 1]; // G
      out[o + 2] = pixels[i]; // R
      out[o + 3] = 0xff; // A
    }
  }
  return out;
}

/// 将「宽 × 高 × 4」的**自顶向下 RGBA**像素组装为 CF_DIBV5（124 字节
/// BITMAPV5HEADER + 自底向上 B G R A，**保留源图 alpha**）。
///
/// 头字段与 Chromium CreateBitmapV5HeaderForARGB8888 一致：
/// bV5AlphaMask=0xFF000000、bV5CSType=LCS_WINDOWS_COLOR_SPACE、bV5Intent=LCS_GM_IMAGES。
Uint8List buildWindowsDibV5Rgba({
  required int width,
  required int height,
  required Uint8List pixels,
}) {
  assert(width > 0 && height > 0);
  assert(pixels.length >= width * height * 4);
  const headerSize = 124; // BITMAPV5HEADER
  final rowStride = width * 4;
  final out = Uint8List(headerSize + rowStride * height);
  final data = ByteData.view(out.buffer);
  data.setUint32(0, headerSize, Endian.little); // bV5Size
  data.setInt32(4, width, Endian.little); // bV5Width
  data.setInt32(8, height, Endian.little); // bV5Height（正值 = 自底向上）
  data.setUint16(12, 1, Endian.little); // bV5Planes
  data.setUint16(14, 32, Endian.little); // bV5BitCount
  data.setUint32(16, 0, Endian.little); // bV5Compression = BI_RGB
  data.setUint32(20, rowStride * height, Endian.little); // bV5SizeImage
  data.setUint32(52, 0xff000000, Endian.little); // bV5AlphaMask
  data.setUint32(56, 0x73524742, Endian.little); // bV5CSType = LCS_WINDOWS_COLOR_SPACE
  data.setUint32(108, 2, Endian.little); // bV5Intent = LCS_GM_IMAGES
  for (var y = 0; y < height; y++) {
    final src = (height - 1 - y) * rowStride; // 首行像素位于 DIB 底部
    final dst = headerSize + y * rowStride;
    for (var x = 0; x < width; x++) {
      final i = src + x * 4;
      final o = dst + x * 4;
      out[o] = pixels[i + 2]; // B
      out[o + 1] = pixels[i + 1]; // G
      out[o + 2] = pixels[i]; // R
      out[o + 3] = pixels[i + 3]; // A（保留源图 alpha）
    }
  }
  return out;
}

/// 把单个文件路径组装为 Windows CF_HDROP 数据：
/// DROPFILES(20B) + 路径 UTF-16 字节 + 双个终止空字符（路径终止 + 列表终止）。
///
/// 与 Explorer「复制文件」完全同构：粘贴到文件目标时得到原始文件本身，
/// 扩展名与字节不变（JPEG 复制后粘贴仍是 JPEG）；本应用粘贴也优先读它。
Uint8List buildWindowsDropFiles(String filePath) {
  const headerSize = 20; // DROPFILES
  final utf16 = <int>[...filePath.codeUnits, 0, 0];
  final out = Uint8List(headerSize + utf16.length * 2);
  final data = ByteData.view(out.buffer);
  data.setUint32(0, headerSize, Endian.little); // pFiles：文件名数组偏移
  data.setUint32(4, 0, Endian.little); // pt.x
  data.setUint32(8, 0, Endian.little); // pt.y
  data.setUint32(12, 0, Endian.little); // fNC = FALSE
  data.setUint32(16, 1, Endian.little); // fWide = TRUE（UTF-16）
  for (var i = 0; i < utf16.length; i++) {
    data.setUint16(headerSize + i * 2, utf16[i], Endian.little);
  }
  return out;
}

// ---------------------------------------------------------------------------
// Win32 剪贴板（user32 + kernel32；惰性解析，仅 Windows 调用时加载）
// ---------------------------------------------------------------------------

/// Windows 剪贴板写入（native 层）：像素三格式 + 可选 CF_HDROP；或仅 CF_HDROP。
///
/// 每块内存经 GlobalAlloc(GHND) 分配并写入后交给 SetClipboardData：
/// - 成功：系统接管内存，不再释放；
/// - 失败：对应块主动释放并返回 false（失败时系统未接管）。
class _Win32Clipboard {
  static final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');
  static final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');

  static final _OpenClipboardDart _openClipboard =
      _user32.lookupFunction<_OpenClipboardNative, _OpenClipboardDart>(
          'OpenClipboard');
  static final _EmptyClipboardDart _emptyClipboard =
      _user32.lookupFunction<_EmptyClipboardNative, _EmptyClipboardDart>(
          'EmptyClipboard');
  static final _SetClipboardDataDart _setClipboardData =
      _user32.lookupFunction<_SetClipboardDataNative, _SetClipboardDataDart>(
          'SetClipboardData');
  static final _CloseClipboardDart _closeClipboard =
      _user32.lookupFunction<_CloseClipboardNative, _CloseClipboardDart>(
          'CloseClipboard');
  static final _RegisterClipboardFormatDart _registerClipboardFormat =
      _user32.lookupFunction<
        _RegisterClipboardFormatNative,
        _RegisterClipboardFormatDart
      >('RegisterClipboardFormatW');
  static final _GlobalAllocDart _globalAlloc =
      _kernel32.lookupFunction<_GlobalAllocNative, _GlobalAllocDart>(
          'GlobalAlloc');
  static final _GlobalLockDart _globalLock =
      _kernel32.lookupFunction<_GlobalLockNative, _GlobalLockDart>(
          'GlobalLock');
  static final _GlobalUnlockDart _globalUnlock =
      _kernel32.lookupFunction<_GlobalUnlockNative, _GlobalUnlockDart>(
          'GlobalUnlock');
  static final _GlobalFreeDart _globalFree =
      _kernel32.lookupFunction<_GlobalFreeNative, _GlobalFreeDart>(
          'GlobalFree');
  static final _SleepDart _sleep =
      _kernel32.lookupFunction<_SleepNative, _SleepDart>('Sleep');

  /// 注册的「PNG」格式 id（同名格式全系统一致；0 = 注册失败，跳过该格式）。
  static int? _pngFormatId;

  /// Clipboard 格式常量（winuser.h）。
  static const int _cfHdrop = 15;
  static const int _cfDibV5 = 17;
  static const int _cfDib = 8;

  /// GHND = GMEM_MOVEABLE | GMEM_ZEROINIT。
  static const int _ghnd = 0x42;

  /// 打开剪贴板的最大重试次数与间隔：剪贴板常被其它进程（剪贴板历史服务、
  /// 输入法、IM 等）短暂占用，一次性 OpenClipboard 经常失败——此前
  /// 「有时复制无效果」的主要可疑根因；重试逻辑与 pasteboard 原生一致并加长。
  static const int _kMaxClipboardOpenAttempts = 10;
  static const int _kClipboardOpenRetryDelayMs = 5;

  static bool _openClipboardWithRetry() {
    for (var i = 0; i < _kMaxClipboardOpenAttempts; i++) {
      if (_openClipboard(0) != 0) return true;
      _sleep(_kClipboardOpenRetryDelayMs);
    }
    return false;
  }

  static bool set({
    required WindowsClipboardImage image,
    Uint8List? dropFiles,
  }) {
    final pngFormat = _getPngFormatId();
    final hPng = pngFormat == 0 ? 0 : _allocAndFill(image.png);
    final hV5 = _allocAndFill(image.dibV5);
    final hDib = _allocAndFill(image.dib);
    final hDrop = dropFiles == null ? 0 : _allocAndFill(dropFiles);
    if (hV5 == 0 || hDib == 0 || (dropFiles != null && hDrop == 0)) {
      if (hPng != 0) _globalFree(hPng);
      if (hV5 != 0) _globalFree(hV5);
      if (hDib != 0) _globalFree(hDib);
      if (hDrop != 0) _globalFree(hDrop);
      return false;
    }
    if (!_openClipboardWithRetry()) {
      if (hPng != 0) _globalFree(hPng);
      _globalFree(hV5);
      _globalFree(hDib);
      if (hDrop != 0) _globalFree(hDrop);
      return false;
    }
    _emptyClipboard();
    var anyOk = false;
    if (hPng != 0) {
      if (_setClipboardData(pngFormat, hPng) != 0) {
        anyOk = true;
      } else {
        _globalFree(hPng);
      }
    }
    if (_setClipboardData(_cfDibV5, hV5) != 0) {
      anyOk = true;
    } else {
      _globalFree(hV5);
    }
    if (_setClipboardData(_cfDib, hDib) != 0) {
      anyOk = true;
    } else {
      _globalFree(hDib);
    }
    if (hDrop != 0) {
      if (_setClipboardData(_cfHdrop, hDrop) != 0) {
        anyOk = true;
      } else {
        _globalFree(hDrop);
      }
    }
    _closeClipboard();
    return anyOk;
  }

  static bool setDropFiles(Uint8List dropFiles) {
    final hDrop = _allocAndFill(dropFiles);
    if (hDrop == 0) return false;
    if (!_openClipboardWithRetry()) {
      _globalFree(hDrop);
      return false;
    }
    _emptyClipboard();
    final ok = _setClipboardData(_cfHdrop, hDrop) != 0;
    if (!ok) _globalFree(hDrop);
    _closeClipboard();
    return ok;
  }

  static int _getPngFormatId() {
    final cached = _pngFormatId;
    if (cached != null) return cached;
    final name = 'PNG'.toNativeUtf16();
    try {
      final id = _registerClipboardFormat(name);
      _pngFormatId = id;
      return id;
    } finally {
      malloc.free(name);
    }
  }

  static int _allocAndFill(Uint8List bytes) {
    final hGlobal = _globalAlloc(_ghnd, bytes.length);
    if (hGlobal == 0) return 0;
    final ptr = _globalLock(hGlobal);
    if (ptr == nullptr) {
      _globalFree(hGlobal);
      return 0;
    }
    ptr.cast<Uint8>().asTypedList(bytes.length).setAll(0, bytes);
    _globalUnlock(hGlobal);
    return hGlobal;
  }
}

typedef _OpenClipboardNative = Int32 Function(IntPtr hwnd);
typedef _OpenClipboardDart = int Function(int hwnd);
typedef _EmptyClipboardNative = Int32 Function();
typedef _EmptyClipboardDart = int Function();
typedef _SetClipboardDataNative = IntPtr Function(Uint32 uFormat, IntPtr hMem);
typedef _SetClipboardDataDart = int Function(int uFormat, int hMem);
typedef _CloseClipboardNative = Int32 Function();
typedef _CloseClipboardDart = int Function();
typedef _RegisterClipboardFormatNative = Uint32 Function(Pointer<Utf16> name);
typedef _RegisterClipboardFormatDart = int Function(Pointer<Utf16> name);
typedef _GlobalAllocNative = IntPtr Function(Uint32 uFlags, UintPtr dwBytes);
typedef _GlobalAllocDart = int Function(int uFlags, int dwBytes);
typedef _GlobalLockNative = Pointer<Void> Function(IntPtr hMem);
typedef _GlobalLockDart = Pointer<Void> Function(int hMem);
typedef _GlobalUnlockNative = Int32 Function(IntPtr hMem);
typedef _GlobalUnlockDart = int Function(int hMem);
typedef _GlobalFreeNative = IntPtr Function(IntPtr hMem);
typedef _GlobalFreeDart = int Function(int hMem);
typedef _SleepNative = Void Function(Uint32 ms);
typedef _SleepDart = void Function(int ms);
