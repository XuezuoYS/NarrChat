import 'package:flutter/material.dart';

import '../services/local_config_service.dart';
import '../services/update_check_flow.dart';
import '../services/update_check_service.dart';
import '../theme/app_theme.dart';
import '../utils/release_info.dart';
import 'app_notice_overlay.dart';
import 'settings/settings_kit.dart';
import 'update_available_dialog.dart';

/// 「通用设置 → 其它设置」卡片内容：检查更新开关 + 立即检查入口。
///
/// - 开关：启动时自动检查（每天最多一次），默认开启；
/// - 立即检查：用户主动点击，**不受开关限制**（关掉自动检查后仍可手动查），
///   点击期间行尾转圈并忽略重复点击。
///
/// 设置保存到本地 JSON 配置文件（local_config/app_settings.json），不参与云同步。
class OtherSettingsSection extends StatefulWidget {
  const OtherSettingsSection({
    super.key,
    this.updateService,
    this.currentVersion,
    this.writeConfig,
  });

  /// 更新检查服务（测试注入替身；缺省使用真实 GitHub 实现）。
  final UpdateCheckService? updateService;

  /// 本地版本号（测试注入；缺省运行时读 `release.yaml`）。
  final String? currentVersion;

  /// 配置写入函数（测试注入替身；缺省写本地 JSON 配置文件）。
  final Future<void> Function(Map<String, dynamic> patch)? writeConfig;

  @override
  State<OtherSettingsSection> createState() => _OtherSettingsSectionState();
}

class _OtherSettingsSectionState extends State<OtherSettingsSection> {
  /// 检查更新服务（懒创建一次，避免每次点击都新建 HTTP 客户端）。
  late final UpdateCheckService _service =
      widget.updateService ?? UpdateCheckService();

  /// 配置写入（缺省写本地 JSON 配置文件；测试可注入替身）。
  late final Future<void> Function(Map<String, dynamic> patch) _writeConfig =
      widget.writeConfig ?? LocalConfigService.update;

  /// 「检查更新」开关（默认开启；从本地配置读取，读取失败按默认值）。
  bool _updateCheckEnabled = true;

  /// 手动检查是否进行中（用于行尾转圈 + 防重复点击）。
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _loadUpdateCheckEnabled();
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
    _writeConfig({UpdateCheckFlow.keyUpdateCheckEnabled: value}).catchError(
      (Object e) {
        debugPrint('检查更新开关保存失败：$e');
      },
    );
  }

  /// 手动检查是否有新版本：按结果弹更新对话框 / 悬浮提示。
  Future<void> _checkNow() async {
    if (_checking) return;
    // 通知入口先取出来（跨 await 后不再查 Provider）。
    final notices = context.notices;
    setState(() => _checking = true);
    final currentVersion =
        widget.currentVersion ?? await ReleaseInfo.version();
    UpdateCheckResult result;
    try {
      result = await _service.check(currentVersion: currentVersion);
    } catch (e) {
      // 服务本身承诺不抛错；这里兜底，避免一次异常把设置页的点击挂住。
      result = CheckFailed('网络请求失败：$e');
    }
    if (!mounted) return;
    setState(() => _checking = false);
    switch (result) {
      case UpdateAvailable(:final release):
        // 手动触发即「明确要看」：即使此前点过「跳过此版本」也照常展示。
        final choice = await showUpdateAvailableDialog(
          context,
          release: release,
          currentVersion: currentVersion,
        );
        // 「跳过此版本」在手动入口同样要落盘（启动检查据此不再提示该版本）。
        if (choice == UpdateDialogChoice.skipVersion) {
          try {
            await _writeConfig({
              UpdateCheckFlow.keyUpdateSkipVersion: release.tagVersion,
            });
          } catch (e) {
            debugPrint('跳过版本保存失败：$e');
          }
        }
      case UpToDate():
        notices.info('当前已是最新版本（$currentVersion）');
      case NoRelease():
        notices.info('GitHub 仓库暂无发布版本');
      case CheckFailed(:final reason):
        notices.error('检查更新失败：$reason', copyable: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    return SettingsCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SettingsSwitchRow(
            icon: Icons.system_update_alt_outlined,
            title: '检查更新',
            subtitle: '启动时检查新版本（每天最多一次）',
            value: _updateCheckEnabled,
            switchKey: const ValueKey('other_update_check_switch'),
            onChanged: _toggleUpdateCheck,
          ),
          const Divider(height: 1, indent: 14, endIndent: 14),
          // 手动检查：整行可点，进行中行尾转圈、副标题给出状态。
          SettingsRow(
            icon: Icons.refresh,
            title: '立即检查更新',
            subtitle: _checking ? '正在检查是否有新版本…' : '点击检查 GitHub 上是否有新版本发布',
            onTap: _checking ? null : _checkNow,
            rowKey: const ValueKey('other_update_check_now'),
            trailing: _checking
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    Icons.chevron_right,
                    size: 20,
                    color: colors.textSecondary,
                  ),
          ),
        ],
      ),
    );
  }
}
