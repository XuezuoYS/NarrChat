import 'package:flutter/material.dart';

import '../models/app_notice.dart';

/// 通知统一视觉：**黑底 + 白 / 浅色字体**（悬浮渠道与驻场岛同源，唯一来源）。
///
/// - 驻场岛用不透明近黑（灵动岛式实体感）；
/// - 悬浮渠道用半透明黑（[kNoticeSurfaceTranslucent] 约 78% 黑，能透出下方内容）；
/// - 强调色（图标 / 进度）为深色底专用常量，**不随应用亮 / 暗主题变化**，
///   避免在浅色主题下把深色文字色带上黑底而失去对比。
const Color kNoticeSurface = Color(0xFF16161A);

/// 悬浮通知底色：约 78% 黑，真正半透明（透出下方页面内容）。
const Color kNoticeSurfaceTranslucent = Color(0xC70B0B0E);

/// 主文案（白）。
const Color kNoticeTextPrimary = Color(0xFFF7F7F9);

/// 次要文案 / 次要图标（浅灰白）。
const Color kNoticeTextSecondary = Color(0xFFA9A9B2);

/// 分隔线 / 弱背景（白色低透明度）。
const Color kNoticeDivider = Color(0x1FFFFFFF);

/// 描边：让半透明卡片在任意背景上都有边界感。
const Color kNoticeBorder = Color(0x1FFFFFFF);

/// 通知卡片圆角。
const double kNoticeRadius = 14;

/// 类型 → (图标, 强调色)：深色底配色（唯一来源）。
(IconData, Color) noticeIconOf(NoticeKind kind) => switch (kind) {
  NoticeKind.info => (Icons.info_outline, kNoticeTextSecondary),
  NoticeKind.success => (Icons.cloud_done_outlined, Color(0xFF34D399)),
  NoticeKind.warning => (Icons.warning_amber_outlined, Color(0xFFFBBF24)),
  NoticeKind.error => (Icons.error_outline, Color(0xFFF87171)),
};

/// 通知卡片的主题覆盖：黑底白字下的选取高亮 / 光标 / 关闭按钮着色。
///
/// 通知表面恒为深色，不能沿用应用亮色主题的选区与前景色。
ThemeData noticeThemeOf(BuildContext context) {
  return Theme.of(context).copyWith(
    textSelectionTheme: const TextSelectionThemeData(
      selectionColor: Color(0x4DFFFFFF),
      selectionHandleColor: kNoticeTextPrimary,
      cursorColor: kNoticeTextPrimary,
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: kNoticeTextSecondary),
    ),
  );
}
