import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 桌面端（Windows / Linux / macOS）把全局 [databaseFactory] 切到 FFI 实现；
/// Android / iOS 使用 sqflite 原生插件，本函数无操作。
///
/// [sqfliteFfiInit] 幂等，且多个库入口（用户库 / 本地库 / 各书库）谁先打开库
/// 都可能触发，故各自调用本函数而非共享一次性状态。
///
/// **已配置过的工厂不再覆盖**：测试会显式装 `databaseFactoryFfiNoIsolate`
/// （sqlite 调用同步执行）。若这里无条件覆盖回带 isolate 的版本，那版要靠真实
/// 事件循环回消息，在 `testWidgets` 的 fake-async 区域里第一次查库就永远不返回。
/// 生产环境走一遍本函数之前没人配置工厂，所以行为与以前完全一致。
void ensureDesktopSqfliteFactory() {
  if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) return;
  sqfliteFfiInit();
  if (_factoryConfigured) return;
  databaseFactory = databaseFactoryFfi;
}

/// 全局 [databaseFactory] 是否已被显式配置过。
///
/// 只能靠「读一下会不会抛」判断：sqflite 没有公开的 `databaseFactoryOrNull`
/// （那个是 `@visibleForTesting`）。
bool get _factoryConfigured {
  try {
    databaseFactory;
    return true;
  } on StateError {
    return false;
  }
}
