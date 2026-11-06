/// 高度缓存的分档：**列宽**与**字号**都离散成"档"，同档才复用缓存高度。
///
/// 为什么要分档：条目高度由正文折行数决定，折行数同时取决于列宽和字号。
/// 只按 `(书, 条目)` 存高度的话，改窗口宽度或换字号之后旧高度全部失真，
/// 首屏会跳、轨道进度会歪。分档后不同档位互不命中，各自存各自的真值。
///
/// 步长怎么定的：
/// - **列宽 8dp 一档**：聊天列的有效宽度变化 8dp 时，一行正文（14~16px 字号）
///   最多多/少折一个字，高度变化通常在 0~2 行内，用户察觉不到；
/// - **字号 5% 一档**：`textScale` 变化 5% 时行高变化约 5%，同一档内误差
///   不超过一行，超出就换档重测。
///
/// 档太细 → 命中率骤降（用户拖动侧栏宽度时每 1dp 都换档，等于没缓存）；
/// 档太粗 → 高度偏差累积成整屏跳动。上面两个值是折中。
class ChatHeightBucket {
  const ChatHeightBucket._();

  /// 列宽每 8dp 一档。
  static const double widthStep = 8;

  /// 字号每 5% 一档。
  static const double typeScaleStep = 0.05;

  /// 列宽的档号（按步长四舍五入到最近的档）。
  static int widthOf(double logicalWidth) {
    if (logicalWidth.isNaN || logicalWidth <= 0) return 0;
    return (logicalWidth / widthStep).round();
  }

  /// 字号（`MediaQuery.textScaler.scale(1)`）的档号。
  ///
  /// 用相对 1.0 的百分比除以步长；1.0 与 1.02 同档，1.0 与 1.06 不同档。
  static int typeScaleOf(double textScale) {
    if (textScale.isNaN || textScale <= 0) return 20; // 兜底 = 100% / 5%
    return (textScale / typeScaleStep).round();
  }
}
