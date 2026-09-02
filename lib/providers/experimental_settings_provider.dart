import 'package:flutter/foundation.dart';

import '../services/local_config_service.dart';

/// 实验性功能设置（本地数据，不参与云同步）。
///
/// 目前仅含「Agent 模式」开关（默认关闭）：它是独立于平台接入协议的
/// 生成功能开关——开启后两阶段生成（正文轮 → 状态轮）并调用自定义工具
/// （narrchat_readState / narrchat_editSection / narrchat_webSearch /
/// narrchat_webFetchPage）维护状态，属于实验性功能，可能产生错误或不被
/// 服务商支持（见「设置 → 通用设置 → 实验性设置」中的声明）。
class ExperimentalSettingsProvider extends ChangeNotifier {
  /// 允许测试直接注入初值（不触碰真实配置文件）。
  ExperimentalSettingsProvider({bool initialAgentModeEnabled = false})
      : _agentModeEnabled = initialAgentModeEnabled;

  /// 本地配置文件键名（camelCase）。
  static const String keyAgentModeEnabled = 'agentModeEnabled';

  bool _agentModeEnabled;

  /// Agent 模式是否开启（默认关闭）。
  bool get agentModeEnabled => _agentModeEnabled;

  /// 从本地配置读取（读取失败 / 键缺失按默认关闭）。
  Future<void> load() async {
    try {
      _agentModeEnabled = await LocalConfigService.readValue<bool>(
            keyAgentModeEnabled,
            fallback: false,
          ) ??
          false;
    } catch (_) {
      _agentModeEnabled = false;
    }
    notifyListeners();
  }

  /// 切换 Agent 模式开关：先乐观生效再异步持久化，保存失败仅记录。
  ///
  /// 瞬间影响下一次生成（组装时快照该值），不打断进行中的请求。
  Future<bool> setAgentModeEnabled(bool value) async {
    _agentModeEnabled = value;
    notifyListeners();
    try {
      await LocalConfigService.update({keyAgentModeEnabled: value});
      return true;
    } catch (e) {
      debugPrint('Agent 模式开关保存失败：$e');
      return false;
    }
  }
}
