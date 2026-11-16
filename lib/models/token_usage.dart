import '../utils/formats.dart';
import 'round.dart';

/// Token 统计卡里的一组数据属于谁：主模型 / 子模型 / 总计。
enum TokenUsageRole { main, subagent, total }

/// 一组 Token 统计（某个模型的一次生成）。
///
/// `null` 一律表示**无数据**（服务商没返回该字段 / 历史轮次没记录），界面显示
/// 「（无）」；`0` 是真实的 0 消耗，两者必须区分。
class TokenUsageStats {
  const TokenUsageStats({
    required this.role,
    this.modelName = '',
    this.tokensIn,
    this.cachedTokensIn,
    this.tokensOut,
  });

  final TokenUsageRole role;

  /// 模型名；总计组为空串。
  final String modelName;

  final int? tokensIn;

  /// 缓存命中的输入 token（包含在 [tokensIn] 内，不额外相加）。
  final int? cachedTokensIn;

  final int? tokensOut;

  /// 展示用模型名：空白 / 无名称 → 「（无）」。
  String get displayModelName =>
      modelName.trim().isEmpty ? Formats.noData : modelName.trim();

  /// 总 token = 输入 + 输出；两侧都无数据 → null。
  ///
  /// 只有一侧有数据时按已知侧求和（与旧统计卡口径一致）。
  int? get totalTokens {
    if (tokensIn == null && tokensOut == null) return null;
    return (tokensIn ?? 0) + (tokensOut ?? 0);
  }

  String get totalTokensText => Formats.formatTokenCount(totalTokens);

  /// 缓存命中率文本；缺数据时返回「（无）」。
  String get cacheHitRateText =>
      Formats.formatCacheHitRate(cachedTokensIn, tokensIn) ?? Formats.noData;
}

/// 一轮的 Token 统计拆分：主模型 / 子模型（未启用为 null）/ 总计。
///
/// 数据全部来自 [Round] 的四个子模型字段：
/// - 四列全 NULL → 子模型未启用，[subagent] 为 null，统计卡只显示主模型；
/// - 名称非空但 token 全 NULL → 子模型启用但服务商未返回用量，仍显示子模型区，
///   数值为「（无）」，总计等于主模型。
class RoundTokenUsage {
  const RoundTokenUsage({
    required this.main,
    required this.total,
    this.subagent,
  });

  final TokenUsageStats main;

  /// 未启用子模型时为 null。
  final TokenUsageStats? subagent;

  /// 主 + 子逐项求和；两侧都无数据才 null。
  final TokenUsageStats total;

  bool get hasSubagent => subagent != null;

  factory RoundTokenUsage.of(Round round) {
    final main = TokenUsageStats(
      role: TokenUsageRole.main,
      modelName: round.modelName,
      tokensIn: round.tokensIn,
      cachedTokensIn: round.cachedTokensIn,
      tokensOut: round.tokensOut,
    );
    final subagent = round.hasSubagent
        ? TokenUsageStats(
            role: TokenUsageRole.subagent,
            modelName: round.subagentModelName,
            tokensIn: round.subagentTokensIn,
            cachedTokensIn: round.subagentCachedTokensIn,
            tokensOut: round.subagentTokensOut,
          )
        : null;
    return RoundTokenUsage(
      main: main,
      subagent: subagent,
      total: TokenUsageStats(
        role: TokenUsageRole.total,
        tokensIn: _sum(main.tokensIn, subagent?.tokensIn),
        cachedTokensIn: _sum(main.cachedTokensIn, subagent?.cachedTokensIn),
        tokensOut: _sum(main.tokensOut, subagent?.tokensOut),
      ),
    );
  }

  /// 两侧都 null 才是 null；否则按已知侧求和（0 视为真实数据）。
  static int? _sum(int? a, int? b) {
    if (a == null && b == null) return null;
    return (a ?? 0) + (b ?? 0);
  }
}
