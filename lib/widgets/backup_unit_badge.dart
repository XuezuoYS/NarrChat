import 'package:flutter/material.dart';

import '../services/cloud_backup/backup_unit.dart';
import '../theme/app_theme.dart';

/// 「库」的图标：Library / Mod / 书籍（面板条目与二级页共用）。
IconData backupUnitIconOf(BackupUnitKind kind) => switch (kind) {
      BackupUnitKind.library => Icons.library_books_outlined,
      BackupUnitKind.mods => Icons.extension_outlined,
      BackupUnitKind.book => Icons.menu_book_outlined,
    };

/// 库图标徽章：默认品牌色淡底，[filled] 时改用品牌渐变 + 白图标（二级页头部用）。
class BackupUnitBadge extends StatelessWidget {
  const BackupUnitBadge({
    super.key,
    required this.kind,
    this.size = 32,
    this.filled = false,
  });

  final BackupUnitKind kind;
  final double size;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final icon = backupUnitIconOf(kind);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: filled ? null : NarrChatTheme.primary.withValues(alpha: 0.12),
        gradient: filled ? NarrChatTheme.brandGradient : null,
        borderRadius: BorderRadius.circular(size * 0.28),
      ),
      child: Icon(
        icon,
        size: size * 0.56,
        color: filled ? Colors.white : NarrChatTheme.primary,
      ),
    );
  }
}
