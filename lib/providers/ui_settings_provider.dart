import 'package:flutter/foundation.dart';

import '../services/local_config_service.dart';
import '../services/system_fonts_service.dart';

/// 应用主题模式。
enum AppThemeMode {
  /// 跟随系统亮暗设置（默认）。
  system,

  /// 始终使用亮色主题。
  light,

  /// 始终使用暗色主题。
  dark;

  /// 配置文件中存储的字符串值。
  String get storageValue => switch (this) {
        AppThemeMode.system => 'system',
        AppThemeMode.light => 'light',
        AppThemeMode.dark => 'dark',
      };

  /// 从配置文件字符串解析；未知值回退为 [AppThemeMode.system]。
  static AppThemeMode fromStorageValue(String? value) =>
      switch (value) {
        'light' => AppThemeMode.light,
        'dark' => AppThemeMode.dark,
        _ => AppThemeMode.system,
      };
}

/// 宽屏 Chat 页右侧栏默认宽度（px），同时是可调宽度的下限。
///
/// 窄屏（宽屏断点以下）抽屉不使用该值，一律按屏宽 0.88 的占比显示。
const double kChatSidebarDefaultWidth = 380;

/// UI 设置状态管理（本地数据，明文 JSON 配置，不参与云同步）。
///
/// 当前支持：
/// - 主题模式（[themeMode]：跟随系统 / 亮色 / 暗色，默认跟随系统）；
/// - 全局字体（[fontFamily]，空字符串表示跟随系统默认）；
/// - 宽屏 Chat 页右侧栏宽度（[chatSidebarWidth]，默认 [kChatSidebarDefaultWidth]）。
class UiSettingsProvider extends ChangeNotifier {
  /// 本地 JSON 配置文件中的键名。
  static const String keyFontFamily = 'fontFamily';

  /// 本地 JSON 配置文件中的主题模式键名。
  static const String keyThemeMode = 'themeMode';

  /// 本地 JSON 配置文件中的宽屏侧栏宽度键名。
  static const String keyChatSidebarWidth = 'chatSidebarWidth';

  String _fontFamily = '';
  AppThemeMode _themeMode = AppThemeMode.system;
  double _chatSidebarWidth = kChatSidebarDefaultWidth;
  bool _isLoading = false;
  String? _error;

  /// 全局字体族名；空字符串表示系统默认字体。
  String get fontFamily => _fontFamily;

  /// 是否已配置自定义全局字体。
  bool get hasCustomFont => _fontFamily.isNotEmpty;

  /// 主题模式（跟随系统 / 亮色 / 暗色）。
  AppThemeMode get themeMode => _themeMode;

  /// 宽屏 Chat 页右侧栏宽度（px）；不小于 [kChatSidebarDefaultWidth]。
  ///
  /// 窄屏抽屉不读取该值（按屏宽 0.88 占比显示）。
  double get chatSidebarWidth => _chatSidebarWidth;

  /// 是否已自定义右侧栏宽度（大于默认值）。
  bool get hasCustomSidebarWidth =>
      _chatSidebarWidth > kChatSidebarDefaultWidth;

  bool get isLoading => _isLoading;
  String? get error => _error;

  /// 从本地 JSON 配置文件中加载 UI 设置。
  Future<void> load() async {
    _isLoading = true;
    try {
      final cfg = await LocalConfigService.read();
      _fontFamily = (cfg[keyFontFamily] as String?) ?? '';
      _themeMode = AppThemeMode.fromStorageValue(
        cfg[keyThemeMode] as String?,
      );
      // 用户可手工编辑明文配置：非有限（NaN / Infinity）或低于下限的值一律回退默认。
      final raw = cfg[keyChatSidebarWidth];
      final stored = raw is num ? raw.toDouble() : null;
      _chatSidebarWidth = stored == null ||
              !stored.isFinite ||
              stored < kChatSidebarDefaultWidth
          ? kChatSidebarDefaultWidth
          : stored;
    } catch (e) {
      _error = e.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 设置主题模式并写入本地配置。
  Future<void> setThemeMode(AppThemeMode mode) async {
    if (mode == _themeMode) return;
    _themeMode = mode;
    notifyListeners();
    try {
      await LocalConfigService.update({keyThemeMode: mode.storageValue});
    } catch (e) {
      _error = e.toString();
    }
  }

  /// 设置宽屏 Chat 页右侧栏宽度并写入本地配置。
  ///
  /// 非有限（NaN / Infinity）或低于默认值的输入归一化为默认值（默认即最小宽度）。
  Future<void> setChatSidebarWidth(double width) async {
    final normalized =
        !width.isFinite || width < kChatSidebarDefaultWidth
            ? kChatSidebarDefaultWidth
            : width;
    if (normalized == _chatSidebarWidth) return;
    _chatSidebarWidth = normalized;
    notifyListeners();
    try {
      await LocalConfigService.update({keyChatSidebarWidth: normalized});
    } catch (e) {
      _error = e.toString();
    }
  }

  /// 设置全局字体并写入本地配置。
  ///
  /// 字体尚未加载时会先尝试加载；加载失败时保持原字体并返回 false。
  Future<bool> setFontFamily(String familyName) async {
    final normalized = familyName.trim();
    if (normalized == _fontFamily) return true;
    if (normalized.isNotEmpty) {
      final ok = await SystemFontsService.instance.loadFont(normalized);
      if (!ok) return false;
    }
    _fontFamily = normalized;
    notifyListeners();
    try {
      await LocalConfigService.update({keyFontFamily: normalized});
    } catch (e) {
      _error = e.toString();
    }
    return true;
  }
}
