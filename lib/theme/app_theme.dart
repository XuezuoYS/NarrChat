import 'package:flutter/material.dart';

/// NarrChat 主题：模仿 DeepSeek Chat 的极简浅色设计语言。
///
/// - 主色：DeepSeek 品牌蓝 `#4D6BFE`；
/// - 背景：浅灰 `#F7F7F8`，内容面为纯白；
/// - 强调克制：少阴影、细边框、圆角适中，整体干净通透。
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

  /// 页面浅灰背景。
  static const Color background = Color(0xFFF7F7F8);

  /// 主文字色。
  static const Color textPrimary = Color(0xFF1F1F1F);

  /// 次级文字色。
  static const Color textSecondary = Color(0xFF8A8F98);

  /// 细分割线色。
  static const Color divider = Color(0xFFE8E8EA);

  static ThemeData get light {
    final scheme = ColorScheme.fromSeed(
      seedColor: primary,
      brightness: Brightness.light,
    ).copyWith(
      primary: primary,
      secondary: accent,
      surface: Colors.white,
      surfaceContainerLowest: Colors.white,
      surfaceContainerLow: const Color(0xFFFAFAFB),
      surfaceContainer: const Color(0xFFF4F4F5),
      surfaceContainerHighest: const Color(0xFFECECEE),
      error: const Color(0xFFE5484D),
      outline: const Color(0xFFD3D5DA),
      outlineVariant: const Color(0xFFE8E8EA),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      // —— AppBar：极简白，深色前景 ——
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        foregroundColor: textPrimary,
        iconTheme: const IconThemeData(color: textPrimary),
        titleTextStyle: const TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w700,
          color: textPrimary,
          letterSpacing: 0,
        ),
      ),
      // —— 输入框：浅灰填充 + 细边框 ——
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFFF7F7F8),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        hintStyle: const TextStyle(color: Color(0xFF9CA1A9)),
        labelStyle: const TextStyle(color: Color(0xFF8A8F98)),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFE8E8EA)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFE8E8EA)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: primary, width: 1.4),
        ),
      ),
      // —— 按钮 ——
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
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
        style: IconButton.styleFrom(
          foregroundColor: textPrimary,
        ),
      ),
      // —— 对话框 ——
      dialogTheme: DialogThemeData(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        titleTextStyle: const TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w700,
          color: textPrimary,
        ),
      ),
      // —— 右键/长按弹出菜单：明显圆角 ——
      popupMenuTheme: PopupMenuThemeData(
        color: Colors.white,
        elevation: 3,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      // —— 卡片 ——
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      // —— SnackBar ——
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF2A2A2A),
        contentTextStyle: const TextStyle(color: Colors.white),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      // —— 分割线 ——
      dividerTheme: DividerThemeData(
        thickness: 1,
        color: divider,
      ),
      // —— 列表 ——
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        titleTextStyle: const TextStyle(fontSize: 14, color: textPrimary),
        subtitleTextStyle: const TextStyle(fontSize: 12, color: textSecondary),
        iconColor: textSecondary,
      ),
      // —— TabBar ——
      tabBarTheme: TabBarThemeData(
        labelColor: primary,
        unselectedLabelColor: textSecondary,
        indicatorColor: primary,
        labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        unselectedLabelStyle: const TextStyle(fontSize: 13),
      ),
      // —— Switch ——
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? Colors.white : scheme.outline,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? primary
              : scheme.surfaceContainerHighest,
        ),
      ),
      // —— 滚动条：原生实现，仅滚动时显示（细圆角拇指，无轨道），
      //    避免常显滚动条在流式输出/内容高度变化时移动造成“乱飞/瞬移”观感 ——
      scrollbarTheme: ScrollbarThemeData(
        thumbVisibility: const WidgetStatePropertyAll(false),
        thickness: const WidgetStatePropertyAll(6),
        radius: const Radius.circular(3),
        thumbColor: const WidgetStatePropertyAll(Color(0xFFB9BDC7)),
        trackVisibility: const WidgetStatePropertyAll(false),
      ),
    );
  }
}

