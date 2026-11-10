/// Agent 模式档位（实验性功能；本地数据，不参与云同步）。
///
/// 档位决定生成流程与工具集，档位语义的统一映射见
/// `lib/services/agent/agent_mode_profile.dart`（[AgentModeProfile]）：
/// - [off]：关闭——完全走传统 Chat 流程；
/// - [lv1]：三段流程（调研 → 记忆 → 正文；无联网时恰好 3 次请求）——调研阶段
///   读一次 `narrchat_readHistory`、需要时联网（不写大纲）；记忆阶段**同一回合**
///   内在思考通道推演剧情定大纲、并用 `op=append` 先于正文落入本轮条目；
///   正文阶段输出 5 个区块（排除
///   `## 记忆总结`）且是唯一上屏阶段；维护轮仅在记忆未落地 / 有缺口时兜底。
///   工具集为仅历史（记忆总结）一读一写 + 联网，记忆由 Agent 托管。
///
/// 历史上的**完整 Agent（Lv.2，六工具 + 正文三小节）已移除**：它的世界 / 角色
/// 工具类与多栏目缺口框架仍留在代码里作为后续档位的基础设施，但当前没有任何
/// 档位注册它们（详见 `lib/services/agent/state/state_tools.dart` 的说明）。
///
/// [id] 是本地配置中的持久化值：新档位按顺序追加，**旧值语义永不改变**；
/// 已移除档位的旧值（如 `2`）不再映射任何档位，[parse] 回落 [off]。
enum AgentModeLevel {
  off,
  lv1;

  /// 本地配置持久化值（见 [parse]）。
  int get id => switch (this) {
        AgentModeLevel.off => 0,
        AgentModeLevel.lv1 => 1,
      };

  /// 设置页下拉标签。
  String get label => switch (this) {
        AgentModeLevel.off => '关',
        AgentModeLevel.lv1 => 'Lv.1',
      };

  /// 设置页下拉菜单里的选项标题（含语义化名称）。
  String get menuTitle => switch (this) {
        AgentModeLevel.off => '无',
        AgentModeLevel.lv1 => 'Agent Lv.1',
      };

  /// 设置页下拉菜单里的选项说明（该档位「托管什么」，一句话）。
  String get menuDetail => switch (this) {
        AgentModeLevel.off => '使用传统 Chat 方式',
        AgentModeLevel.lv1 => '记忆总结部分将由 Agent 托管',
      };

  /// Chat 页左下角徽标文本（联网同款黄色样式；关闭时为空串）。
  String get badge => switch (this) {
        AgentModeLevel.off => '',
        AgentModeLevel.lv1 => 'Agent Lv.1 On (BETA)',
      };

  /// 是否开启 Agent 流程（当前仅 Lv.1）。
  bool get isOn => this != AgentModeLevel.off;

  /// 解析本地配置值：非 int / 未知值（含已移除的 Lv.2 值 `2`）一律回退
  /// [off]（不猜测档位）。
  static AgentModeLevel parse(Object? raw) {
    if (raw is int) {
      for (final level in AgentModeLevel.values) {
        if (level.id == raw) return level;
      }
    }
    return AgentModeLevel.off;
  }
}
