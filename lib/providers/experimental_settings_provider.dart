import 'package:flutter/foundation.dart';

import '../models/agent_mode_level.dart';
import '../services/local_config_service.dart';

/// 实验性功能设置（本地数据，不参与云同步）。
///
/// 目前仅含「Agent 模式」档位（默认关闭 [AgentModeLevel.off]）：它是独立于
/// 平台接入协议的生成功能档位——
/// - **Lv.1**：仅历史（记忆总结）工具 + 联网；正文回合输出 5 个区块
///   （排除 `## 记忆总结`）并先调用 `narrchat_readHistory`，随后**每轮必发**
///   的维护回合用 `narrchat_editHistory` 补本轮记忆条目；
/// - **Lv.2**：完整 Agent（六个状态工具 `narrchat_readWorldState` /
///   `narrchat_editWorldState` / `narrchat_readCharacterState` /
///   `narrchat_editCharacterState` / `narrchat_readHistory` /
///   `narrchat_editHistory` + 联网），正文回合只输出 3 个小节；
///
/// 两档都属于实验性功能，可能产生错误或不被服务商支持（见「设置 → 通用设置 →
/// 实验性设置」中的声明）。档位语义的统一映射见 `AgentModeProfile`。
///
/// 另含 **Agent 模式下的思考回传策略**（[reduceReasoningReplay]，默认关 =
/// 逐字节回传原文；开启则精简，规则见 `services/agent/reasoning_replay.dart`）。
class ExperimentalSettingsProvider extends ChangeNotifier {
  /// 允许测试直接注入初值（不触碰真实配置文件）。
  ExperimentalSettingsProvider({
    AgentModeLevel initialLevel = AgentModeLevel.off,
    bool initialReduceReasoningReplay = false,
  })  : _level = initialLevel,
        _reduceReasoningReplay = initialReduceReasoningReplay;

  /// 本地配置文件键名（camelCase）：现行档位键。
  static const String keyAgentModeLevel = 'agentModeLevel';

  /// 历史键（**只读迁移用**）：早期版本的布尔开关（true → Lv.2）。
  static const String keyAgentModeEnabled = 'agentModeEnabled';

  /// 本地配置文件键名：Agent 模式思考回传是否精简（默认关）。
  static const String keyReduceReasoningReplay = 'agentReasoningReplayReduced';

  AgentModeLevel _level;
  bool _reduceReasoningReplay;

  /// 当前 Agent 档位（默认关闭）。
  AgentModeLevel get agentModeLevel => _level;

  /// Agent 流程是否开启（Lv.1 / Lv.2）。
  bool get agentModeEnabled => _level.isOn;

  /// Agent 模式下的思考回传是否精简（默认关 = 逐字节回传原文）。
  bool get reduceReasoningReplay => _reduceReasoningReplay;

  /// 从本地配置读取（读取失败按默认关闭）。
  ///
  /// 迁移规则：新键 [keyAgentModeLevel] **存在**即以其值为准（合法值 0/1/2，
  /// 非法值按关闭处理），旧键一律忽略；新键缺失时才回退读旧布尔键
  /// [keyAgentModeEnabled]，`true` → [AgentModeLevel.lv2]（保持旧版本行为）。
  /// **读取过程不写盘**（与其它 Provider 的「load 不物化」约定一致）：
  /// 只有用户切换档位时才写入新键。
  Future<void> load() async {
    try {
      final config = await LocalConfigService.read();
      if (config.containsKey(keyAgentModeLevel)) {
        _level = AgentModeLevel.parse(config[keyAgentModeLevel]);
      } else {
        final legacy = config[keyAgentModeEnabled];
        _level = legacy is bool && legacy
            ? AgentModeLevel.lv2
            : AgentModeLevel.off;
      }
      // 缺失 / 类型不符 ⇒ 默认**关闭**（逐字节回传原文）。
      final reduced = config[keyReduceReasoningReplay];
      _reduceReasoningReplay = reduced is bool ? reduced : false;
    } catch (_) {
      _level = AgentModeLevel.off;
      _reduceReasoningReplay = false;
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

  /// 切换「精简思考回传」：先乐观生效再异步持久化，保存失败仅记录。
  Future<bool> setReduceReasoningReplay(bool reduce) async {
    _reduceReasoningReplay = reduce;
    notifyListeners();
    try {
      await LocalConfigService.update({keyReduceReasoningReplay: reduce});
      return true;
    } catch (e) {
      debugPrint('精简思考回传设置保存失败：$e');
      return false;
    }
  }
}
