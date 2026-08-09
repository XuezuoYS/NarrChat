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

/// UI 设置状态管理（本地数据，明文 JSON 配置，不参与云同步）。
///
/// 当前支持：
/// - 主题模式（[themeMode]：跟随系统 / 亮色 / 暗色，默认跟随系统）；
/// - 全局字体（[fontFamily]，空字符串表示跟随系统默认）。
class UiSettingsProvider extends ChangeNotifier {
  /// 本地 JSON 配置文件中的键名。
  static const String keyFontFamily = 'fontFamily';

  /// 本地 JSON 配置文件中的主题模式键名。
  static const String keyThemeMode = 'themeMode';

  String _fontFamily = '';
  AppThemeMode _themeMode = AppThemeMode.system;
  bool _isLoading = false;
  String? _error;

  /// 全局字体族名；空字符串表示系统默认字体。
  String get fontFamily => _fontFamily;

  /// 是否已配置自定义全局字体。
  bool get hasCustomFont => _fontFamily.isNotEmpty;

  /// 主题模式（跟随系统 / 亮色 / 暗色）。
  AppThemeMode get themeMode => _themeMode;

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
