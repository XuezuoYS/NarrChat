import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 桌面端（Windows / Linux / macOS）把全局 [databaseFactory] 切到 FFI 实现；
/// Android / iOS 使用 sqflite 原生插件，本函数无操作。
///
/// [sqfliteFfiInit] 幂等，且多个库入口（用户库 [DatabaseHelper]、本地库
/// [LocalSyncDb]）谁先打开库都可能触发，故各自调用本函数而非共享一次性状态。
void ensureDesktopSqfliteFactory() {
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
}
