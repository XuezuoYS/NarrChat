import 'package:flutter/material.dart';

/// NarrChat 主题：模仿 DeepSeek Chat 的极简设计语言，支持浅色 / 深色双主题。
///
/// - 主色：DeepSeek 品牌蓝 `#4D6BFE`；
/// - 浅色背景：浅灰 `#F7F7F8`，内容面为纯白；
/// - 深色背景：近黑 `#17181A`，内容面为深灰 `#1F2023`；
/// - 强调克制：少阴影、细边框、圆角适中，整体干净通透。
///
/// 自适应颜色（背景/文字/分割线等）集中在 [NarrChatColors]（ThemeExtension），
/// 通过 `context.narrColors` 读取，随亮暗主题自动切换；
/// 品牌色（[primary]/[accent]/[brandGradient]）在两种主题下保持一致。
///
/// 滚动条策略：**使用 Flutter 原生滚动条**（由 MaterialScrollBehavior 为每个
/// Scrollable 自动添加），仅通过 [ScrollbarThemeData] 统一外观为「细、圆角、
/// 仅滚动时显示」，避免常显拇指在流式输出/内容高度变化时移动造成“乱飞/瞬移”观感。
/// 不再使用任何自定义/显式滚动条。
class NarrChatTheme {
  NarrChatTheme._();

  /// 品牌主色（DeepSeek 蓝）。
  static const Color primary = Color(0xFF4D6BFE);

  /// 辅助强调色（品牌渐变中的紫）。
  static const Color accent = Color(0xFF6E5BEF);

  /// 品牌渐变（Logo / 关键点缀）。
  static const LinearGradient brandGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF4D6BFE), Color(0xFF6E5BEF)],
  );

  /// 弹出菜单圆角半径（右键/长按菜单与下拉菜单共用，便于统一调整）。
  static const double menuRadius = 12;

  /// 下拉菜单固定宽度（宽屏下避免菜单与输入框同宽）。
  static const double dropdownMenuWidth = 220;

  /// 默认浅色主题（跟随系统默认字体）。
  static ThemeData get light => lightWithFont(null);

  /// 生成浅色主题；[fontFamily] 非空时作为全局字体族
  /// （需先经 SystemFontsService 加载注册，否则回退系统默认字体）。
  static ThemeData lightWithFont(String? fontFamily) =>
      _build(Brightness.light, fontFamily);

  /// 默认深色主题（跟随系统默认字体）。
  static ThemeData get dark => darkWithFont(null);

  /// 生成深色主题；[fontFamily] 非空时作为全局字体族。
  static ThemeData darkWithFont(String? fontFamily) =>
      _build(Brightness.dark, fontFamily);

  /// 按 [brightness] 构建主题（浅色/深色共用同一套结构，仅配色不同）。
  static ThemeData _build(Brightness brightness, String? fontFamily) {
    final isDark = brightness == Brightness.dark;
    final colors = isDark ? NarrChatColors.dark : NarrChatColors.light;
    final scheme = _buildColorScheme(brightness, colors);

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      fontFamily: (fontFamily == null || fontFamily.isEmpty)
          ? null
          : fontFamily,
      colorScheme: scheme,
      scaffoldBackgroundColor: colors.background,
      // 供 context.narrColors 读取的自适应配色。
      extensions: [colors],
      appBarTheme: _appBarTheme(colors),
      inputDecorationTheme: _inputDecorationTheme(isDark, scheme, colors),
      // —— 按钮 ——
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: primary,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          textStyle: const TextStyle(fontWeight: FontWeight.w500),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(foregroundColor: colors.textPrimary),
      ),
      // —— 对话框 ——
      dialogTheme: DialogThemeData(
        backgroundColor: colors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        titleTextStyle: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w700,
          color: colors.textPrimary,
        ),
      ),
      // —— 右键/长按弹出菜单：明显圆角（与下拉菜单共用同一圆角常量） ——
      popupMenuTheme: PopupMenuThemeData(
        color: colors.surface,
        elevation: 3,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(NarrChatTheme.menuRadius),
        ),
      ),
      // —— 卡片 ——
      cardTheme: CardThemeData(
        color: colors.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      snackBarTheme: _snackBarTheme(isDark),
      // —— 分割线 ——
      dividerTheme: DividerThemeData(thickness: 1, color: colors.divider),
      // —— 列表 ——
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        titleTextStyle: TextStyle(fontSize: 14, color: colors.textPrimary),
        subtitleTextStyle: TextStyle(
          fontSize: 12,
          color: colors.textSecondary,
        ),
        iconColor: colors.textSecondary,
      ),
      // —— TabBar ——
      tabBarTheme: TabBarThemeData(
        labelColor: primary,
        unselectedLabelColor: colors.textSecondary,
        indicatorColor: primary,
        labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        unselectedLabelStyle: const TextStyle(fontSize: 13),
      ),
      // —— Switch ——
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? Colors.white
              : scheme.outline,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? primary
              : scheme.surfaceContainerHighest,
        ),
      ),
      scrollbarTheme: _scrollbarTheme(isDark),
    );
  }

  /// 构建 ColorScheme（品牌色 + 自适应表面色）。
  static ColorScheme _buildColorScheme(
    Brightness brightness,
    NarrChatColors colors,
  ) {
    return ColorScheme.fromSeed(
      seedColor: primary,
      brightness: brightness,
    ).copyWith(
      primary: primary,
      secondary: accent,
      surface: colors.surface,
      surfaceContainerLowest: brightness == Brightness.dark
          ? const Color(0xFF17181A)
          : Colors.white,
      surfaceContainerLow: brightness == Brightness.dark
          ? const Color(0xFF242528)
          : const Color(0xFFFAFAFB),
      surfaceContainer: brightness == Brightness.dark
          ? const Color(0xFF2A2B2F)
          : const Color(0xFFF4F4F5),
      surfaceContainerHighest: brightness == Brightness.dark
          ? const Color(0xFF303238)
          : const Color(0xFFECECEE),
      onSurface: brightness == Brightness.dark
          ? const Color(0xFFE8E8EA)
          : const Color(0xFF1F1F1F),
      onSurfaceVariant: brightness == Brightness.dark
          ? const Color(0xFFA2A6AD)
          : const Color(0xFF5F6368),
      error: const Color(0xFFE5484D),
      outline: brightness == Brightness.dark
          ? const Color(0xFF5B5E66)
          : const Color(0xFFD3D5DA),
      outlineVariant: brightness == Brightness.dark
          ? const Color(0xFF2C2E33)
          : const Color(0xFFE8E8EA),
    );
  }

  /// AppBar 主题：浅色为极简白；深色为深灰，前景随主题。
  static AppBarTheme _appBarTheme(NarrChatColors colors) {
    return AppBarTheme(
      backgroundColor: colors.surface,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      foregroundColor: colors.textPrimary,
      iconTheme: IconThemeData(color: colors.textPrimary),
      titleTextStyle: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w700,
        color: colors.textPrimary,
        letterSpacing: 0,
      ),
    );
  }

  /// 输入框主题：浅灰填充 + 细边框。
  ///
  /// 填充色直接引用既有配色（浅色 = background，深色 = surfaceContainerLow），
  /// 避免与配色中的十六进制值重复硬编码。
  static InputDecorationTheme _inputDecorationTheme(
    bool isDark,
    ColorScheme scheme,
    NarrChatColors colors,
  ) {
    return InputDecorationTheme(
      filled: true,
      fillColor: isDark ? scheme.surfaceContainerLow : colors.background,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      hintStyle: TextStyle(color: colors.placeholder),
      labelStyle: TextStyle(color: colors.textSecondary),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: colors.divider),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: colors.divider),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: primary, width: 1.4),
      ),
    );
  }

  /// SnackBar 主题。
  static SnackBarThemeData _snackBarTheme(bool isDark) {
    return SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: isDark ? const Color(0xFF3A3C42) : const Color(0xFF2A2A2A),
      contentTextStyle: const TextStyle(color: Colors.white),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    );
  }

  /// 滚动条主题：原生实现，仅滚动时显示（细圆角拇指，无轨道），
  /// 避免常显滚动条在流式输出/内容高度变化时移动造成“乱飞/瞬移”观感。
  static ScrollbarThemeData _scrollbarTheme(bool isDark) {
    return ScrollbarThemeData(
      thumbVisibility: const WidgetStatePropertyAll(false),
      thickness: const WidgetStatePropertyAll(6),
      radius: const Radius.circular(3),
      thumbColor: WidgetStatePropertyAll(
        isDark ? const Color(0xFF4A4D54) : const Color(0xFFB9BDC7),
      ),
      trackVisibility: const WidgetStatePropertyAll(false),
    );
  }
}

/// NarrChat 自适应配色（ThemeExtension）。
///
/// 通过 `context.narrColors` 访问（见 [NarrChatThemeContext]），
/// 颜色随当前主题（亮色/暗色）自动切换；品牌色不在此列。
@immutable
class NarrChatColors extends ThemeExtension<NarrChatColors> {
  /// 页面背景色。
  final Color background;

  /// 内容面板/表面色（浅色为纯白，深色为深灰）。
  final Color surface;

  /// 主文字色。
  final Color textPrimary;

  /// 次级文字色。
  final Color textSecondary;

  /// 细分割线 / 边框色。
  final Color divider;

  /// 输入框提示文字色。
  final Color placeholder;

  /// 用户消息气泡背景色。
  final Color userBubble;

  /// 侧边栏历史轮次视图背景色。
  final Color historyBackground;

  /// 侧边栏历史轮次顶栏背景色。
  final Color historyHeader;

  /// 警告色（BETA/试验版等强调用）。浅色为黄棕色，深色为明亮琥珀黄。
  final Color warning;

  /// 跨书生成进程提示栏的背景色（不透明；浅色为淡琥珀，深色为深琥珀）。
  final Color bannerBackground;

  const NarrChatColors({
    required this.background,
    required this.surface,
    required this.textPrimary,
    required this.textSecondary,
    required this.divider,
    required this.placeholder,
    required this.userBubble,
    required this.historyBackground,
    required this.historyHeader,
    required this.warning,
    required this.bannerBackground,
  });

  /// 浅色主题配色。
  static const NarrChatColors light = NarrChatColors(
    background: Color(0xFFF7F7F8),
    surface: Colors.white,
    textPrimary: Color(0xFF1F1F1F),
    textSecondary: Color(0xFF8A8F98),
    divider: Color(0xFFE8E8EA),
    placeholder: Color(0xFF9CA1A9),
    userBubble: Color(0xFFEEF1FF),
    historyBackground: Color(0xFFFFFBFB),
    historyHeader: Color(0xFFFDF0F0),
    warning: Color(0xFFB7791F),
    bannerBackground: Color(0xFFFFF0CC),
  );

  /// 深色主题配色。
  static const NarrChatColors dark = NarrChatColors(
    background: Color(0xFF17181A),
    surface: Color(0xFF1F2023),
    textPrimary: Color(0xFFE8E8EA),
    textSecondary: Color(0xFF9CA1A9),
    divider: Color(0xFF2C2E33),
    placeholder: Color(0xFF6B7076),
    userBubble: Color(0xFF242A45),
    historyBackground: Color(0xFF201B1B),
    historyHeader: Color(0xFF2A1D1D),
    warning: Color(0xFFF0B429),
    bannerBackground: Color(0xFF3E3418),
  );

  @override
  NarrChatColors copyWith({
    Color? background,
    Color? surface,
    Color? textPrimary,
    Color? textSecondary,
    Color? divider,
    Color? placeholder,
    Color? userBubble,
    Color? historyBackground,
    Color? historyHeader,
    Color? warning,
    Color? bannerBackground,
  }) {
    return NarrChatColors(
      background: background ?? this.background,
      surface: surface ?? this.surface,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      divider: divider ?? this.divider,
      placeholder: placeholder ?? this.placeholder,
      userBubble: userBubble ?? this.userBubble,
      historyBackground: historyBackground ?? this.historyBackground,
      historyHeader: historyHeader ?? this.historyHeader,
      warning: warning ?? this.warning,
      bannerBackground: bannerBackground ?? this.bannerBackground,
    );
  }

  @override
  NarrChatColors lerp(ThemeExtension<NarrChatColors>? other, double t) {
    if (other is! NarrChatColors) return this;
    return NarrChatColors(
      background: Color.lerp(background, other.background, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      divider: Color.lerp(divider, other.divider, t)!,
      placeholder: Color.lerp(placeholder, other.placeholder, t)!,
      userBubble: Color.lerp(userBubble, other.userBubble, t)!,
      historyBackground: Color.lerp(
        historyBackground,
        other.historyBackground,
        t,
      )!,
      historyHeader: Color.lerp(historyHeader, other.historyHeader, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      bannerBackground: Color.lerp(
        bannerBackground,
        other.bannerBackground,
        t,
      )!,
    );
  }
}

/// 便捷访问当前主题配色：`context.narrColors.textPrimary` 等。
extension NarrChatThemeContext on BuildContext {
  /// 当前主题的 NarrChat 自适应配色。
  NarrChatColors get narrColors =>
      Theme.of(this).extension<NarrChatColors>() ?? NarrChatColors.light;
}
