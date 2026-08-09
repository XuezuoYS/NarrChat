import 'package:flutter/foundation.dart';

import '../services/local_config_service.dart';
import '../services/system_fonts_service.dart';

/// UI 设置状态管理（本地数据，明文 JSON 配置，不参与云同步）。
///
/// 当前支持：
/// - 全局字体（[fontFamily]，空字符串表示跟随系统默认）。
class UiSettingsProvider extends ChangeNotifier {
  /// 本地 JSON 配置文件中的键名。
  static const String keyFontFamily = 'fontFamily';

  String _fontFamily = '';
  bool _isLoading = false;
  String? _error;

  /// 全局字体族名；空字符串表示系统默认字体。
  String get fontFamily => _fontFamily;

  /// 是否已配置自定义全局字体。
  bool get hasCustomFont => _fontFamily.isNotEmpty;

  bool get isLoading => _isLoading;
  String? get error => _error;

  /// 从本地 JSON 配置文件中加载 UI 设置。
  Future<void> load() async {
    _isLoading = true;
    try {
      final cfg = await LocalConfigService.read();
      _fontFamily = (cfg[keyFontFamily] as String?) ?? '';
    } catch (e) {
      _error = e.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
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
