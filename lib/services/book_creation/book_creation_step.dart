/// 一句话创建新书的阶段、状态与 Token 用量。
///
/// 纯数据模块（不依赖 Flutter），便于执行器 / 校验器单独测试。
library;

/// 创建流程的步骤（5 个内容阶段 + 补充轮 + 程序检查）。
///
/// 顺序即界面展示顺序；[supplement] 与 [verify] 由调用方按需追加。
enum BookCreationStage {
  titleCategory('标题与类别'),
  mods('选择 Mod'),
  baseSettingWorldBook('基础设定与世界书'),
  prompts('前置词、后置词与文笔要求'),
  roleCategories('角色类别与描述格式'),
  supplement('补充完善'),
  verify('程序检查');

  const BookCreationStage(this.label);

  /// 界面展示名（不含「步骤 n」前缀）。
  final String label;

  /// 是否为 5 个固定内容阶段之一（补充轮 / 检查不算）。
  bool get isBaseStage => index <= roleCategories.index;
}

/// 单个步骤在界面上的状态。
enum BookCreationStepStatus {
  /// 还没有开始（固定阶段预置为等待中）。
  waiting,

  /// 正在请求模型 / 正在流式输出。
  running,

  /// 正常完成。
  done,

  /// 完成但带有警告（如忽略了无法识别的 Mod）。
  warning,

  /// 失败（此时流程会中断并弹失败对话框）。
  failed,
}

/// 一次创建流程内的 Token 用量（null = 该次响应未带回该字段）。
class BookCreationUsage {
  const BookCreationUsage({
    this.promptTokens,
    this.completionTokens,
    this.cachedTokensIn,
  });

  final int? promptTokens;
  final int? completionTokens;
  final int? cachedTokensIn;

  static const BookCreationUsage empty = BookCreationUsage();

  /// 是否有任何用量数据（全 null 表示模型没返回）。
  bool get hasData =>
      promptTokens != null ||
      completionTokens != null ||
      cachedTokensIn != null;

  /// 累加两段用量：null 一律视为「没有数据」，不当作 0。
  BookCreationUsage plus(BookCreationUsage other) {
    return BookCreationUsage(
      promptTokens: _add(promptTokens, other.promptTokens),
      completionTokens: _add(completionTokens, other.completionTokens),
      cachedTokensIn: _add(cachedTokensIn, other.cachedTokensIn),
    );
  }

  static int? _add(int? total, int? delta) =>
      delta == null ? total : (total ?? 0) + delta;
}

/// 执行器向界面推送的一次步骤状态变化。
///
/// - [attempt]：0 = 固定内容阶段；1..N = 第几次补充轮；
/// - [visibleText]：当前步骤**累计**的可读文本（去掉标签后的内容），
///   界面直接整体替换即可，不需要自己拼增量；
/// - [summary] / [detailMarkdown]：完成后的摘要与可展开内容；
/// - [problems]：本步骤解析 / 完成时的提醒（不阻断流程）。
class BookCreationStepEvent {
  const BookCreationStepEvent({
    required this.stage,
    required this.status,
    this.attempt = 0,
    this.visibleText = '',
    this.summary,
    this.detailMarkdown,
    this.problems = const [],
    this.usage = BookCreationUsage.empty,
  });

  final BookCreationStage stage;
  final BookCreationStepStatus status;
  final int attempt;
  final String visibleText;
  final String? summary;
  final String? detailMarkdown;
  final List<String> problems;
  final BookCreationUsage usage;

  /// 界面用的稳定键：同一阶段 + 同一尝试次数视为同一步骤。
  String get key => '${stage.name}#$attempt';
}
