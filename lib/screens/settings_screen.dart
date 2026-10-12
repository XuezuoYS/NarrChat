import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'debug_screen.dart';
import 'licenses_screen.dart';
import 'update_log_screen.dart';
import '../providers/ai_settings_provider.dart';
import '../providers/cloud_sync_provider.dart';
import '../theme/app_theme.dart';
import '../utils/release_info.dart';
import '../utils/triple_tap_detector.dart';
import '../widgets/ai_settings_form.dart';
import '../widgets/app_notice_overlay.dart';
import '../widgets/brand_logo.dart';
import '../widgets/cloud_sync_panel.dart';
import '../widgets/general_settings_form.dart';
import '../widgets/mod_management_panel.dart';
import '../widgets/settings_form_state.dart';
import '../widgets/settings_shell.dart';
import '../widgets/storage_management_panel.dart';

/// 全窗口设置界面。
///
/// 6 个子模块（导航顺序即下列顺序，首页为最常用的「通用设置」）：
/// - 通用设置：UI 设置 / 其它设置 / 实验性设置三个子分区（即时生效）；
/// - API 设置：平台/连接 + 各模型参数（始终可调）；
/// - Mod 管理：查看预置 Mod，创建/编辑/导出/导入自定义 Mod；
/// - 云同步：WebDAV 云端备份 / 恢复；
/// - 存储管理：本地存储位置与占用；
/// - 关于：应用信息（宽屏下水平居中排版）。
///
/// 表单状态（API 设置 + 云同步）由本页持有，切换面板不丢失；
/// 右上角「保存」为全局保存：一次性校验并落库全部改动，不退出设置页。
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.initialIndex = pageIndexGeneral});

  /// 面板序号：通用设置（设置页首页，日常最常调整项）。
  static const int pageIndexGeneral = 0;

  /// 面板序号：API 设置。
  static const int pageIndexApi = 1;

  /// 面板序号：Mod 管理。
  static const int pageIndexMod = 2;

  /// 面板序号：云同步。
  static const int pageIndexCloudSync = 3;

  /// 面板序号：存储管理。
  static const int pageIndexStorage = 4;

  /// 面板序号：关于。
  static const int pageIndexAbout = 5;

  /// 打开时初始选中的面板序号（用 [pageIndexGeneral] 等常量指定）。
  final int initialIndex;

  static Future<void> open(
    BuildContext context, {
    int initialIndex = pageIndexGeneral,
  }) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(initialIndex: initialIndex),
      ),
    );
  }

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final SettingsFormState _form;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _form = SettingsFormState(
      ai: context.read<AiSettingsProvider>(),
      sync: context.read<CloudSyncProvider>(),
    );
  }

  @override
  void dispose() {
    _form.dispose();
    super.dispose();
  }

  /// 全局保存：统一校验并落库 API 设置 + 云同步，成功后不退出页面。
  Future<void> _saveAll() async {
    final notices = context.notices;
    setState(() => _isSaving = true);
    final result = await _form.saveAll();
    if (!mounted) return;
    setState(() => _isSaving = false);
    final notes = result.notes;
    if (result.ok) {
      notices.success(notes.isEmpty ? '已保存' : '已保存；${notes.join('；')}');
    } else {
      notices.error('保存失败：${result.errors.join('；')}', copyable: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsShell(
      title: '设置',
      icon: Icons.settings,
      initialIndex: widget.initialIndex.clamp(0, SettingsScreen.pageIndexAbout),
      navItems: const [
        SettingsNavItem(icon: Icons.tune_outlined, label: '通用设置'),
        SettingsNavItem(icon: Icons.smart_toy_outlined, label: 'API 设置'),
        SettingsNavItem(icon: Icons.extension_outlined, label: 'Mod 管理'),
        SettingsNavItem(icon: Icons.cloud_outlined, label: '云同步'),
        SettingsNavItem(icon: Icons.storage_outlined, label: '存储管理'),
        // 「关于」是信息型短面板：豁免靠左骨架，在内容区内居中。
        SettingsNavItem(
          icon: Icons.info_outline,
          label: '关于',
          centered: true,
        ),
      ],
      actions: [
        // 全局保存：对 API 设置 + 云同步的所有改动统一保存（不退出设置页）。
        FilledButton.icon(
          onPressed: _isSaving ? null : _saveAll,
          icon: const Icon(Icons.save_outlined, size: 18),
          label: Text(_isSaving ? '保存中…' : '保存'),
        ),
        const SizedBox(width: 4),
      ],
      contentBuilder: (context, index) {
        // 分支与 SettingsScreen.pageIndexXxx 常量一一对应，调整导航顺序时只需同步这里。
        switch (index) {
          case SettingsScreen.pageIndexApi:
            return AiSettingsForm(form: _form);
          case SettingsScreen.pageIndexMod:
            return const ModManagementPanel();
          case SettingsScreen.pageIndexCloudSync:
            return CloudSyncPanel(form: _form);
          case SettingsScreen.pageIndexStorage:
            return const StorageManagementPanel();
          case SettingsScreen.pageIndexAbout:
            return const _AboutPanel();
          default:
            return const GeneralSettingsForm();
        }
      },
    );
  }
}

/// 「关于」面板：应用基本信息。
class _AboutPanel extends StatefulWidget {
  const _AboutPanel();

  @override
  State<_AboutPanel> createState() => _AboutPanelState();
}

class _AboutPanelState extends State<_AboutPanel> {
  late Future<String> _versionFuture;
  late final TripleTapDetector _versionTapDetector;

  @override
  void initState() {
    super.initState();
    _versionFuture = ReleaseInfo.versionLabel();
    _versionTapDetector = TripleTapDetector(onTripleTap: _openDebug);
  }

  @override
  void dispose() {
    _versionTapDetector.dispose();
    super.dispose();
  }

  /// 连点版本号三次进入「调试」页。
  void _openDebug() {
    if (!context.mounted) return;
    DebugScreen.open(context);
  }

  void _onVersionTap() => _versionTapDetector.tap();

  @override
  Widget build(BuildContext context) {
    // 居中排版（水平 / 垂直）由 SettingsShell 依据 navItems 上的 `centered`
    // 标记负责（限宽 400），本面板只输出纵向卡片内容。
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 顶部块：关于本软件信息。
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 36),
          decoration: BoxDecoration(
            color: context.narrColors.background,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: context.narrColors.divider),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const BrandLogo(size: 56),
              const SizedBox(height: 14),
              Text(
                'NarrChat',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: context.narrColors.textPrimary,
                ),
              ),
              const SizedBox(height: 16),
              FutureBuilder<String>(
                future: _versionFuture,
                builder: (context, snapshot) {
                  return _AboutRow(
                    label: '版本',
                    value: snapshot.data ?? '…',
                    onTap: _onVersionTap,
                    valueKey: const ValueKey('about_version_tap'),
                  );
                },
              ),
              if (ReleaseInfo.flutterVersion.isNotEmpty) ...[
                const SizedBox(height: 12),
                _AboutRow(
                  label: 'Flutter',
                  value: ReleaseInfo.flutterVersion,
                ),
              ],
              const SizedBox(height: 14),
              Text(
                '本软件仅供创作参考，生成内容请仔细甄别。',
                style: TextStyle(
                  fontSize: 11,
                  color: context.narrColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // 底部块：开放源代码许可入口（与上方信息块同级别）。
        _AboutEntry(
          icon: Icons.receipt_long_outlined,
          label: '开放源代码许可',
          onTap: () => LicensesScreen.open(context),
        ),
        const SizedBox(height: 12),
        _AboutEntry(
          icon: Icons.history,
          label: '更新日志',
          onTap: () => UpdateLogScreen.open(context),
        ),
      ],
    );
  }
}

class _AboutRow extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback? onTap;
  final Key? valueKey;

  const _AboutRow({
    required this.label,
    required this.value,
    this.onTap,
    this.valueKey,
  });

  @override
  Widget build(BuildContext context) {
    final valueText = Text(
      value,
      style: TextStyle(
        fontSize: 13,
        color: context.narrColors.textPrimary,
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              color: context.narrColors.textSecondary,
            ),
          ),
          const SizedBox(width: 12),
          if (onTap != null)
            GestureDetector(
              key: valueKey,
              behavior: HitTestBehavior.opaque,
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: valueText,
              ),
            )
          else
            valueText,
        ],
      ),
    );
  }
}

/// 「关于」面板入口块：图标 + 文案 + 尾箭头，可点击跳转
/// （与上方「关于本软件」信息块同级别的独立卡片）。
class _AboutEntry extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _AboutEntry({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.divider),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Icon(icon, size: 18, color: colors.textSecondary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(fontSize: 14, color: colors.textPrimary),
                  ),
                ),
                Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: colors.textSecondary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
