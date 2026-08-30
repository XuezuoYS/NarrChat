import 'dart:async';

import 'package:flutter/material.dart';

import '../utils/release_info.dart';
import '../widgets/update_available_dialog.dart';
import 'local_config_service.dart';
import 'notification_service.dart' show NotificationBackend;
import 'update_check_service.dart';

/// 启动更新检查的编排：开关 → 24h 节流 → 检查 → 弹窗 / 失败通知。
///
/// 所有外部依赖（服务、通知后端、时钟、配置读写、弹窗）均可注入，
/// 便于测试替身替换；[UpdateCheckFlow.real] 提供生产默认组合。
///
/// 配置键存放于 `local_config/app_settings.json`（与 UI 设置同文件）：
/// - [keyUpdateCheckEnabled]：开关，默认 `true`；
/// - [keyUpdateLastCheckAt]：上次检查时间（ISO8601），请求失败也计入；
/// - [keyUpdateSkipVersion]：用户「跳过此版本」的版本号。
class UpdateCheckFlow {
  UpdateCheckFlow({
    required UpdateCheckService service,
    required NotificationBackend backend,
    String? currentVersion,
    DateTime Function()? now,
    Future<Map<String, dynamic>> Function()? readConfig,
    Future<void> Function(Map<String, dynamic>)? writeConfig,
    Future<UpdateDialogChoice?> Function(
      BuildContext context,
      GitHubRelease release,
      String currentVersion,
    )? prompt,
  })  :
        // ignore: prefer_initializing_formals
        _service = service,
        // ignore: prefer_initializing_formals
        _backend = backend,
        // ignore: prefer_initializing_formals
        _currentVersion = currentVersion,
        _now = now ?? DateTime.now,
        _readConfig = readConfig ?? LocalConfigService.read,
        _writeConfig = writeConfig ?? LocalConfigService.update,
        _prompt = prompt ?? _defaultPrompt;

  /// 默认弹窗：直接把选择交回给「发现新版本」对话框。
  static Future<UpdateDialogChoice?> _defaultPrompt(
    BuildContext context,
    GitHubRelease release,
    String currentVersion,
  ) {
    return showUpdateAvailableDialog(
      context,
      release: release,
      currentVersion: currentVersion,
    );
  }

  /// 生产默认组合：真实配置读写 + 真实弹窗；版本号运行时从 `release.yaml` 读取。
  factory UpdateCheckFlow.real({
    required UpdateCheckService service,
    required NotificationBackend backend,
  }) {
    return UpdateCheckFlow(service: service, backend: backend);
  }

  /// 配置键：检查更新开关（默认开启）。
  static const String keyUpdateCheckEnabled = 'updateCheckEnabled';

  /// 配置键：上次检查时间（ISO8601；失败也记录）。
  static const String keyUpdateLastCheckAt = 'updateLastCheckAt';

  /// 配置键：用户「跳过此版本」的版本号。
  static const String keyUpdateSkipVersion = 'updateSkipVersion';

  /// 更新失败通知的专用槽位 id（与 `notificationIdForUuid` 的 FNV 派生区间、
  /// `GenerationNotificationService` 的前台服务通知 id `0x4E43` 错开）。
  static const int kUpdateNoticeId = 0x5550;

  /// 检查频率：距上次检查不足 24 小时则本次启动跳过（零请求）。
  static const Duration checkInterval = Duration(hours: 24);

  final UpdateCheckService _service;
  final NotificationBackend _backend;

  /// 注入的本地版本号（测试用）；null 时运行时读 `release.yaml`。
  final String? _currentVersion;
  final DateTime Function() _now;
  final Future<Map<String, dynamic>> Function() _readConfig;
  final Future<void> Function(Map<String, dynamic>) _writeConfig;
  final Future<UpdateDialogChoice?> Function(
    BuildContext context,
    GitHubRelease release,
    String currentVersion,
  ) _prompt;

  /// 开关取值归一化：配置为非布尔（用户手编文件写坏）时按默认开启处理。
  static bool updateCheckEnabledFrom(Map<String, dynamic> config) =>
      config[keyUpdateCheckEnabled] is bool
      ? config[keyUpdateCheckEnabled] as bool
      : true;

  /// 启动时执行一次检查（首帧后调用；全程不抛异常，任何意外只 debugPrint）。
  Future<void> runAtStartup(GlobalKey<NavigatorState> navigatorKey) async {
    try {
      final config = await _readConfig();
      // 开关关闭：零请求、零通知、零弹窗。
      if (!updateCheckEnabledFrom(config)) return;
      // 每天最多一次（失败也计入：先落时间戳，避免反复重试骚扰）。
      final lastCheckAt = _parseLastCheckAt(config[keyUpdateLastCheckAt]);
      if (lastCheckAt != null &&
          _now().difference(lastCheckAt) < checkInterval) {
        return;
      }
      final currentVersion = _currentVersion ?? await ReleaseInfo.version();
      await _writeConfig({keyUpdateLastCheckAt: _now().toIso8601String()});
      final result = await _service.check(currentVersion: currentVersion);
      switch (result) {
        case UpdateAvailable(:final release):
          // 用户已跳过该版本：不再弹窗。
          if (release.tagVersion == config[keyUpdateSkipVersion]) return;
          final context = navigatorKey.currentContext;
          if (context == null) return;
          // ignore: use_build_context_synchronously
          final choice = await _prompt(context, release, currentVersion);
          if (choice == UpdateDialogChoice.skipVersion) {
            await _writeConfig({keyUpdateSkipVersion: release.tagVersion});
          }
        case CheckFailed(:final reason):
          debugPrint('检查更新失败：$reason');
          await _backend.show(
            id: kUpdateNoticeId,
            title: '检查更新失败',
            body: 'GitHub 源检查更新失败：$reason',
            // 空 payload：点击通知不做事（现有 onTap 对空 payload 直接忽略）。
            payload: '',
          );
        case UpToDate() || NoRelease():
          // 已是最新 / 仓库暂无发布：静默。
          break;
      }
    } catch (e, stack) {
      // 兜底：更新检查绝不影响启动与后续流程。
      debugPrint('检查更新流程异常：$e\n$stack');
    }
  }

  /// 解析上次检查时间；缺失 / 非字符串 / 非法格式返回 `null`。
  static DateTime? _parseLastCheckAt(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }
}
