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
import '../theme/app_theme.dart';
import '../utils/constants.dart';
import '../utils/focus_utils.dart';
import '../widgets/book_mod_panel.dart';
import '../widgets/draggable_role_list.dart';
import '../widgets/history_round_stepper.dart';
import '../widgets/markdown_editing_controller.dart';
import '../widgets/settings_shell.dart';
import '../widgets/uuid_display.dart';
import '../widgets/world_book_panel.dart';

/// 全窗口书籍设置界面（新建 / 编辑书籍）。
///
/// 6 个子模块：
/// - 书籍概览：书名、分类、文笔要求描述（区别于文笔参考段落）、历史轮次数、全局前后置词；
/// - 角色类别与描述格式：可拖拽排序、增删、为每类设定描述格式；
/// - 基础设定：世界观等不会变更的设定；
/// - 世界书：关键词命中后自动注入 System Prompt；
/// - 文笔参考段落：风格范例文本（仅注入 system）；
/// - Mod 管理：启用/禁用 Mod 并调整置入顺序。
class BookSettingsScreen extends StatefulWidget {
  final Book? book;

  const BookSettingsScreen({super.key, this.book});

  static Future<bool?> open(BuildContext context, {Book? book}) {
    return Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => BookSettingsScreen(book: book)),
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
  late List<RoleCategory> _roleCategories;

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
    _roleCategories = List.of(
      b?.roleCategories ?? Constants.defaultRoleCategories,
    );
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
      if (!_rolesDirty) {
        _roleCategories = List.of(book.roleCategories);
      }
    } finally {
      _syncing = false;
    }
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('书籍标题不能为空')),
      );
      return;
    }
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
      roleHierarchy:
          Constants.joinRoleHierarchy(_roleCategories.map((c) => c.name).toList()),
      roleCategories: List.of(_roleCategories),
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
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
      if (errors.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('部分数据保存失败：${errors.join('；')}')),
        );
      }
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败：${provider.error ?? '未知错误'}')),
      );
    }
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

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.book != null;
    return SettingsShell(
      title: isEdit ? '书籍设置' : '新建书籍',
      icon: Icons.book_outlined,
      navItems: const [
        SettingsNavItem(icon: Icons.menu_book_outlined, label: '书籍概览'),
        SettingsNavItem(icon: Icons.category_outlined, label: '角色类别与描述格式'),
        SettingsNavItem(icon: Icons.public_outlined, label: '基础设定'),
        SettingsNavItem(icon: Icons.menu_book_outlined, label: '世界书'),
        SettingsNavItem(icon: Icons.format_quote_outlined, label: '文笔参考段落'),
        SettingsNavItem(icon: Icons.extension_outlined, label: 'Mod 管理'),
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
            return WorldBookPanel(
              bookUuid: widget.book?.uuid,
              pendingEntries: _draftWorldBookEntries,
              onPendingChanged: (entries) => _draftWorldBookEntries = entries,
            );
          case 4:
            return _buildWritingStyle(context);
          default:
            return BookModPanel(
              bookUuid: widget.book?.uuid,
              pendingConfigs: _draftModConfigs.isEmpty ? null : _draftModConfigs,
              onPendingChanged: (configs) => _draftModConfigs = configs,
            );
        }
      },
    );
  }

  Widget _sectionHeader(String title, String subtitle) {
    final colors = context.narrColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: colors.textPrimary,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: TextStyle(fontSize: 12, color: colors.textSecondary),
        ),
        const SizedBox(height: 20),
      ],
    );
  }

  Widget _multiline(TextEditingController controller, String label,
      {String hint = ''}) {
    return TextField(
      controller: controller,
      onTapOutside: unfocusOnTapOutside,
      maxLines: null,
      minLines: 4,
      keyboardType: TextInputType.multiline,
      style: const TextStyle(fontSize: 13, height: 1.4),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );
  }

  /// 书籍概览：书名、分类、文笔要求描述、历史轮次数、全局前后置词。
  Widget _buildOverview(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionHeader(
          '书籍概览',
          '书籍基本信息与对话行为配置。',
        ),
        TextField(
          controller: _title,
          onTapOutside: unfocusOnTapOutside,
          decoration: const InputDecoration(
            labelText: '书籍标题 *',
            hintText: '如：玄幻后宫',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _category,
          onTapOutside: unfocusOnTapOutside,
          decoration: const InputDecoration(
            labelText: '书籍总类别',
            hintText: '如：玄幻、都市、悬疑',
            border: OutlineInputBorder(),
            isDense: true,
          ),
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
