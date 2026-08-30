import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/update_check_service.dart';
import '../theme/app_theme.dart';
import 'markdown_preview.dart';

/// 用户对「发现新版本」对话框的选择。
enum UpdateDialogChoice {
  /// 复制下载链接到剪贴板（主操作）。
  copyLink,

  /// 跳过此版本：该版本此后不再提示（持久化）。
  skipVersion,

  /// 稍后再说：仅关闭（下次启动仍会检查并提示）。
  later,
}

/// 弹出「发现新版本」对话框，返回用户选择。
///
/// - 选择「复制链接」时对话框内已执行 [Clipboard.setData]，关闭后追加
///   SnackBar 提示（[context] 需位于 MaterialApp 下）；
/// - 点遮罩 / 按 Esc 关闭返回 `null`（等同「以后再说」）。
Future<UpdateDialogChoice?> showUpdateAvailableDialog(
  BuildContext context, {
  required GitHubRelease release,
  required String currentVersion,
}) async {
  final choice = await showDialog<UpdateDialogChoice>(
    context: context,
    builder: (ctx) => _UpdateAvailableDialog(
      release: release,
      currentVersion: currentVersion,
    ),
  );
  if (choice == UpdateDialogChoice.copyLink && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('下载链接已复制，请在浏览器中打开')),
    );
  }
  return choice;
}

class _UpdateAvailableDialog extends StatelessWidget {
  const _UpdateAvailableDialog({
    required this.release,
    required this.currentVersion,
  });

  final GitHubRelease release;
  final String currentVersion;

  void _copyLink(BuildContext context) {
    Clipboard.setData(ClipboardData(text: release.pageUrl));
    Navigator.of(context).pop(UpdateDialogChoice.copyLink);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    return AlertDialog(
      title: const Text('发现新版本'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'NarrChat ${release.tagVersion} 已发布（当前版本 $currentVersion）',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: colors.textPrimary,
                ),
              ),
              if (release.notes.trim().isNotEmpty) ...[
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 260),
                  child: SingleChildScrollView(
                    child: MarkdownPreview(
                      data: release.notes,
                      base: TextStyle(
                        fontSize: 12.5,
                        height: 1.55,
                        color: colors.textSecondary,
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Text(
                '下载地址（复制到浏览器打开）：',
                style: TextStyle(fontSize: 12.5, color: colors.textSecondary),
              ),
              const SizedBox(height: 2),
              SelectableText(
                release.pageUrl,
                style: TextStyle(
                  fontSize: 12.5,
                  color: NarrChatTheme.primary,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('update_dialog_later'),
          onPressed: () => Navigator.of(context).pop(UpdateDialogChoice.later),
          child: const Text('以后再说'),
        ),
        TextButton(
          key: const ValueKey('update_dialog_skip'),
          onPressed: () =>
              Navigator.of(context).pop(UpdateDialogChoice.skipVersion),
          child: const Text('跳过此版本'),
        ),
        FilledButton(
          key: const ValueKey('update_dialog_copy'),
          onPressed: () => _copyLink(context),
          child: const Text('复制链接'),
        ),
      ],
    );
  }
}
