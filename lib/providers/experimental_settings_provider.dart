import 'package:flutter/foundation.dart';

import '../models/agent_mode_level.dart';
import '../services/local_config_service.dart';

/// 实验性功能设置（本地数据，不参与云同步）。
///
/// 目前仅含「Agent 模式」档位（默认关闭 [AgentModeLevel.off]）：它是独立于
/// 平台接入协议的生成功能档位——
/// - **Lv.1**：仅历史（记忆总结）工具 + 联网；每轮两步——第一步先读一次
///   `narrchat_readHistory`、需要时联网，调研结束后直接写 5 个正文区块；
///   第二步在正文完成后作为**单独的新请求**只维护记忆总结；所有步结束后统一入库，
///   token 记录所有步的总和；
///
/// 历史上的**完整 Agent（Lv.2）已移除**：它的世界 / 角色工具类与多栏目缺口框架
/// 仍留在代码里作为后续档位的基础设施，但当前不注册；旧配置值 `2` 与旧布尔键
/// 一律回落「关」（见 [load]）。
///
/// 该档位属于实验性功能，可能产生错误或不被服务商支持（见「设置 → 通用设置 →
/// 会话工作模式（实验性）」中的声明）。档位语义的统一映射见 `AgentModeProfile`。
///
/// 另含 **Agent 模式下按「步」的思考链压缩策略**：
/// - [compressNonBodyReasoning]（默认开）：非正文步（第二步维护）收到的
///   前面思考链压缩；第一步调研 + 正文属于正文步，保持完整；
/// - [compressAllReasoning]（默认关，且仅在主开关开启时生效）：连正文步的
///   思考链也压缩。
///
/// 压缩规则见 `services/agent/reasoning_replay.dart`。
class ExperimentalSettingsProvider extends ChangeNotifier {
  /// 允许测试直接注入初值（不触碰真实配置文件）。
  ExperimentalSettingsProvider({
    AgentModeLevel initialLevel = AgentModeLevel.off,
    bool initialCompressNonBodyReasoning = true,
    bool initialCompressAllReasoning = false,
  })  : _level = initialLevel,
        _compressNonBodyReasoning = initialCompressNonBodyReasoning,
        _compressAllReasoning = initialCompressAllReasoning {
    // 主开关关闭时子开关永远无效（构造注入也遵守同一不变量）。
    if (!_compressNonBodyReasoning) _compressAllReasoning = false;
  }

  /// 本地配置文件键名（camelCase）：现行档位键。
  static const String keyAgentModeLevel = 'agentModeLevel';

  /// 主开关：压缩非正文步模型所获取到的思考链（默认开）。
  static const String keyCompressNonBodyReasoning =
      'agentCompressNonBodyReasoning';

  /// 子开关：压缩所有回合的思考链（默认关，仅主开关开启时生效）。
  static const String keyCompressAllReasoning = 'agentCompressAllReasoning';

  /// 旧版「精简思考回传」键：只读迁移，不再写入。
  static const String legacyKeyReduceReasoningReplay =
      'agentReasoningReplayReduced';

  AgentModeLevel _level;
  bool _compressNonBodyReasoning;
  bool _compressAllReasoning;

  /// 当前 Agent 档位（默认关闭）。
  AgentModeLevel get agentModeLevel => _level;

  /// Agent 流程是否开启（当前仅 Lv.1）。
  bool get agentModeEnabled => _level.isOn;

  /// 主开关：非正文步（维护步）收到的前面思考链压缩（默认开）。
  bool get compressNonBodyReasoning => _compressNonBodyReasoning;

  /// 子开关的**生效值**：主开关关闭时恒为 false。
  bool get compressAllReasoning =>
      _compressNonBodyReasoning && _compressAllReasoning;

  /// 从本地配置读取。
  ///
  /// 档位规则：新键 [keyAgentModeLevel] **存在**即以其值为准（合法值 0/1；
  /// 非法值、以及已移除的 Lv.2 旧值 `2` 一律按关闭处理）。早期版本的布尔键
  /// `agentModeEnabled`（`true` 曾代表 Lv.2）**已废弃**：它不再作为迁移来源，
  /// 旧用户升级后回落「关」，需要时自行在设置里重新选择 Lv.1。
  /// **读取过程不写盘**（与其它 Provider 的「load 不物化」约定一致）：
  /// 只有用户切换档位时才写入新键。
  ///
  /// 思考链压缩迁移：
  /// - 新主键存在 → 以新主键为准；
  /// - 新主键缺失、旧键 `agentReasoningReplayReduced` 为 bool → 沿用旧值；
  /// - 两者都缺失 / 类型不符 → 主开关默认 `true`；
  /// - 子键缺失 / 类型不符 → `false`；主开关关闭时强制 `false`。
  Future<void> load() async {
    try {
      final config = await LocalConfigService.read();
      _level = config.containsKey(keyAgentModeLevel)
          ? AgentModeLevel.parse(config[keyAgentModeLevel])
          : AgentModeLevel.off;
      final parentRaw = config[keyCompressNonBodyReasoning];
      final legacyRaw = config[legacyKeyReduceReasoningReplay];
      final parent = parentRaw is bool
          ? parentRaw
          : (legacyRaw is bool ? legacyRaw : true);
      final childRaw = config[keyCompressAllReasoning];
      final child = childRaw is bool ? childRaw : false;
      _compressNonBodyReasoning = parent;
      _compressAllReasoning = parent && child;
    } catch (_) {
      _level = AgentModeLevel.off;
      _compressNonBodyReasoning = true;
      _compressAllReasoning = false;
    }
    notifyListeners();
  }

  /// 切换 Agent 档位：先乐观生效再异步持久化，保存失败仅记录。
  ///
  /// 瞬间影响下一次生成（组装时快照该值），不打断进行中的请求。
  Future<bool> setAgentModeLevel(AgentModeLevel level) async {
    _level = level;
    notifyListeners();
    try {
      await LocalConfigService.update({keyAgentModeLevel: level.id});
      return true;
    } catch (e) {
      debugPrint('Agent 档位保存失败：$e');
      return false;
    }
  }

  /// 切换主开关「压缩非正文步模型所获取到的思考链」。
  ///
  /// 关闭主开关会同时复位子开关（隐藏状态不得在下次开启时意外生效）。
  Future<bool> setCompressNonBodyReasoning(bool value) async {
    _compressNonBodyReasoning = value;
    if (!value) _compressAllReasoning = false;
    notifyListeners();
    try {
      await LocalConfigService.update({
        keyCompressNonBodyReasoning: value,
        if (!value) keyCompressAllReasoning: false,
      });
      return true;
    } catch (e) {
      debugPrint('非正文步思考链压缩设置保存失败：$e');
      return false;
    }
  }

  /// 切换子开关「压缩所有回合的思考链」。
  ///
  /// 主开关关闭时子开关无意义：拒绝把子开关单独置 true。
  Future<bool> setCompressAllReasoning(bool value) async {
    if (value && !_compressNonBodyReasoning) return false;
    _compressAllReasoning = value;
    notifyListeners();
    try {
      await LocalConfigService.update({keyCompressAllReasoning: value});
      return true;
    } catch (e) {
      debugPrint('所有回合思考链压缩设置保存失败：$e');
      return false;
    }
  }
}
