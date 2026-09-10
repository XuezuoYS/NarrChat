/// Agent 模式档位（实验性功能；本地数据，不参与云同步）。
///
/// 档位决定生成流程与工具集，档位语义的统一映射见
/// `lib/services/agent/agent_mode_profile.dart`（[AgentModeProfile]）：
/// - [off]：关闭——完全走传统 Chat 流程；
/// - [lv1]：仅历史（记忆总结）工具 + 联网；正文回合输出 5 个区块
///   （排除 `## 记忆总结`），历史读取由模型自行调用、历史编辑在随之的
///   维护回合完成；
/// - [lv2]：完整 Agent（六个状态工具 + 联网）；正文回合只输出 3 个小节，
///   世界 / 角色 / 历史一律由工具维护。
///
/// [id] 是本地配置中的持久化值：新档位按顺序追加，**旧值语义永不改变**。
enum AgentModeLevel {
  off,
  lv1,
  lv2;

  /// 本地配置持久化值（见 [parse]）。
  int get id => switch (this) {
        AgentModeLevel.off => 0,
        AgentModeLevel.lv1 => 1,
        AgentModeLevel.lv2 => 2,
      };

  /// 设置页下拉标签。
  String get label => switch (this) {
        AgentModeLevel.off => '关',
        AgentModeLevel.lv1 => 'Lv.1',
        AgentModeLevel.lv2 => 'Lv.2',
      };

  /// 设置页下拉菜单里的选项标题（含语义化名称）。
  String get menuTitle => switch (this) {
        AgentModeLevel.off => '无',
        AgentModeLevel.lv1 => 'Agent Lv.1',
        AgentModeLevel.lv2 => 'Agent Lv.2',
      };

  /// 设置页下拉菜单里的选项说明（该档位「托管什么」，一句话）。
  String get menuDetail => switch (this) {
        AgentModeLevel.off => '使用传统 Chat 方式',
        AgentModeLevel.lv1 => '记忆总结部分将由 Agent 托管',
        AgentModeLevel.lv2 => '角色状态、世界状态、记忆总结部分将由 Agent 托管',
      };

  /// Chat 页左下角徽标文本（联网同款黄色样式；关闭时为空串）。
  String get badge => switch (this) {
        AgentModeLevel.off => '',
        AgentModeLevel.lv1 => 'Agent Lv.1 On (BETA)',
        AgentModeLevel.lv2 => 'Agent Lv.2 On (BETA)',
      };

  /// 是否开启 Agent 流程（Lv.1 / Lv.2）。
  bool get isOn => this != AgentModeLevel.off;

  /// 解析本地配置值：非 int / 未知值一律回退 [off]（不猜测档位）。
  static AgentModeLevel parse(Object? raw) {
    if (raw is int) {
      for (final level in AgentModeLevel.values) {
        if (level.id == raw) return level;
      }
    }
    return AgentModeLevel.off;
  }
}
