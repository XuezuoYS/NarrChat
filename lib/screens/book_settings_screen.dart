import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/book.dart';
import '../models/mod.dart';
import '../models/role_category.dart';
import '../models/world_book_entry.dart';
import '../providers/book_provider.dart';
import '../providers/cloud_sync_provider.dart';
import '../providers/mod_provider.dart';
import '../providers/world_book_provider.dart';
import '../services/book_cover_import_service.dart';
import '../services/image_store.dart';
import '../services/sync/image_deletion.dart';
import '../services/sync/sync_models.dart';
import '../theme/app_theme.dart';
import '../utils/constants.dart';
import '../widgets/app_notice_overlay.dart';
import '../widgets/book_cover_image.dart';
import '../widgets/book_mod_panel.dart';
import '../widgets/book_other_settings_panel.dart';
import '../widgets/draggable_role_list.dart';
import '../widgets/history_round_stepper.dart';
import '../widgets/markdown_editing_controller.dart';
import '../widgets/memory_summary_round_selector.dart';
import '../widgets/prompt_input_hint.dart';
import '../widgets/settings/settings_kit.dart';
import '../widgets/settings_shell.dart';
import '../widgets/uuid_display.dart';
import '../widgets/world_book_panel.dart';

/// 全窗口书籍设置界面（新建 / 编辑书籍）。
///
/// 编辑态 7 个子模块（新建态 6 个）：
/// - 书籍概览：书名、分类、文笔要求描述（区别于文笔参考段落）、历史轮次数、
///   记忆总结轮次合并、全局前后置词；
/// - 角色类别与描述格式：可拖拽排序、增删、为每类设定描述格式；
/// - 基础设定：世界观等不会变更的设定；
/// - 世界书：关键词命中后自动注入 System Prompt；
/// - 文笔参考段落：风格范例文本（仅注入 system）；
/// - Mod 管理：启用/禁用 Mod 并调整置入顺序；
/// - 其它设置（仅编辑态）：书籍维护操作，目前提供「删除未启用的代」。
class BookSettingsScreen extends StatefulWidget {
  final Book? book;

  /// 封面「选图 + 裁剪」服务（可注入替身；缺省走真实 `file_picker` + 裁剪页）。
  final BookCoverImportService? coverService;

  const BookSettingsScreen({super.key, this.book, this.coverService});

  static Future<bool?> open(
    BuildContext context, {
    Book? book,
    BookCoverImportService? coverService,
  }) {
    return Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => BookSettingsScreen(
          book: book,
          coverService: coverService,
        ),
      ),
    );
  }

  @override
  State<BookSettingsScreen> createState() => _BookSettingsScreenState();
}

class _BookSettingsScreenState extends State<BookSettingsScreen> {
  late final TextEditingController _title;
  late final TextEditingController _category;
  late final MarkdownEditingController _writingRequirements;
  late final MarkdownEditingController _baseSetting;
  late final MarkdownEditingController _writingStyle;
  late final MarkdownEditingController _globalPrePrompt;
  late final MarkdownEditingController _globalPostPrompt;
  late int _historyRounds;
  late int _memorySummaryRounds;
  late List<RoleCategory> _roleCategories;

  /// 当前草稿里的封面（图片相对路径；null = 没有封面）。
  String? _coverImg;

  /// 用户本次是否动过封面：动过就不再跟随外部（云同步）刷新。
  bool _coverDirty = false;

  /// 封面导入 / 裁剪进行中（按钮禁用 + 文案切换）。
  bool _importingCover = false;

  /// 封面「选图 + 裁剪」服务（构造参数注入，缺省走真实实现）。
  late final BookCoverImportService _coverService =
      widget.coverService ?? const PlatformBookCoverImportService();

  bool _isSaving = false;

  /// 编辑模式下已解析的**最新**书籍实例（随 Provider 刷新更新；新建草稿为 null）。
  ///
  /// 打开时优先从 [BookProvider] 按 id 解析，调用方传入的陈旧快照
  ///（如云同步落地前打开的对话页传入的 currentBook 旧引用）不再决定展示值。
  Book? _book;

  /// 用户已编辑过的字段：同步落地刷新时仅更新**未编辑**字段，
  /// 避免覆盖用户进行中的输入（用户草稿优先，保存后以草稿为准）。
  final Set<TextEditingController> _dirtyControllers = {};
  bool _historyRoundsDirty = false;
  bool _memorySummaryRoundsDirty = false;
  bool _rolesDirty = false;

  /// 程序化刷新守卫：区分「用户输入」与「外部（同步）写入」，
  /// 防止把程序写入误标为用户编辑。
  bool _syncing = false;

  BookProvider? _bookProvider;
  bool _listening = false;

  bool get _isCreate => widget.book == null;

  /// 新建书籍草稿模式下收集的世界书条目（保存书籍成功后统一落库）。
  List<WorldBookEntry> _draftWorldBookEntries = [];

  /// 新建书籍草稿模式下收集的 Mod 配置（保存书籍成功后统一落库）。
  List<BookModConfig> _draftModConfigs = [];

  @override
  void initState() {
    super.initState();
    _book = widget.book == null ? null : _resolveFresh(widget.book!);
    final b = _book;
    _title = TextEditingController(text: b?.title ?? '');
    _category = TextEditingController(text: b?.category ?? '');
    _writingRequirements = MarkdownEditingController(text: b?.writingRequirements ?? '');
    _baseSetting = MarkdownEditingController(text: b?.baseSetting ?? '');
    _writingStyle = MarkdownEditingController(text: b?.writingStyle ?? '');
    _globalPrePrompt = MarkdownEditingController(text: b?.globalPrePrompt ?? '');
    _globalPostPrompt = MarkdownEditingController(text: b?.globalPostPrompt ?? '');
    _historyRounds = (b?.historyRounds ?? 1) < 1 ? 1 : (b?.historyRounds ?? 1);
    // 模型已把越界档位收敛为 0（见 Book.memorySummaryRounds）。
    _memorySummaryRounds = b?.memorySummaryRounds ?? 0;
    _roleCategories = List.of(
      b?.roleCategories ?? Constants.defaultRoleCategories,
    );
    _coverImg = b?.bookCoverImg;
    // 打开书籍设置即触发一次静默同步：另一台设备刚改过的书籍设置就近拉到本地
    // （编辑态打开时展示最新值；已无空闲轮询，此处是编辑前唯一的拉取点）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Provider.of<CloudSyncProvider?>(context, listen: false)
          ?.triggerSync(silent: true);
    });
    // 编辑态监听书籍数据变化（云同步落地等）：未编辑字段即时跟随最新值；
    // 用户已编辑的字段保留草稿。
    for (final c in <TextEditingController>[
      _title,
      _category,
      _writingRequirements,
      _baseSetting,
      _writingStyle,
      _globalPrePrompt,
      _globalPostPrompt,
    ]) {
      c.addListener(() {
        if (_syncing) return;
        _dirtyControllers.add(c);
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_listening || _isCreate) return;
    _listening = true;
    _bookProvider = context.read<BookProvider>();
    _bookProvider!.addListener(_onBookProviderChanged);
  }

  @override
  void dispose() {
    _bookProvider?.removeListener(_onBookProviderChanged);
    _title.dispose();
    _category.dispose();
    _writingRequirements.dispose();
    _baseSetting.dispose();
    _writingStyle.dispose();
    _globalPrePrompt.dispose();
    _globalPostPrompt.dispose();
    super.dispose();
  }

  /// 解析 [base] 同 uuid 的最新书籍实例（Provider 列表优先；无则回退传入快照）。
  Book _resolveFresh(Book base) {
    if (base.uuid.isEmpty) return base;
    for (final b in context.read<BookProvider>().books) {
      if (b.uuid == base.uuid) return b;
    }
    return base;
  }

  /// 书籍数据变化（CloudSyncProvider 落地后的重载等）：刷新未编辑字段。
  void _onBookProviderChanged() {
    final base = _book;
    if (base == null || !mounted || _isCreate) return;
    final fresh = _resolveFresh(base);
    if (identical(fresh, base)) return;
    setState(() {
      _book = fresh;
      _applyBookToFields(fresh);
    });
  }

  /// 把 [book] 的最新字段同步到编辑控件；跳过用户已编辑过的字段。
  void _applyBookToFields(Book book) {
    _syncing = true;
    try {
      if (!_dirtyControllers.contains(_title)) _title.text = book.title;
      if (!_dirtyControllers.contains(_category)) _category.text = book.category;
      if (!_dirtyControllers.contains(_writingRequirements)) {
        _writingRequirements.text = book.writingRequirements;
      }
      if (!_dirtyControllers.contains(_baseSetting)) {
        _baseSetting.text = book.baseSetting;
      }
      if (!_dirtyControllers.contains(_writingStyle)) {
        _writingStyle.text = book.writingStyle;
      }
      if (!_dirtyControllers.contains(_globalPrePrompt)) {
        _globalPrePrompt.text = book.globalPrePrompt;
      }
      if (!_dirtyControllers.contains(_globalPostPrompt)) {
        _globalPostPrompt.text = book.globalPostPrompt;
      }
      if (!_historyRoundsDirty) {
        _historyRounds = book.historyRounds < 1 ? 1 : book.historyRounds;
      }
      if (!_memorySummaryRoundsDirty) {
        _memorySummaryRounds = book.memorySummaryRounds;
      }
      if (!_rolesDirty) {
        _roleCategories = List.of(book.roleCategories);
      }
      // 用户本次动过封面就不覆盖草稿；没动过则跟随最新（云同步落地）。
      if (!_coverDirty) _coverImg = book.bookCoverImg;
    } finally {
      _syncing = false;
    }
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.isEmpty) {
      context.notices.warning('书籍标题不能为空');
      return;
    }
    // 清掉 / 换掉的旧封面（保存成功后再回收它的图片）。
    final previousCover = _book?.bookCoverImg;
    setState(() => _isSaving = true);
    final book = Book(
      uuid: _book?.uuid ?? '',
      title: title,
      category: _category.text.trim(),
      baseSetting: _baseSetting.text,
      writingRequirements: _writingRequirements.text,
      writingStyle: _writingStyle.text,
      globalPrePrompt: _globalPrePrompt.text,
      globalPostPrompt: _globalPostPrompt.text,
      historyRounds: _historyRounds,
      // 档位来自模型（库内脏数据已在 Book.fromMap 收敛为 0），保存即自愈库内值。
      memorySummaryRounds: _memorySummaryRounds,
      roleHierarchy:
          Constants.joinRoleHierarchy(_roleCategories.map((c) => c.name).toList()),
      roleCategories: List.of(_roleCategories),
      bookCoverImg: _coverImg,
    );

    final provider = context.read<BookProvider>();
    final ok = _isCreate
        ? await provider.createBook(book)
        : await provider.updateBook(book);

    if (!mounted) return;
    setState(() => _isSaving = false);
    if (ok) {
      final errors = <String>[];
      // 新建书籍：将草稿阶段配置的世界书条目与 Mod 一并落库到新书。
      if (_isCreate) {
        await _commitDraftData(errors);
        if (!mounted) return;
      }
      // 封面被清除 / 换掉：旧图若全库都没人再用，顺手删掉（本机 + 云端墓碑）。
      await _releaseCoverImageIfUnused(previousCover);
      if (!mounted) return;
      Navigator.of(context).pop(true);
      if (errors.isNotEmpty) {
        context.notices.error(
          '部分数据保存失败：${errors.join('；')}',
          copyable: true,
        );
      }
    } else {
      context.notices.error('保存失败：${provider.error ?? '未知错误'}');
    }
  }

  /// 回收「被清掉 / 换掉」的旧封面图片。
  ///
  /// 只有**全库都没人引用**时才删（别的书的封面、任何一代的剧情附图都算引用）；
  /// 删除走 [ImageDeletionService]：本机文件 + 删除墓碑一起处理，否则下次图片
  /// 同步会把云端那份又拉回来。
  ///
  /// 一切异常都按「不删」处理：宁可留一张孤儿图，也不能误删别处在用的图。
  Future<void> _releaseCoverImageIfUnused(String? previousCover) async {
    final current = _coverImg;
    if (previousCover == null ||
        previousCover.isEmpty ||
        previousCover == current) {
      return;
    }
    // 跨 await 前先取好依赖。
    final books = context.read<BookProvider>();
    final deletion = context.read<ImageDeletionService?>();
    final cloud = context.read<CloudSyncProvider?>();
    if (deletion == null) return;
    bool referenced;
    try {
      referenced = await books.isImageReferenced(previousCover);
    } catch (_) {
      return;
    }
    if (referenced) return;
    try {
      await deletion.delete(previousCover);
    } catch (_) {
      return;
    }
    // 图片平面尽快收敛（删除墓碑在上一行已写入）。
    cloud?.triggerSync(kind: SyncKind.images);
  }

  /// 新建书籍成功后，将草稿阶段配置的世界书条目与 Mod 配置落库到新书。
  Future<void> _commitDraftData(List<String> errors) async {
    // 所有 Provider 在首个 await 之前获取，避免跨异步间隙使用 context。
    final bookUuid = context.read<BookProvider>().currentBook?.uuid ?? '';
    final wbProvider = context.read<WorldBookProvider>();
    final modProvider = context.read<ModProvider>();
    if (bookUuid.isEmpty) return;

    // 世界书条目（逐条插入）。
    if (_draftWorldBookEntries.isNotEmpty) {
      await wbProvider.loadEntries(bookUuid);
      for (final entry in _draftWorldBookEntries) {
        final ok = await wbProvider.addEntry(
          keyword: entry.keyword,
          content: entry.content,
          isActive: entry.isActive,
        );
        if (!ok) {
          errors.add('世界书条目「${entry.keyword}」保存失败');
          break;
        }
      }
    }

    // Mod 配置（整体替换，草稿期占位的空 uuid 补成新书 uuid）。
    if (_draftModConfigs.isNotEmpty) {
      final ok = await modProvider.saveBookModConfigs(
        bookUuid,
        _draftModConfigs
            .map((c) => c.copyWith(bookUuid: bookUuid))
            .toList(),
      );
      if (!ok) {
        errors.add('Mod 配置保存失败');
      }
    }
  }

  /// 导入封面：选图 → 裁剪成 2:3 → 按内容哈希落盘（`img/<sha256>.png`）。
  ///
  /// 只改页面草稿（预览立刻更新），真正写库在点「保存」时；因此中途关掉设置页
  /// 只会留下一个孤儿图片文件（图片库是内容寻址 + 刻意不做引用回收）。
  Future<void> _importCover() async {
    if (_importingCover) return;
    final notices = context.notices;
    setState(() => _importingCover = true);
    try {
      final relPath = await _coverService.importCover(context);
      if (relPath == null || relPath.isEmpty || !mounted) return;
      setState(() {
        _coverImg = relPath;
        _coverDirty = true;
      });
    } on ImageFormatException catch (e) {
      notices.warning(e.message);
    } on BookCoverImportException catch (e) {
      notices.warning(e.message);
    } catch (e) {
      notices.error('封面导入失败：$e', copyable: true);
    } finally {
      if (mounted) setState(() => _importingCover = false);
    }
  }

  /// 移除封面（只改草稿；保存后库里这一列才变 NULL，首页回到默认封面）。
  void _removeCover() {
    setState(() {
      _coverImg = null;
      _coverDirty = true;
    });
  }

  /// 概览页顶部的封面区块：左边 2:3 预览，右边说明与操作按钮。
  Widget _buildCoverCard(BuildContext context) {
    final colors = context.narrColors;
    final cover = _coverImg;
    final hasCover = cover != null && cover.isNotEmpty;
    return SettingsCard(
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          BookCoverImage(
            key: const ValueKey('book_settings_cover_preview'),
            relPath: cover,
            width: 96,
            radius: 10,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '书籍封面',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '2:3 比例，首页方格与列表都会用它；未设置时首页显示「默认封面」。',
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.4,
                    color: colors.textSecondary,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    FilledButton.tonalIcon(
                      key: const ValueKey('book_settings_cover_import'),
                      onPressed: _importingCover ? null : _importCover,
                      icon: Icon(
                        hasCover
                            ? Icons.swap_horiz
                            : Icons.add_photo_alternate_outlined,
                        size: 18,
                      ),
                      label: Text(
                        _importingCover
                            ? '处理中…'
                            : (hasCover ? '更换封面' : '导入封面'),
                      ),
                    ),
                    if (hasCover)
                      TextButton.icon(
                        key: const ValueKey('book_settings_cover_remove'),
                        onPressed: _importingCover ? null : _removeCover,
                        icon: const Icon(Icons.delete_outline, size: 18),
                        label: const Text('清除封面'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.book != null;
    return SettingsShell(
      title: isEdit ? '书籍设置' : '新建书籍',
      icon: Icons.book_outlined,
      navItems: [
        const SettingsNavItem(icon: Icons.menu_book_outlined, label: '书籍概览'),
        const SettingsNavItem(icon: Icons.category_outlined, label: '角色类别与描述格式'),
        const SettingsNavItem(icon: Icons.public_outlined, label: '基础设定'),
        const SettingsNavItem(icon: Icons.menu_book_outlined, label: '世界书'),
        const SettingsNavItem(icon: Icons.format_quote_outlined, label: '文笔参考段落'),
        const SettingsNavItem(icon: Icons.extension_outlined, label: 'Mod 管理'),
        // 新建态还没有任何代，不显示纯维护性质的「其它设置」。
        if (isEdit)
          const SettingsNavItem(icon: Icons.tune_outlined, label: '其它设置'),
      ],
      actions: [
        FilledButton.icon(
          onPressed: _isSaving ? null : _save,
          icon: const Icon(Icons.save_outlined, size: 18),
          label: Text(_isSaving ? '保存中…' : '保存'),
        ),
        const SizedBox(width: 4),
      ],
      contentBuilder: (context, index) {
        switch (index) {
          case 0:
            return _buildOverview(context);
          case 1:
            return _buildRoleCategories(context);
          case 2:
            return _buildBaseSetting(context);
          case 3:
            return _panelPage(
              WorldBookPanel(
                bookUuid: widget.book?.uuid,
                pendingEntries: _draftWorldBookEntries,
                onPendingChanged: (entries) => _draftWorldBookEntries = entries,
              ),
            );
          case 4:
            return _buildWritingStyle(context);
          case 6:
            // 编辑态才有的维护页；新建态导航项不会出现（防御性兜底空 uuid）。
            return BookOtherSettingsPanel(
              bookUuid: widget.book?.uuid ?? '',
            );
          default:
            return _panelPage(
              BookModPanel(
                bookUuid: widget.book?.uuid,
                pendingConfigs:
                    _draftModConfigs.isEmpty ? null : _draftModConfigs,
                onPendingChanged: (configs) => _draftModConfigs = configs,
              ),
            );
        }
      },
    );
  }

  /// 面板页（世界书 / Mod 管理）：面板自带标题与内容，这里只补统一的输入提示。
  Widget _panelPage(Widget child) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PromptInputHint(),
        const SizedBox(height: 12),
        child,
      ],
    );
  }

  Widget _sectionHeader(String title, String subtitle) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsPageHeader(title: title, description: subtitle),
        // 各页统一提示：本页填写的内容会注入提示词，避免使用 #/##。
        const PromptInputHint(),
        const SizedBox(height: 20),
      ],
    );
  }

  /// 多行文本输入（统一使用 SettingsTextField，支持 MarkdownEditingController）。
  Widget _multiline(
    TextEditingController controller,
    String label, {
    String hint = '',
  }) {
    return SettingsTextField(
      controller: controller,
      label: label,
      hint: hint.isEmpty ? null : hint,
      minLines: 4,
      maxLines: null,
    );
  }

  /// 书籍概览：封面、书名、分类、文笔要求描述、历史轮次数、全局前后置词。
  Widget _buildOverview(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionHeader(
          '书籍概览',
          '书籍基本信息与对话行为配置。',
        ),
        _buildCoverCard(context),
        const SizedBox(height: 16),
        SettingsTextField(
          controller: _title,
          label: '书籍标题 *',
          hint: '如：玄幻后宫',
        ),
        const SizedBox(height: 12),
        SettingsTextField(
          controller: _category,
          label: '书籍总类别',
          hint: '如：玄幻、都市、悬疑',
        ),
        const SizedBox(height: 8),
        UuidDisplay(label: '书籍 UUID', uuid: _book?.uuid ?? ''),
        const SizedBox(height: 12),
        _multiline(
          _writingRequirements,
          '文笔要求描述',
          hint: '描述本书的写作规则与风格要求（区别于文笔参考段落）',
        ),
        const SizedBox(height: 12),
        HistoryRoundStepper(
          value: _historyRounds,
          onChanged: (v) {
            _historyRoundsDirty = true;
            setState(() => _historyRounds = v < 1 ? 1 : v);
          },
        ),
        const SizedBox(height: 12),
        MemorySummaryRoundSelector(
          value: _memorySummaryRounds,
          onChanged: (v) {
            _memorySummaryRoundsDirty = true;
            setState(() => _memorySummaryRounds = v);
          },
        ),
        const SizedBox(height: 12),
        _multiline(_globalPrePrompt, '全局前置词'),
        const SizedBox(height: 12),
        _multiline(_globalPostPrompt, '全局后置词'),
      ],
    );
  }

  /// 角色类别与描述格式。
  Widget _buildRoleCategories(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionHeader(
          '角色类别与描述格式',
          '定义角色分类及其属性描述模板，可拖拽排序、增删。',
        ),
        DraggableRoleList(
          initialCategories: _roleCategories,
          onChanged: (categories) {
            _rolesDirty = true;
            _roleCategories = List.of(categories);
          },
        ),
      ],
    );
  }

  /// 基础设定。
  Widget _buildBaseSetting(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionHeader(
          '基础设定',
          '书籍的世界观与不变设定，AI 将在每轮创作中遵循。',
        ),
        _multiline(_baseSetting, '基础设定（不会变更）'),
      ],
    );
  }

  /// 文笔参考段落。
  Widget _buildWritingStyle(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionHeader(
          '文笔参考段落',
          '风格范例文本，仅注入系统提示词（与「文笔要求描述」不同）。',
        ),
        _multiline(_writingStyle, '文笔参考段落'),
      ],
    );
  }
}
