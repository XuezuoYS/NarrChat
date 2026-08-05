import 'package:flutter/material.dart';

/// NarrChat 定制主题（放弃原生默认配色，使用品牌化的深紫 + 柔和背景）。
class NarrChatTheme {
  NarrChatTheme._();

  /// 品牌主色（深紫）。
  static const Color primary = Color(0xFF6C4DF6);

  /// 强调色（青绿，用于推荐行动等）。
  static const Color accent = Color(0xFF00B8A9);

  /// 品牌渐变（AppBar / 关键区域）。
  static const LinearGradient brandGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF6C4DF6), Color(0xFF9A5CF2)],
  );

  /// 柔和页面背景。
  static const Color background = Color(0xFFF4F1FB);

  static ThemeData get light {
    final scheme = ColorScheme.fromSeed(
      seedColor: primary,
      brightness: Brightness.light,
    ).copyWith(
      primary: primary,
      secondary: accent,
      surface: Colors.white,
      surfaceContainerLowest: const Color(0xFFFDFBFF),
      surfaceContainerLow: const Color(0xFFF6F3FC),
      surfaceContainer: const Color(0xFFEFEAF8),
      surfaceContainerHighest: const Color(0xFFE5DDF3),
      error: const Color(0xFFE5484D),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      // —— AppBar ——（背景由页面渐变容器提供，这里设为透明）
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        foregroundColor: Colors.white,
        iconTheme: const IconThemeData(color: Colors.white),
        titleTextStyle: const TextStyle(
          fontSize: 21,
          fontWeight: FontWeight.w800,
          color: Colors.white,
          letterSpacing: 1.5,
        ),
      ),
      // —— 输入框 ——
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        hintStyle: TextStyle(color: scheme.outlineVariant),
        labelStyle: TextStyle(color: scheme.outline),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: primary, width: 1.6),
        ),
      ),
      // —— 按钮 ——
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          textStyle: const TextStyle(fontWeight: FontWeight.w500),
        ),
      ),
      // —— 对话框 ——
      dialogTheme: DialogThemeData(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        titleTextStyle: const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: Color(0xFF1F1B2E),
        ),
      ),
      // —— 卡片 ——
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      // —— SnackBar ——
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF2A2440),
        contentTextStyle: const TextStyle(color: Colors.white),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      // —— 分割线 ——
      dividerTheme: DividerThemeData(
        thickness: 1,
        color: scheme.outlineVariant.withValues(alpha: 0.6),
      ),
      // —— 列表 ——
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        titleTextStyle: const TextStyle(fontSize: 14, color: Color(0xFF1F1B2E)),
        subtitleTextStyle: TextStyle(fontSize: 12, color: scheme.outline),
      ),
      // —— TabBar ——
      tabBarTheme: TabBarThemeData(
        labelColor: primary,
        unselectedLabelColor: scheme.outline,
        indicatorColor: primary,
        labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        unselectedLabelStyle: const TextStyle(fontSize: 13),
      ),
      // —— Switch ——
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? Colors.white : scheme.outline,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? primary : scheme.surfaceContainerHighest,
        ),
      ),
    );
  }
}
