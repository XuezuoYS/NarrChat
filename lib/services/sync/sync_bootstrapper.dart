/// 首次连接分支判定（纯逻辑）。
///
/// 首次连接一定 WebDAV 时，按"本地是否有数据、云端是否有数据"决定走向：
/// - 仅本地有 → 初始化云端仓库（上传本地）；
/// - 仅云端有 → 拉取云端；
/// - 双方都有 → 默认**双端合并**（逐书/逐 Mod 决策页），并提供"云端覆盖本地/本地覆盖云端"可选；
/// - 都无 → 无可同步。
enum SyncBootstrapDecision {
  initCloud, // 上传本地初始化云端
  pullCloud, // 拉取云端
  mergeBoth, // 默认双端合并（需确认）
  nothing, // 无可同步
}

class SyncBootstrapper {
  SyncBootstrapper._();

  static SyncBootstrapDecision decide({
    required bool localHasData,
    required bool cloudHasData,
  }) {
    if (localHasData && !cloudHasData) return SyncBootstrapDecision.initCloud;
    if (!localHasData && cloudHasData) return SyncBootstrapDecision.pullCloud;
    if (localHasData && cloudHasData) return SyncBootstrapDecision.mergeBoth;
    return SyncBootstrapDecision.nothing;
  }
}
