import 'package:flutter/foundation.dart';

import '../models/agent_mode_level.dart';
import '../services/local_config_service.dart';

/// 实验性功能设置（本地数据，不参与云同步）。
///
/// 目前含「Agent 模式」档位（默认关闭 [AgentModeLevel.off]）：它是独立于
/// 平台接入协议的生成功能档位——
/// - **Lv.1**：仅历史（记忆总结）工具 + 联网；每轮两步——第一步先读一次
///   `narrchat_readHistory`、需要时联网，调研结束后直接写 5 个正文区块；
///   第二步在正文完成后作为**单独的新请求**只维护记忆总结；所有步结束后统一入库，
///   主模型 / 子模型 token 分桶记录（第一步归主模型，第二步归子模型）；
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
///
/// 另含**非创作步子模型**（[subagentPlatformId] / [subagentModelId] +
/// [subagentReasoningEffort]，默认空 = 与当前激活主模型一致）：只作用于第二步
/// 状态维护（非创作步）；配置与主模型完全相同时按「未启用」处理。思考强度由
/// 子模型选择器单独记住，空 = 用该模型自己的默认强度。跨模型无法命中主模型的
/// 上下文缓存，设置页会提示确保子模型成本足够低。
class ExperimentalSettingsProvider extends ChangeNotifier {
  /// 允许测试直接注入初值（不触碰真实配置文件）。
  ExperimentalSettingsProvider({
    AgentModeLevel initialLevel = AgentModeLevel.off,
    bool initialCompressNonBodyReasoning = true,
    bool initialCompressAllReasoning = false,
    String initialSubagentPlatformId = '',
    String initialSubagentModelId = '',
    String initialSubagentReasoningEffort = '',
  }) : _level = initialLevel,
       _compressNonBodyReasoning = initialCompressNonBodyReasoning,
       _compressAllReasoning = initialCompressAllReasoning,
       _subagentPlatformId = initialSubagentPlatformId.trim(),
       _subagentModelId = initialSubagentModelId.trim(),
       _subagentReasoningEffort = initialSubagentReasoningEffort.trim() {
    // 主开关关闭时子开关永远无效（构造注入也遵守同一不变量）。
    if (!_compressNonBodyReasoning) _compressAllReasoning = false;
    // 子模型必须平台 + 模型成对出现；只给一半等于没配置。
    if (_subagentPlatformId.isEmpty || _subagentModelId.isEmpty) {
      _subagentPlatformId = '';
      _subagentModelId = '';
      _subagentReasoningEffort = '';
    }
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

  /// 非创作步（第二步状态维护）所用子模型的平台 id；空 = 跟随主模型。
  static const String keySubagentPlatformId = 'agentSubagentPlatformId';

  /// 非创作步（第二步状态维护）所用子模型的模型 id；空 = 跟随主模型。
  static const String keySubagentModelId = 'agentSubagentModelId';

  /// 子模型选择器记住的思考强度；空 = 用该模型自己的默认强度。
  ///
  /// 与 Chat 页的「按模型记住强度」分开存：子模型设置是独立的一份配置，
  /// 不应因为用户在对话页切换主模型强度而被动改变。
  static const String keySubagentReasoningEffort =
      'agentSubagentReasoningEffort';

  AgentModeLevel _level;
  bool _compressNonBodyReasoning;
  bool _compressAllReasoning;
  String _subagentPlatformId;
  String _subagentModelId;
  String _subagentReasoningEffort;

  /// 当前 Agent 档位（默认关闭）。
  AgentModeLevel get agentModeLevel => _level;

  /// Agent 流程是否开启（当前仅 Lv.1）。
  bool get agentModeEnabled => _level.isOn;

  /// 主开关：非正文步（维护步）收到的前面思考链压缩（默认开）。
  bool get compressNonBodyReasoning => _compressNonBodyReasoning;

  /// 子开关的**生效值**：主开关关闭时恒为 false。
  bool get compressAllReasoning =>
      _compressNonBodyReasoning && _compressAllReasoning;

  /// 子模型配置的平台 id（空 = 跟随当前激活主模型）。
  String get subagentPlatformId => _subagentPlatformId;

  /// 子模型配置的模型 id（空 = 跟随当前激活主模型）。
  String get subagentModelId => _subagentModelId;

  /// 子模型选择器记住的思考强度（空 = 用模型默认强度）。
  String get subagentReasoningEffort => _subagentReasoningEffort;

  /// 是否配置了具体子模型（平台 + 模型成对出现）。
  bool get hasSubagentModel =>
      _subagentPlatformId.isNotEmpty && _subagentModelId.isNotEmpty;

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
      _subagentPlatformId = _readId(config[keySubagentPlatformId]);
      _subagentModelId = _readId(config[keySubagentModelId]);
      _subagentReasoningEffort = _readId(config[keySubagentReasoningEffort]);
      // 平台 + 模型必须成对；只有一半（旧缓存 / 手改配置）按未配置处理，
      // 强度也随配置一起清空（不能留下一个没有模型的孤立强度）。
      if (_subagentPlatformId.isEmpty || _subagentModelId.isEmpty) {
        _subagentPlatformId = '';
        _subagentModelId = '';
        _subagentReasoningEffort = '';
      }
    } catch (_) {
      _level = AgentModeLevel.off;
      _compressNonBodyReasoning = true;
      _compressAllReasoning = false;
      _subagentPlatformId = '';
      _subagentModelId = '';
      _subagentReasoningEffort = '';
    }
    notifyListeners();
  }

  /// 读取一个 id 类配置：只认非空字符串，其它类型 / 空白一律视为未配置。
  static String _readId(Object? raw) => raw is String ? raw.trim() : '';

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

  /// 设置非创作步使用的子模型（可同时记住思考强度）。
  ///
  /// [platformId] / [modelId] 任一为空表示「与当前激活主模型一致」（会同时清空
  /// 平台 / 模型 / 强度三个键，避免留下半套失效配置）。
  /// [reasoningEffort] 为空 = 用该模型自己的默认强度；非空 = 用户在选择器里
  /// 明确选择的强度。先乐观生效再异步持久化，保存失败仅记录；下一次组装会
  /// 瞬时读到新值，不打断进行中的请求。
  Future<bool> setSubagentModel(
    String platformId,
    String modelId, {
    String reasoningEffort = '',
  }) async {
    final platform = platformId.trim();
    final model = modelId.trim();
    final valid = platform.isNotEmpty && model.isNotEmpty;
    _subagentPlatformId = valid ? platform : '';
    _subagentModelId = valid ? model : '';
    _subagentReasoningEffort = valid ? reasoningEffort.trim() : '';
    notifyListeners();
    try {
      await LocalConfigService.update({
        keySubagentPlatformId: _subagentPlatformId,
        keySubagentModelId: _subagentModelId,
        keySubagentReasoningEffort: _subagentReasoningEffort,
      });
      return true;
    } catch (e) {
      debugPrint('子模型设置保存失败：$e');
      return false;
    }
  }
}
