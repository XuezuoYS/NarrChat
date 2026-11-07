import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/update_check_service.dart';
import '../theme/app_theme.dart';
import '../utils/external_link.dart';
import 'app_notice_overlay.dart';
import 'markdown_preview.dart';

/// 用户对「发现新版本」对话框的选择。
enum UpdateDialogChoice {
  /// 用系统默认浏览器打开 Release 页面（主操作）。
  openInBrowser,

  /// 复制下载链接到剪贴板（辅操作）。
  copyLink,

  /// 跳过此版本：该版本此后不再提示（持久化）。
  skipVersion,

  /// 稍后再说：仅关闭（下次启动仍会检查并提示）。
  later,
}

/// 弹出「发现新版本」对话框，返回用户选择。
///
/// - 选择「在浏览器打开」时用系统默认浏览器打开 Release 页面；打不开时
///   自动复制链接并提示（[context] 需位于应用通知作用域内）；
/// - 选择「复制链接」时对话框内已执行 [Clipboard.setData]，关闭后追加
///   悬浮通知提示；
/// - 点遮罩 / 按 Esc 关闭返回 `null`（等同「以后再说」）。
///
/// [openLink] 供测试注入替身；缺省用 [openExternalLink] 走真实浏览器。
Future<UpdateDialogChoice?> showUpdateAvailableDialog(
  BuildContext context, {
  required GitHubRelease release,
  required String currentVersion,
  ExternalLinkOpener openLink = openExternalLink,
}) async {
  final choice = await showDialog<UpdateDialogChoice>(
    context: context,
    builder: (ctx) => _UpdateAvailableDialog(
      release: release,
      currentVersion: currentVersion,
    ),
  );
  if (!context.mounted) return choice;
  switch (choice) {
    case UpdateDialogChoice.copyLink:
      context.notices.success('下载链接已复制，请在浏览器中打开');
    case UpdateDialogChoice.openInBrowser:
      final uri = Uri.tryParse(release.pageUrl);
      final opened = uri != null && await openLink(uri);
      if (opened || !context.mounted) return choice;
      // 系统没有接住链接：退化为复制下载地址，避免用户空手而归。
      await Clipboard.setData(ClipboardData(text: release.pageUrl));
      if (!context.mounted) return choice;
      context.notices.warning('无法打开浏览器，下载链接已复制');
    case _:
      break;
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
              SelectableTextArea(
                child: Text(
                  release.pageUrl,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: NarrChatTheme.primary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      // 动作区交给 [Wrap] 自然换行：宽屏一排（主操作在右），手机等窄屏
      // 自动排成两排；直接交给 [OverflowBar] 时一旦放不下会把四个按钮
      // 竖着叠成四层，观感很差。
      actions: [
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 8,
          runSpacing: 4,
          children: [
            TextButton(
              key: const ValueKey('update_dialog_later'),
              onPressed: () =>
                  Navigator.of(context).pop(UpdateDialogChoice.later),
              child: const Text('以后再说'),
            ),
            TextButton(
              key: const ValueKey('update_dialog_skip'),
              onPressed: () =>
                  Navigator.of(context).pop(UpdateDialogChoice.skipVersion),
              child: const Text('跳过此版本'),
            ),
            // 辅操作：复制下载链接。
            TextButton(
              key: const ValueKey('update_dialog_copy'),
              onPressed: () => _copyLink(context),
              child: const Text('复制链接'),
            ),
            // 主操作：直接用系统浏览器打开 Release 页面。
            FilledButton(
              key: const ValueKey('update_dialog_open_browser'),
              onPressed: () =>
                  Navigator.of(context).pop(UpdateDialogChoice.openInBrowser),
              child: const Text('在浏览器打开'),
            ),
          ],
        ),
      ],
    );
  }
}
