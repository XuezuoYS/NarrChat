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

/// 全局字体大小档位（字体缩放）。
///
/// **偏移量语义**：[offset] `0` 对应 0%（默认档），更小的档位用负数表示；
/// 该偏移量同时作为本地 JSON 配置文件的存储值
/// （见 [UiSettingsProvider.keyFontScaleIndex]）。
///
/// 6 档：-30% / -15% / 0%（默认）/ +15% / +30% / +45%。
/// 界面上的滑杆位置是 `offset - minOffset`（0..5），由使用方计算，避免散落魔法数。
enum FontScaleLevel {
  /// -30%（最小档）。
  minus30(-2, -30),

  /// -15%。
  minus15(-1, -15),

  /// 0%（默认档）。
  zero(0, 0),

  /// +15%。
  plus15(1, 15),

  /// +30%。
  plus30(2, 30),

  /// +45%（最大档）。
  plus45(3, 45);

  const FontScaleLevel(this.offset, this.percent);

  /// 偏移量：0 为默认档（0%），负数为更小档位。
  ///
  /// ⚠ 该值是**存储值**（本地配置 `fontScaleIndex`），改动档位时需保持其语义稳定；
  /// 不能命名为 `index`（与枚举自带的位置索引冲突）。
  final int offset;

  /// 相对默认字号的百分比（如 `-30` / `0` / `45`）。
  final int percent;

  /// 文字缩放倍率（1.0 为不缩放）。
  double get scale => 1 + percent / 100;

  /// 展示标签：负档为 `-30%`，零档为 `0%`，正档为 `+15%`。
  String get label =>
      percent == 0 ? '0%' : (percent > 0 ? '+$percent%' : '$percent%');

  /// 默认档（0%）。
  static const FontScaleLevel defaultLevel = FontScaleLevel.zero;

  /// 最小偏移量（与最负档 [minus30] 一致）。
  ///
  /// ⚠ 增删档位时需同步本常量与 [maxOffset]。
  static const int minOffset = -2;

  /// 最大偏移量（与最正档 [plus45] 一致）。
  static const int maxOffset = 3;

  /// 全部档位的偏移量（按档位顺序，最负档在前）。
  static Iterable<int> get offsets => values.map((level) => level.offset);

  /// 按偏移量解析档位；非法偏移量（null / 越界）回退 [defaultLevel]。
  static FontScaleLevel fromOffset(int? offset) {
    if (offset == null || offset < minOffset || offset > maxOffset) {
      return defaultLevel;
    }
    return values[offset - minOffset];
  }
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
/// - 全局字体大小档位（[fontScaleIndex]：6 档，0 为默认 0%，可为负；全局文字缩放）；
/// - 宽屏 Chat 页右侧栏宽度（[chatSidebarWidth]，默认 [kChatSidebarDefaultWidth]）。
class UiSettingsProvider extends ChangeNotifier {
  /// 本地 JSON 配置文件中的键名。
  static const String keyFontFamily = 'fontFamily';

  /// 本地 JSON 配置文件中的字体缩放档位键名。
  ///
  /// 值即 [FontScaleLevel.offset] 偏移量（0 = 0% = 默认，可为负）。
  static const String keyFontScaleIndex = 'fontScaleIndex';

  /// 本地 JSON 配置文件中的主题模式键名。
  static const String keyThemeMode = 'themeMode';

  /// 本地 JSON 配置文件中的宽屏侧栏宽度键名。
  static const String keyChatSidebarWidth = 'chatSidebarWidth';

  String _fontFamily = '';
  int _fontScaleIndex = FontScaleLevel.defaultLevel.offset;
  AppThemeMode _themeMode = AppThemeMode.system;
  double _chatSidebarWidth = kChatSidebarDefaultWidth;
  bool _isLoading = false;
  String? _error;

  /// 全局字体族名；空字符串表示系统默认字体。
  String get fontFamily => _fontFamily;

  /// 是否已配置自定义全局字体。
  bool get hasCustomFont => _fontFamily.isNotEmpty;

  /// 全局字体缩放档位偏移量（0 = 0% = 默认；可为负，范围见
  /// [FontScaleLevel.minOffset] / [FontScaleLevel.maxOffset]）。
  int get fontScaleIndex => _fontScaleIndex;

  /// 全局字体缩放档位。
  FontScaleLevel get fontScaleLevel =>
      FontScaleLevel.fromOffset(_fontScaleIndex);

  /// 全局字体缩放档位的展示标签（如 `0%` / `+15%` / `-30%`）。
  String get fontScaleLabel => fontScaleLevel.label;

  /// 全局文字缩放倍率（1.0 为不缩放）。
  double get fontScaleMultiplier => fontScaleLevel.scale;

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
      // 用户可手工编辑明文配置：仅接受合法整数偏移量，其余（null / 小数 / 字符串 /
      // 越界）一律回退默认档 0%。
      final rawScale = cfg[keyFontScaleIndex];
      _fontScaleIndex = FontScaleLevel.fromOffset(
        rawScale is int ? rawScale : null,
      ).offset;
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

  /// 设置全局字体缩放档位并写入本地配置。
  ///
  /// [offset] 为档位偏移量（0 = 0% = 默认，可为负）；非法偏移量归一化为默认档。
  Future<void> setFontScaleIndex(int offset) async {
    final normalized = FontScaleLevel.fromOffset(offset).offset;
    if (normalized == _fontScaleIndex) return;
    _fontScaleIndex = normalized;
    notifyListeners();
    try {
      await LocalConfigService.update({keyFontScaleIndex: normalized});
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
