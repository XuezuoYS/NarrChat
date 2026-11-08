import '../../models/ai_platform.dart';
import '../../models/book_creation_draft.dart';
import '../../models/mod.dart';
import '../ai_request_body_builder.dart';
import '../ai_service.dart';
import 'book_creation_parser.dart';
import 'book_creation_prompts.dart';
import 'book_creation_step.dart';
import 'book_creation_verifier.dart';

/// 创建流程的硬失败：阶段 + 可直接展示给用户的原因。
class BookCreationException implements Exception {
  const BookCreationException(this.stage, this.message);

  final BookCreationStage stage;
  final String message;

  @override
  String toString() => '${stage.label}：$message';
}

/// 一次创建（5 个内容阶段 + 至多 2 次补充轮）的最终结果。
class BookCreationRunResult {
  const BookCreationRunResult({
    required this.draft,
    required this.remainingProblems,
    required this.usage,
  });

  final BookCreationDraft draft;

  /// 补充轮结束后仍未解决的问题（空 = 内容完整）。
  final List<String> remainingProblems;

  /// 本次全部 AI 调用的 Token 合计。
  final BookCreationUsage usage;
}

/// 逐阶段执行「一句话创建新书」的 AI 生成。
///
/// 设计要点：
/// - **每步一次请求**，顺序固定；每步产出用标签协议解析，解析失败只记提醒、
///   不中断（缺失项由完整性检查 + 补充轮兜底）；
/// - **只有硬失败才中断**：网络 / API / 超时 / 输出截断 / 用户取消；
/// - 每次调用的 Token 都累加，分步用量随事件回传给界面；
/// - 与 `AiSettingsProvider` 解耦：平台 / 模型 / Key / 参数由调用方解析好后注入。
class BookCreationRunner {
  BookCreationRunner({
    required this.aiService,
    required this.platform,
    required this.model,
    required this.apiKey,
    required this.baseUrl,
    required this.reasoningEffort,
    required this.thinking,
    required this.streaming,
    this.maxSupplementRounds = 2,
    this.parser = const BookCreationParser(),
    this.prompts = const BookCreationPrompts(),
  });

  final AiService aiService;
  final AiPlatform platform;
  final AiModel model;
  final String apiKey;
  final String baseUrl;
  final String reasoningEffort;
  final bool thinking;
  final bool streaming;

  /// 补充轮上限（需求：一到两次）。
  final int maxSupplementRounds;

  final BookCreationParser parser;
  final BookCreationPrompts prompts;

  /// 固定内容阶段（界面按此顺序预置步骤卡）。
  static const List<BookCreationStage> baseStages = [
    BookCreationStage.titleCategory,
    BookCreationStage.mods,
    BookCreationStage.baseSettingWorldBook,
    BookCreationStage.prompts,
    BookCreationStage.roleCategories,
  ];

  /// 依次执行全部阶段；[isCancelled] 返回 true 时抛 [AiCancelledException]。
  Future<BookCreationRunResult> run({
    required String idea,
    required List<Mod> availableMods,
    void Function(BookCreationStepEvent event)? onEvent,
    bool Function()? isCancelled,
  }) async {
    var draft = BookCreationDraft.empty;
    var usage = BookCreationUsage.empty;

    Future<void> runStage(
      BookCreationStage stage,
      String prompt, {
      int attempt = 0,
    }) async {
      _throwIfCancelled(isCancelled);
      onEvent?.call(
        BookCreationStepEvent(
          stage: stage,
          status: BookCreationStepStatus.running,
          attempt: attempt,
        ),
      );
      try {
        final call = await _call(
          stage,
          prompt,
          attempt: attempt,
          onEvent: onEvent,
          isCancelled: isCancelled,
        );
        usage = usage.plus(call.usage);
        final parsed = _parseStage(stage, call.content, availableMods);
        draft = _merge(draft, parsed);

        final remaining = stage == BookCreationStage.supplement
            ? BookCreationVerifier.completenessProblems(draft)
            : const <String>[];
        onEvent?.call(
          BookCreationStepEvent(
            stage: stage,
            status: parsed.warnings.isEmpty && remaining.isEmpty
                ? BookCreationStepStatus.done
                : BookCreationStepStatus.warning,
            attempt: attempt,
            visibleText: BookCreationParser.visibleTextOf(call.content),
            summary: _summaryOf(stage, draft, availableMods),
            detailMarkdown: _detailOf(stage, draft, availableMods),
            problems: stage == BookCreationStage.supplement
                ? remaining
                : parsed.warnings,
            usage: call.usage,
          ),
        );
      } on AiCancelledException {
        rethrow;
      } on BookCreationException catch (error) {
        onEvent?.call(
          BookCreationStepEvent(
            stage: stage,
            status: BookCreationStepStatus.failed,
            attempt: attempt,
            problems: [error.message],
          ),
        );
        rethrow;
      } catch (error) {
        final message = _messageOf(error);
        onEvent?.call(
          BookCreationStepEvent(
            stage: stage,
            status: BookCreationStepStatus.failed,
            attempt: attempt,
            problems: [message],
          ),
        );
        throw BookCreationException(stage, message);
      }
    }

    for (final stage in baseStages) {
      final prompt = _promptFor(stage, idea, draft, availableMods);
      await runStage(stage, prompt);
    }

    var problems = BookCreationVerifier.completenessProblems(draft);
    for (var attempt = 1;
        problems.isNotEmpty && attempt <= maxSupplementRounds;
        attempt++) {
      _throwIfCancelled(isCancelled);
      final prompt = prompts.supplement(
        idea: idea,
        draft: draft,
        selectedMods: _selectedMods(draft, availableMods),
        problems: problems,
        attempt: attempt,
        maxAttempts: maxSupplementRounds,
      );
      await runStage(BookCreationStage.supplement, prompt, attempt: attempt);
      problems = BookCreationVerifier.completenessProblems(draft);
    }

    return BookCreationRunResult(
      draft: draft,
      remainingProblems: problems,
      usage: usage,
    );
  }

  // ---------------------------------------------------------------------------
  // 单次调用
  // ---------------------------------------------------------------------------

  Future<({String content, BookCreationUsage usage})> _call(
    BookCreationStage stage,
    String userPrompt, {
    required int attempt,
    void Function(BookCreationStepEvent event)? onEvent,
    bool Function()? isCancelled,
  }) async {
    final body = _buildBody(userPrompt);
    final contentSb = StringBuffer();
    var lastVisible = '';

    void onChunk(AiStreamChunk chunk) {
      if (chunk.contentDelta.isEmpty) return;
      contentSb.write(chunk.contentDelta);
      final visible = BookCreationParser.visibleTextOf(contentSb.toString());
      if (visible == lastVisible) return;
      lastVisible = visible;
      onEvent?.call(
        BookCreationStepEvent(
          stage: stage,
          status: BookCreationStepStatus.running,
          attempt: attempt,
          visibleText: visible,
        ),
      );
    }

    final result = platform.apiType.isResponses
        ? await aiService.responses(
            apiBaseUrl: baseUrl,
            apiKey: apiKey,
            requestBody: body,
            stream: streaming,
            onChunk: onChunk,
            isCancelled: isCancelled,
          )
        : await aiService.chat(
            apiBaseUrl: baseUrl,
            apiKey: apiKey,
            requestBody: body,
            stream: streaming,
            onChunk: onChunk,
            isCancelled: isCancelled,
          );

    if (result.incomplete) {
      throw BookCreationException(
        stage,
        '模型输出被截断（可能达到最大 token 上限），请调高「最大 token」'
        '或更换模型后重试。',
      );
    }

    return (
      content: result.content,
      usage: BookCreationUsage(
        promptTokens: result.promptTokens,
        completionTokens: result.completionTokens,
        cachedTokensIn: result.cachedTokensIn,
      ),
    );
  }

  /// 按平台接入协议构建请求体（两条线路共用同一份参数取值）。
  Map<String, dynamic> _buildBody(String userPrompt) {
    final responses = platform.apiType.isResponses;
    final values = AiRequestValues(
      model: model.id,
      messages: responses
          ? [
              {'role': 'user', 'content': userPrompt},
            ]
          : [
              {'role': 'system', 'content': BookCreationPrompts.system},
              {'role': 'user', 'content': userPrompt},
            ],
      temperature: model.temperature,
      thinking: thinking,
      reasoningEffort: reasoningEffort,
      maxTokens: model.maxTokens,
      stream: streaming,
      tools: null,
      instructions: responses ? BookCreationPrompts.system : null,
    );
    return AiRequestBodyBuilder.buildPresetBody(
      rules: platform.apiType.requestRules,
      values: values,
    );
  }

  // ---------------------------------------------------------------------------
  // 阶段 → 提示词 / 解析 / 合并 / 展示
  // ---------------------------------------------------------------------------

  String _promptFor(
    BookCreationStage stage,
    String idea,
    BookCreationDraft draft,
    List<Mod> availableMods,
  ) {
    switch (stage) {
      case BookCreationStage.titleCategory:
        return prompts.titleCategory(idea: idea);
      case BookCreationStage.mods:
        return prompts.mods(
          idea: idea,
          draft: draft,
          availableMods: availableMods,
        );
      case BookCreationStage.baseSettingWorldBook:
        return prompts.baseSettingWorldBook(
          idea: idea,
          draft: draft,
          selectedMods: _selectedMods(draft, availableMods),
        );
      case BookCreationStage.prompts:
        return prompts.prePostWriting(
          idea: idea,
          draft: draft,
          selectedMods: _selectedMods(draft, availableMods),
        );
      case BookCreationStage.roleCategories:
        return prompts.roleCategories(
          idea: idea,
          draft: draft,
          selectedMods: _selectedMods(draft, availableMods),
        );
      case BookCreationStage.supplement:
      case BookCreationStage.verify:
        throw ArgumentError('阶段 ${stage.name} 不使用常规提示词');
    }
  }

  BookCreationParseResult _parseStage(
    BookCreationStage stage,
    String raw,
    List<Mod> availableMods,
  ) {
    switch (stage) {
      case BookCreationStage.titleCategory:
        return parser.parseTitleCategory(raw);
      case BookCreationStage.mods:
        return parser.parseMods(raw, availableMods);
      case BookCreationStage.baseSettingWorldBook:
        return parser.parseBaseSettingWorldBook(raw);
      case BookCreationStage.prompts:
        return parser.parsePrompts(raw);
      case BookCreationStage.roleCategories:
        return parser.parseRoleCategories(raw);
      case BookCreationStage.supplement:
        return parser.parseAll(raw, availableMods);
      case BookCreationStage.verify:
        return const BookCreationParseResult();
    }
  }

  /// 把解析结果合并进草稿。
  ///
  /// 标量只在「有非空值」时覆盖；世界书 / 角色类别只在「解析出非空列表」时
  /// 覆盖——补充轮没重发的块不会被空值洗掉。
  static BookCreationDraft _merge(
    BookCreationDraft draft,
    BookCreationParseResult parsed,
  ) {
    final modRefs = parsed.modRefs;
    final worldBook = parsed.worldBook;
    final roleCategories = parsed.roleCategories;
    return draft.copyWith(
      title: _nonEmpty(parsed.title) ?? draft.title,
      category: _nonEmpty(parsed.category) ?? draft.category,
      baseSetting: _nonEmpty(parsed.baseSetting) ?? draft.baseSetting,
      worldBook: worldBook != null && worldBook.isNotEmpty
          ? worldBook
          : draft.worldBook,
      globalPrePrompt: _nonEmpty(parsed.prePrompt) ?? draft.globalPrePrompt,
      globalPostPrompt: _nonEmpty(parsed.postPrompt) ?? draft.globalPostPrompt,
      writingRequirements:
          _nonEmpty(parsed.writingRequirements) ?? draft.writingRequirements,
      roleCategories: roleCategories != null && roleCategories.isNotEmpty
          ? roleCategories
          : draft.roleCategories,
      modRefs: modRefs != null && modRefs.isNotEmpty ? modRefs : draft.modRefs,
    );
  }

  static String? _nonEmpty(String? value) {
    final text = value?.trim() ?? '';
    return text.isEmpty ? null : text;
  }

  static List<Mod> _selectedMods(
    BookCreationDraft draft,
    List<Mod> availableMods,
  ) {
    final byRef = {for (final mod in availableMods) mod.ref: mod};
    return [
      for (final ref in draft.modRefs)
        if (byRef[ref] != null) byRef[ref]!,
    ];
  }

  static String? _summaryOf(
    BookCreationStage stage,
    BookCreationDraft draft,
    List<Mod> availableMods,
  ) {
    switch (stage) {
      case BookCreationStage.titleCategory:
        return '《${draft.title.trim()}》 · ${draft.category.trim()}';
      case BookCreationStage.mods:
        final mods = _selectedMods(draft, availableMods);
        if (mods.isEmpty) return '未选择 Mod';
        return '已选 ${mods.length} 个 Mod：'
            '${mods.map((mod) => mod.name.trim()).join('、')}';
      case BookCreationStage.baseSettingWorldBook:
        return '基础设定 ${draft.baseSetting.trim().length} 字 · '
            '世界书 ${draft.worldBook.length} 条';
      case BookCreationStage.prompts:
        return '前置词 ${draft.globalPrePrompt.trim().length} 字 · '
            '后置词 ${draft.globalPostPrompt.trim().length} 字 · '
            '文笔要求 ${draft.writingRequirements.trim().length} 字';
      case BookCreationStage.roleCategories:
        final names = [
          for (final category in draft.roleCategories)
            if (category.name.trim().isNotEmpty) category.name.trim(),
        ];
        return names.isEmpty
            ? '暂无角色类别（待补充）'
            : '角色类别：${names.join(' / ')}';
      case BookCreationStage.supplement:
        final remaining = BookCreationVerifier.completenessProblems(draft).length;
        return remaining == 0 ? '内容已补全' : '补充完成，仍有 $remaining 项待补';
      case BookCreationStage.verify:
        return null;
    }
  }

  static String? _detailOf(
    BookCreationStage stage,
    BookCreationDraft draft,
    List<Mod> availableMods,
  ) {
    switch (stage) {
      case BookCreationStage.titleCategory:
        return '**书名**：${draft.title.trim()}\n\n'
            '**分类**：${draft.category.trim()}';
      case BookCreationStage.mods:
        final mods = _selectedMods(draft, availableMods);
        if (mods.isEmpty) return '未选择任何 Mod。';
        return [
          for (final mod in mods)
            '- **${mod.name.trim()}**（`${mod.ref}`）'
                '${mod.description.trim().isEmpty ? '' : '：${mod.description.trim()}'}',
        ].join('\n');
      case BookCreationStage.baseSettingWorldBook:
        final buf = StringBuffer();
        if (draft.baseSetting.trim().isNotEmpty) {
          buf.writeln('### 基础设定\n');
          buf.writeln(draft.baseSetting.trim());
        }
        // 展示 AI 的原始产出（含不完整项）；落库时只写有效条目。
        final entries = draft.worldBook;
        if (entries.isNotEmpty) {
          buf.writeln('\n### 世界书（${entries.length} 条）\n');
          for (final entry in entries) {
            final keyword = entry.keyword.trim();
            final content = entry.content.trim();
            buf.writeln(
              '- **关键词**：${keyword.isEmpty ? '（缺少关键词）' : keyword}',
            );
            buf.writeln(
              '  ${content.isEmpty ? '（内容为空）' : content.replaceAll('\n', '\n  ')}',
            );
          }
        }
        return buf.toString().trim();
      case BookCreationStage.prompts:
        return [
          if (draft.globalPrePrompt.trim().isNotEmpty)
            '### 前置词\n\n${draft.globalPrePrompt.trim()}',
          if (draft.globalPostPrompt.trim().isNotEmpty)
            '### 后置词\n\n${draft.globalPostPrompt.trim()}',
          if (draft.writingRequirements.trim().isNotEmpty)
            '### 文笔要求\n\n${draft.writingRequirements.trim()}',
        ].join('\n\n');
      case BookCreationStage.roleCategories:
        final categories = draft.roleCategories;
        if (categories.isEmpty) return '暂无角色类别。';
        return [
          '### 角色类别与描述格式\n',
          for (final category in categories) ...[
            '**${category.name.trim().isEmpty ? '（缺少名称）' : category.name.trim()}**',
            '```',
            category.format.trim().isEmpty ? '（描述格式为空）' : category.format,
            '```',
          ],
        ].join('\n');
      case BookCreationStage.supplement:
      case BookCreationStage.verify:
        return null;
    }
  }

  static void _throwIfCancelled(bool Function()? isCancelled) {
    if (isCancelled?.call() ?? false) {
      throw const AiCancelledException();
    }
  }

  static String _messageOf(Object error) {
    if (error is AiException) return error.message;
    return error.toString();
  }
}
