import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'debug_screen.dart';
import 'licenses_screen.dart';
import 'update_log_screen.dart';
import '../providers/ai_settings_provider.dart';
import '../providers/cloud_sync_provider.dart';
import '../services/local_config_service.dart';
import '../services/update_check_flow.dart';
import '../theme/app_theme.dart';
import '../utils/release_info.dart';
import '../utils/triple_tap_detector.dart';
import '../widgets/ai_settings_form.dart';
import '../widgets/brand_logo.dart';
import '../widgets/cloud_sync_panel.dart';
import '../widgets/mod_management_panel.dart';
import '../widgets/settings_form_state.dart';
import '../widgets/settings_shell.dart';
import '../widgets/storage_management_panel.dart';
import '../widgets/ui_settings_form.dart';

/// 全窗口设置界面。
///
/// 5 个子模块：
/// - API 设置：平台/连接 + 各模型参数（始终可调）；
/// - UI 设置：全局字体等界面偏好（即时生效）；
/// - Mod 管理：查看预置 Mod，创建/编辑/导出/导入自定义 Mod；
/// - 云同步：WebDAV 云端备份 / 恢复；
/// - 关于：应用信息。
///
/// 表单状态（API 设置 + 云同步）由本页持有，切换面板不丢失；
/// 右上角「保存」为全局保存：一次性校验并落库全部改动，不退出设置页。
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.initialIndex = 0});

  /// 打开时初始选中的面板序号（与 [SettingsShell.navItems] 对应）。
  final int initialIndex;

  static Future<void> open(BuildContext context, {int initialIndex = 0}) {
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
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _isSaving = true);
    final result = await _form.saveAll();
    if (!mounted) return;
    setState(() => _isSaving = false);
    final notes = result.notes;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          result.ok
              ? (notes.isEmpty ? '已保存' : '已保存；${notes.join('；')}')
              : '保存失败：${result.errors.join('；')}',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SettingsShell(
      title: '设置',
      icon: Icons.settings,
      initialIndex: widget.initialIndex.clamp(0, 5),
      navItems: const [
        SettingsNavItem(icon: Icons.smart_toy_outlined, label: 'API 设置'),
        SettingsNavItem(icon: Icons.palette_outlined, label: 'UI 设置'),
        SettingsNavItem(icon: Icons.extension_outlined, label: 'Mod 管理'),
        SettingsNavItem(icon: Icons.cloud_outlined, label: '云同步'),
        SettingsNavItem(icon: Icons.storage_outlined, label: '存储管理'),
        SettingsNavItem(icon: Icons.info_outline, label: '关于'),
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
        switch (index) {
          case 0:
            return AiSettingsForm(form: _form);
          case 1:
            return const UiSettingsForm();
          case 2:
            return const ModManagementPanel();
          case 3:
            return CloudSyncPanel(form: _form);
          case 4:
            return const StorageManagementPanel();
          default:
            return const _AboutPanel();
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

  /// 「检查更新」开关（默认开启；从本地配置读取，读取失败按默认值）。
  bool _updateCheckEnabled = true;

  @override
  void initState() {
    super.initState();
    _versionFuture = ReleaseInfo.versionLabel();
    _versionTapDetector = TripleTapDetector(onTripleTap: _openDebug);
    _loadUpdateCheckEnabled();
  }

  @override
  void dispose() {
    _versionTapDetector.dispose();
    super.dispose();
  }

  /// 读取「检查更新」开关（本地明文配置文件；读取失败按默认开启）。
  Future<void> _loadUpdateCheckEnabled() async {
    var enabled = true;
    try {
      final config = await LocalConfigService.read();
      enabled = UpdateCheckFlow.updateCheckEnabledFrom(config);
    } catch (_) {
      // 配置不可用（如测试环境无 path_provider）时按默认开启。
    }
    if (mounted) setState(() => _updateCheckEnabled = enabled);
  }

  /// 切换「检查更新」开关：先生效再持久化，保存失败不影响本次会话。
  void _toggleUpdateCheck(bool value) {
    setState(() => _updateCheckEnabled = value);
    LocalConfigService.update({UpdateCheckFlow.keyUpdateCheckEnabled: value})
        .catchError((Object e) {
      debugPrint('检查更新开关保存失败：$e');
    });
  }

  /// 连点版本号三次进入「调试」页。
  void _openDebug() {
    if (!context.mounted) return;
    DebugScreen.open(context);
  }

  void _onVersionTap() => _versionTapDetector.tap();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Column(
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
                  if (ReleaseInfo.flutterVersion.isNotEmpty) ...[const SizedBox(height: 12),
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
            const SizedBox(height: 12),
            // 启动检查更新开关（默认开启）。
            _AboutToggle(
              value: _updateCheckEnabled,
              onChanged: _toggleUpdateCheck,
            ),
          ],
        ),
      ),
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

/// 「关于」面板开关行卡片：图标 + 标题 + 副标题 + Switch
/// （样式对齐 [_AboutEntry]，整行可点、Switch 显示当前值）。
class _AboutToggle extends StatelessWidget {
  const _AboutToggle({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

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
          onTap: () => onChanged(!value),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Icon(
                  Icons.system_update_alt_outlined,
                  size: 18,
                  color: colors.textSecondary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '检查更新',
                        style: TextStyle(
                          fontSize: 14,
                          color: colors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '启动时检查新版本（每天最多一次）',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: colors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(
                  key: const ValueKey('about_update_check_switch'),
                  value: value,
                  onChanged: onChanged,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
