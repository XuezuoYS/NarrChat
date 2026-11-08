import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config/ai_platforms.dart';
import '../config/app_config.dart';
import '../models/ai_platform.dart';
import '../models/book.dart';
import '../providers/ai_settings_provider.dart';
import '../providers/book_provider.dart';
import '../providers/cloud_sync_provider.dart';
import '../providers/mod_provider.dart';
import '../services/ai_service.dart';
import '../services/book_creation/book_creation_runner.dart';
import '../services/book_creation/book_creation_step.dart';
import '../services/book_creation/book_creation_writer.dart';
import '../theme/app_theme.dart';
import '../utils/formats.dart';
import '../widgets/app_notice_overlay.dart';
import '../widgets/book_creation/agent_book_idea_form.dart';
import '../widgets/book_creation/book_creation_step_card.dart';
import '../widgets/island_bar.dart';
import '../widgets/markdown_editing_controller.dart';
import '../widgets/narr_chat_app_bar.dart';
import 'book_settings_screen.dart';
import 'home_navigation.dart';

/// 一句话创建新书（Agent 创建新书）的整条流程。
///
/// **一条路由、两个阶段**：
/// - [_FlowPhase.idea]：输入创意 + 选择生成模型 + 开始创建；
/// - [_FlowPhase.creating]：逐步骤流式展示 AI 产出 → 完整性检查 / 补充轮 →
///   写库校验 → 成功 / 不完整 / 失败对话框。
///
/// 输入框控制器由本页持有，创建失败或用户主动取消时只是切回看
/// `_FlowPhase.idea`，输入内容天然保留（满足「编辑页面未销毁」的要求）。
/// 成功后本路由会被 `ChatScreen` 替换，不会残留半路页面。
class AgentBookCreationPage extends StatefulWidget {
  const AgentBookCreationPage({super.key, this.aiService, this.writer});

  /// AI 服务（测试注入；null = 真实 [AiService]）。
  final AiService? aiService;

  /// 落库 / 校验器（测试注入；null = 从 `AppRepositories` 组装）。
  final BookCreationWriter? writer;

  @override
  State<AgentBookCreationPage> createState() => _AgentBookCreationPageState();
}

class _AgentBookCreationPageState extends State<AgentBookCreationPage> {
  late final MarkdownEditingController _idea = MarkdownEditingController();
  late final AiService _aiService = widget.aiService ?? AiService();

  /// 分步用量（键 = 阶段 + 尝试次数），用于汇总总消耗。
  final Map<String, BookCreationUsage> _stepUsages = {};

  _FlowPhase _phase = _FlowPhase.idea;
  bool _ideaEmpty = true;
  bool _busy = false;

  /// 是否处于「落库 + 回读校验」阶段（此时不可取消，避免删到写了一半的书）。
  bool _writing = false;

  /// 本页的生成模型选择：只作用于本次创建，不写回全局设置。
  String _platformId = '';
  String _modelId = '';
  String? _reasoningEffort;
  bool _selectionInitialized = false;

  final List<_StepView> _steps = [];
  BookCreationUsage _totalUsage = BookCreationUsage.empty;
  bool _cancelRequested = false;
  bool _leaveAfterCancel = false;

  Book? _createdBook;
  bool _keptIncomplete = false;
  List<String> _keptProblems = const [];

  @override
  void initState() {
    super.initState();
    _ideaEmpty = _idea.text.trim().isEmpty;
    _idea.addListener(_onIdeaChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_selectionInitialized) return;
    _selectionInitialized = true;
    final settings = context.read<AiSettingsProvider>();
    _platformId = settings.selectedPlatformId;
    _modelId = settings.selectedModelId;
  }

  @override
  void dispose() {
    _idea.removeListener(_onIdeaChanged);
    _idea.dispose();
    super.dispose();
  }

  void _onIdeaChanged() {
    final empty = _idea.text.trim().isEmpty;
    if (empty != _ideaEmpty) {
      setState(() => _ideaEmpty = empty);
    }
  }

  // ---------------------------------------------------------------------------
  // 开始 / 取消 / 返回
  // ---------------------------------------------------------------------------

  Future<void> _start() async {
    if (_busy) return;
    final idea = _idea.text.trim();
    if (idea.isEmpty) return;
    final confirmed = await _confirmStart();
    if (confirmed != true || !mounted) return;

    final settings = context.read<AiSettingsProvider>();
    final modProvider = context.read<ModProvider>();
    final platform = _resolvePlatform(settings);
    final model = platform.modelOrFirst(_resolveModelId(platform));
    final effort = (_reasoningEffort?.trim().isNotEmpty ?? false)
        ? _reasoningEffort!.trim()
        : settings.reasoningEffortFor(platform, model);

    setState(() {
      _busy = true;
      _phase = _FlowPhase.creating;
      _writing = false;
      _cancelRequested = false;
      _leaveAfterCancel = false;
      _createdBook = null;
      _keptIncomplete = false;
      _keptProblems = const [];
      _steps
        ..clear()
        ..addAll([
          for (var i = 0; i < BookCreationRunner.baseStages.length; i++)
            _StepView.waiting(BookCreationRunner.baseStages[i], i),
        ]);
      _stepUsages.clear();
      _totalUsage = BookCreationUsage.empty;
    });
    FocusScope.of(context).unfocus();

    // Mod 目录：创建期间可选的全部 Mod（预置 + 用户自定义）。
    try {
      await modProvider.loadUserMods();
    } catch (_) {
      // 读取失败不阻断创建：至少还能用预置 Mod。
    }
    if (!mounted) return;

    final runner = BookCreationRunner(
      aiService: _aiService,
      platform: platform,
      model: model,
      apiKey: _apiKeyFor(settings, platform),
      baseUrl: platform.baseUrl.isEmpty
          ? AppConfig.defaultApiBaseUrlEffective
          : platform.baseUrl,
      reasoningEffort: effort,
      thinking: settings.thinkingFor(model),
      streaming: settings.streamingFor(model),
    );

    try {
      final result = await runner.run(
        idea: idea,
        availableMods: modProvider.allMods,
        onEvent: _onStepEvent,
        isCancelled: () => _cancelRequested || !mounted,
      );
      if (!mounted) return;
      if (result.remainingProblems.isNotEmpty) {
        final keep = await _confirmIncomplete(result.remainingProblems);
        if (!mounted) return;
        if (keep != true) {
          _resetToIdea();
          return;
        }
        _keptIncomplete = true;
        _keptProblems = List.of(result.remainingProblems);
        await _writeAndVerify(result, fallbackTitle: '未命名书籍');
      } else {
        await _writeAndVerify(result);
      }
    } on AiCancelledException {
      if (!mounted) return;
      if (_leaveAfterCancel) {
        Navigator.of(context).pop();
        return;
      }
      _resetToIdea();
      if (mounted) context.notices.info('已取消创建');
    } on BookCreationException catch (error) {
      if (!mounted) return;
      await _showFailure('${error.stage.label}失败：${error.message}');
    } catch (error) {
      if (!mounted) return;
      await _showFailure('创建过程发生未预期错误：$error');
    }
  }

  Future<void> _writeAndVerify(
    BookCreationRunResult result, {
    String fallbackTitle = '',
  }) async {
    setState(() {
      _writing = true;
      _upsertVerify(
        BookCreationStepStatus.running,
        summary: fallbackTitle.isEmpty ? '正在写入并校验…' : '正在写入并校验（保留现有内容）…',
      );
    });

    BookCreationWriteResult write;
    try {
      final writer = widget.writer ?? BookCreationWriter.fromAppRepositories();
      write = await writer.writeAndVerify(
        draft: result.draft,
        fallbackTitle: fallbackTitle,
      );
    } catch (error) {
      write = BookCreationWriteResult.failure('创建写入器失败：$error');
    }
    if (!mounted) return;

    if (!write.ok) {
      final reason = write.error ?? '数据库写入失败';
      setState(() {
        _writing = false;
        _upsertVerify(
          BookCreationStepStatus.failed,
          summary: reason,
          problems: [reason],
        );
      });
      await _showFailure(reason, usage: result.usage);
      return;
    }

    final book = write.book!;
    final bookProvider = context.read<BookProvider>();
    await bookProvider.loadBooks();
    if (!mounted) return;
    final fresh = _bookOf(bookProvider.books, book.uuid) ?? book;
    bookProvider.selectBook(fresh);
    // 所有数据（书 + 世界书 + Mod）都写完后只同步一次。
    context.read<CloudSyncProvider?>()?.triggerSync();

    setState(() {
      _writing = false;
      _busy = false;
      _createdBook = fresh;
      _upsertVerify(
        BookCreationStepStatus.done,
        summary: _keptIncomplete
            ? '写入并校验通过（内容不完整，已保留）'
            : '写入并校验通过',
      );
    });

    await _showSuccessDialog(fresh, result.usage);
    if (!mounted) return;
    await _openSettings(fresh);
  }

  /// 成功 / 保留不完整书后的导航：设置页 →（保存或返回都）新书聊天页。
  Future<void> _openSettings(Book book) async {
    await BookSettingsScreen.open(context, book: book);
    if (!mounted) return;
    await openHomeChat(context, book, replace: true);
  }

  Future<void> _handleBack() async {
    if (_phase == _FlowPhase.idea) {
      if (Navigator.of(context).canPop()) Navigator.of(context).pop();
      return;
    }
    if (_createdBook != null) {
      await _openSettings(_createdBook!);
      return;
    }
    if (_writing) {
      context.notices.info('正在写入并校验，请稍候…');
      return;
    }
    final leave = await _confirmCancel(leave: true);
    if (leave == true && mounted) {
      setState(() {
        _leaveAfterCancel = true;
        _cancelRequested = true;
      });
    }
  }

  Future<void> _requestCancel() async {
    if (!_canCancel) return;
    final cancel = await _confirmCancel(leave: false);
    if (cancel == true && mounted) {
      setState(() => _cancelRequested = true);
      context.notices.info('正在取消…');
    }
  }

  bool get _canCancel =>
      _busy && !_writing && _createdBook == null && !_cancelRequested;

  void _resetToIdea() {
    if (!mounted) return;
    setState(() {
      _phase = _FlowPhase.idea;
      _busy = false;
      _writing = false;
      _cancelRequested = false;
      _leaveAfterCancel = false;
      _createdBook = null;
      _steps.clear();
      _stepUsages.clear();
      _totalUsage = BookCreationUsage.empty;
      _keptIncomplete = false;
      _keptProblems = const [];
    });
  }

  // ---------------------------------------------------------------------------
  // 步骤事件
  // ---------------------------------------------------------------------------

  void _onStepEvent(BookCreationStepEvent event) {
    if (!mounted) return;
    setState(() {
      final index = _steps.indexWhere((step) => step.key == event.key);
      final existing = index >= 0 ? _steps[index] : null;
      final view = _StepView(
        stage: event.stage,
        attempt: event.attempt,
        badge: _badgeOf(event),
        title: _titleOf(event),
        status: event.status,
        visibleText: event.visibleText.isNotEmpty
            ? event.visibleText
            : (existing?.visibleText ?? ''),
        summary: event.summary ?? existing?.summary,
        detailMarkdown: event.detailMarkdown ?? existing?.detailMarkdown,
        problems:
            event.problems.isNotEmpty ? event.problems : (existing?.problems ?? const []),
        usage: event.usage.hasData
            ? event.usage
            : (existing?.usage ?? BookCreationUsage.empty),
      );
      if (index >= 0) {
        _steps[index] = view;
      } else {
        _steps.add(view);
      }
      if ((event.status == BookCreationStepStatus.done ||
              event.status == BookCreationStepStatus.warning) &&
          event.usage.hasData) {
        _stepUsages[event.key] = event.usage;
        _totalUsage = _sumUsage(_stepUsages.values);
      }
    });
  }

  void _upsertVerify(
    BookCreationStepStatus status, {
    String? summary,
    List<String> problems = const [],
  }) {
    final index = _steps.indexWhere(
      (step) => step.stage == BookCreationStage.verify,
    );
    final view = _StepView(
      stage: BookCreationStage.verify,
      attempt: 0,
      badge: '${BookCreationRunner.baseStages.length + 1}',
      title: BookCreationStage.verify.label,
      status: status,
      summary: summary,
      problems: problems,
    );
    if (index >= 0) {
      _steps[index] = view;
    } else {
      _steps.add(view);
    }
  }

  String _badgeOf(BookCreationStepEvent event) {
    if (event.stage == BookCreationStage.supplement) {
      return '补${event.attempt}';
    }
    final index = BookCreationRunner.baseStages.indexOf(event.stage);
    return index >= 0 ? '${index + 1}' : '·';
  }

  String _titleOf(BookCreationStepEvent event) {
    if (event.stage == BookCreationStage.supplement) {
      return '补充完善（${event.attempt}/2）';
    }
    return event.stage.label;
  }

  // ---------------------------------------------------------------------------
  // 模型 / 用量解析
  // ---------------------------------------------------------------------------

  AiPlatform _resolvePlatform(AiSettingsProvider settings) {
    for (final platform in settings.platforms) {
      if (platform.id == _platformId) return platform;
    }
    return settings.selectedPlatform;
  }

  String _resolveModelId(AiPlatform platform) {
    return platform.modelById(_modelId) != null
        ? _modelId
        : platform.defaultModel.id;
  }

  /// 平台 API Key：优先该平台已保存的 Key；内置默认平台再回退默认值。
  String _apiKeyFor(AiSettingsProvider settings, AiPlatform platform) {
    final stored = settings.apiKeyFor(platform.id).trim();
    if (stored.isNotEmpty) return stored;
    return platform.id == AiPlatforms.defaultPlatformId
        ? AppConfig.defaultApiKeyEffective
        : '';
  }

  static BookCreationUsage _sumUsage(
    Iterable<BookCreationUsage> values,
  ) {
    var total = BookCreationUsage.empty;
    for (final value in values) {
      total = total.plus(value);
    }
    return total;
  }

  static Book? _bookOf(List<Book> books, String uuid) {
    for (final book in books) {
      if (book.uuid == uuid) return book;
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // 对话框
  // ---------------------------------------------------------------------------

  Future<bool?> _confirmStart() {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          key: const ValueKey('agent_book_confirm_dialog'),
          title: const Text('开始创建新书？'),
          content: const Text(
            '你输入的内容不会被保存，只会用于本次生成。\n\n'
            '创建会按步骤调用 AI，可能失败并产生 Token 消耗；'
            '失败后会回到本页，输入内容仍然保留。',
          ),
          actions: [
            TextButton(
              key: const ValueKey('agent_book_confirm_cancel'),
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const ValueKey('agent_book_confirm_start'),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('开始创建'),
            ),
          ],
        ),
      ),
    );
  }

  Future<bool?> _confirmIncomplete(List<String> problems) {
    final shown = problems.take(12).toList();
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          key: const ValueKey('agent_book_incomplete_dialog'),
          title: const Text('内容不完整'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('AI 生成的内容经过补充后仍不完整：'),
                const SizedBox(height: 8),
                for (final problem in shown)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text('· $problem'),
                  ),
                if (problems.length > shown.length)
                  Text('…还有 ${problems.length - shown.length} 项'),
                const SizedBox(height: 10),
                const Text('可以返回修改创意后重试，或保留这本书并稍后在书籍设置里补齐。'),
              ],
            ),
          ),
          actions: [
            TextButton(
              key: const ValueKey('agent_book_incomplete_keep'),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('保留此书'),
            ),
            FilledButton(
              key: const ValueKey('agent_book_incomplete_edit'),
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('返回重新编辑'),
            ),
          ],
        ),
      ),
    );
  }

  Future<bool?> _confirmCancel({required bool leave}) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('agent_book_cancel_dialog'),
        title: Text(leave ? '取消创建并离开？' : '取消创建？'),
        content: Text(
          leave
              ? '已生成的内容会被丢弃，你输入的创意仍然保留。'
              : '已生成的内容会被丢弃，输入内容仍然保留，可重新点击开始创建。',
        ),
        actions: [
          TextButton(
            key: const ValueKey('agent_book_cancel_continue'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('继续创建'),
          ),
          FilledButton(
            key: const ValueKey('agent_book_cancel_confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('取消创建'),
          ),
        ],
      ),
    );
  }

  Future<void> _showFailure(
    String reason, {
    BookCreationUsage? usage,
  }) async {
    final used = usage ?? _totalUsage;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          key: const ValueKey('agent_book_failure_dialog'),
          title: const Text('创建失败'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(reason),
                const SizedBox(height: 12),
                Text(
                  '本次已消耗：${_usageText(used)}',
                  style: const TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 6),
                const Text(
                  '输入内容仍然保留，可修改创意后重试。',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
          actions: [
            FilledButton(
              key: const ValueKey('agent_book_failure_back'),
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('返回编辑'),
            ),
          ],
        ),
      ),
    );
    if (mounted) _resetToIdea();
  }

  Future<void> _showSuccessDialog(
    Book book,
    BookCreationUsage usage,
  ) async {
    final kept = _keptIncomplete;
    final problems = _keptProblems.take(12).toList();
    final usageSteps = [
      for (final step in _steps)
        if (step.usage.hasData) step,
    ];
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          key: const ValueKey('agent_book_success_dialog'),
          title: Text(kept ? '已保留此书（内容不完整）' : '创建成功'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('《${book.title}》已创建完成，可在书籍设置里继续调整。'),
                if (kept) ...[
                  const SizedBox(height: 10),
                  const Text('以下内容不完整（已用默认值或留空）：'),
                  const SizedBox(height: 4),
                  for (final problem in problems)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Text('· $problem'),
                    ),
                  if (_keptProblems.length > problems.length)
                    Text('…还有 ${_keptProblems.length - problems.length} 项'),
                ],
                const SizedBox(height: 12),
                Text(
                  '本次消耗：${_usageText(usage)}',
                  style: const TextStyle(fontSize: 12),
                ),
                if (usageSteps.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  const Text('分步消耗：', style: TextStyle(fontSize: 12)),
                  for (final step in usageSteps)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        '${step.title}：'
                        '输入 ${Formats.formatTokenCount(step.usage.promptTokens)}'
                        ' · 输出 ${Formats.formatTokenCount(step.usage.completionTokens)}',
                        style: const TextStyle(fontSize: 11.5),
                      ),
                    ),
                ],
              ],
            ),
          ),
          actions: [
            FilledButton(
              key: const ValueKey('agent_book_success_confirm'),
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('前往书籍设置'),
            ),
          ],
        ),
      ),
    );
  }

  String _usageText(BookCreationUsage usage) {
    return '输入 Tokens ${Formats.formatTokenCount(usage.promptTokens)}'
        ' · 输出 Tokens ${Formats.formatTokenCount(usage.completionTokens)}'
        ' · 缓存命中 ${Formats.formatTokenCount(usage.cachedTokensIn)}';
  }

  // ---------------------------------------------------------------------------
  // 构建
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    final settings = context.watch<AiSettingsProvider>();
    final platform = _resolvePlatform(settings);
    final modelId = _resolveModelId(platform);
    return PopScope(
      canPop: _phase == _FlowPhase.idea,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _handleBack();
      },
      child: IslandAwareScaffold(
        backgroundColor: colors.background,
        appBarBuilder: (context, extraRow) => NarrChatAppBar(
          extraRowHeight: extraRow,
          // 与设置页一致：无底边、渐变图标。
          showBorder: false,
          icon: Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              gradient: NarrChatTheme.brandGradient,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.auto_awesome, size: 16, color: Colors.white),
          ),
          title: 'Agent 创建新书',
        ),
        body: _phase == _FlowPhase.idea
            ? AgentBookIdeaForm(
                controller: _idea,
                settings: settings,
                platformId: platform.id,
                modelId: modelId,
                reasoningEffort: _reasoningEffort,
                onModelSelected: (platformId, modelId, effort) {
                  setState(() {
                    _platformId = platformId;
                    _modelId = modelId;
                    _reasoningEffort = effort;
                  });
                },
                onStart: _ideaEmpty || _busy ? null : _start,
              )
            : _buildCreationView(context),
      ),
    );
  }

  Widget _buildCreationView(BuildContext context) {
    final colors = context.narrColors;
    final completed = _steps
        .where(
          (step) =>
              step.status == BookCreationStepStatus.done ||
              step.status == BookCreationStepStatus.warning,
        )
        .length;
    final total = _steps.isEmpty ? 1 : _steps.length;
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 960),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildIdeaSummary(context),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                minHeight: 6,
                                value: completed / total,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            '步骤 $completed/$total',
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      for (final step in _steps)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: BookCreationStepCard(
                            key: ValueKey(
                              'book_creation_step_${step.key}',
                            ),
                            badge: step.badge,
                            title: step.title,
                            status: step.status,
                            visibleText: step.visibleText,
                            summary: step.summary,
                            detailMarkdown: step.detailMarkdown,
                            problems: step.problems,
                            usage: step.usage,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        _buildFooter(context),
      ],
    );
  }

  Widget _buildIdeaSummary(BuildContext context) {
    final colors = context.narrColors;
    final idea = _idea.text.trim();
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(NarrChatTheme.cardRadius),
        border: Border.all(color: colors.divider),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lightbulb_outline, size: 16, color: colors.textSecondary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              idea,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.5,
                color: colors.textSecondary,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '不会保存',
            style: TextStyle(fontSize: 11, color: colors.placeholder),
          ),
        ],
      ),
    );
  }

  Widget _buildFooter(BuildContext context) {
    final colors = context.narrColors;
    final created = _createdBook;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(24, 10, 24, 12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border(top: BorderSide(color: colors.divider)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _writing
                        ? '正在写入并校验…'
                        : '总消耗（模型未返回的项显示「无」）',
                    style: TextStyle(
                      fontSize: 11,
                      color: colors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _usageText(_totalUsage),
                    style: TextStyle(
                      fontSize: 12,
                      color: colors.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            if (created != null)
              FilledButton.icon(
                key: const ValueKey('agent_book_created_go_settings'),
                onPressed: () => _openSettings(created),
                icon: const Icon(Icons.book_outlined, size: 18),
                label: const Text('前往书籍设置'),
              )
            else
              OutlinedButton.icon(
                key: const ValueKey('agent_book_cancel_button'),
                onPressed: _canCancel ? _requestCancel : null,
                icon: const Icon(Icons.stop_circle_outlined, size: 18),
                label: Text(_cancelRequested ? '正在取消…' : '取消生成'),
              ),
          ],
        ),
      ),
    );
  }
}

/// 创建流程的 UI 阶段。
enum _FlowPhase { idea, creating }

/// 步骤卡片的数据快照。
class _StepView {
  const _StepView({
    required this.stage,
    required this.attempt,
    required this.badge,
    required this.title,
    required this.status,
    this.visibleText = '',
    this.summary,
    this.detailMarkdown,
    this.problems = const [],
    this.usage = BookCreationUsage.empty,
  });

  factory _StepView.waiting(BookCreationStage stage, int index) {
    return _StepView(
      stage: stage,
      attempt: 0,
      badge: '${index + 1}',
      title: stage.label,
      status: BookCreationStepStatus.waiting,
    );
  }

  final BookCreationStage stage;
  final int attempt;
  final String badge;
  final String title;
  final BookCreationStepStatus status;
  final String visibleText;
  final String? summary;
  final String? detailMarkdown;
  final List<String> problems;
  final BookCreationUsage usage;

  String get key => '${stage.name}#$attempt';
}
