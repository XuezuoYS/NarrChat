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

  /// 新建书籍草稿模式下收集的世界书条目（保存书籍成功后统一落库）。
  List<WorldBookEntry> _draftWorldBookEntries = [];

  /// 新建书籍草稿模式下收集的 Mod 配置（保存书籍成功后统一落库）。
  List<BookModConfig> _draftModConfigs = [];

  @override
  void initState() {
    super.initState();
    final b = widget.book;
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
    // （编辑态打开时展示最新值；轮询会在 1 分钟内兜底）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Provider.of<CloudSyncProvider?>(context, listen: false)
          ?.triggerAutoSync(silent: true);
    });
  }

  @override
  void dispose() {
    _title.dispose();
    _category.dispose();
    _writingRequirements.dispose();
    _baseSetting.dispose();
    _writingStyle.dispose();
    _globalPrePrompt.dispose();
    _globalPostPrompt.dispose();
    super.dispose();
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
      id: widget.book?.id,
      uuid: widget.book?.uuid ?? '',
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
    final ok = widget.book == null
        ? await provider.createBook(book)
        : await provider.updateBook(book);

    if (!mounted) return;
    setState(() => _isSaving = false);
    if (ok) {
      final errors = <String>[];
      // 新建书籍：将草稿阶段配置的世界书条目与 Mod 一并落库到新书。
      if (widget.book == null) {
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
    final bookId = context.read<BookProvider>().currentBook?.id;
    final wbProvider = context.read<WorldBookProvider>();
    final modProvider = context.read<ModProvider>();
    if (bookId == null) return;

    // 世界书条目（逐条插入）。
    if (_draftWorldBookEntries.isNotEmpty) {
      await wbProvider.loadEntries(bookId);
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

    // Mod 配置（整体替换，bookId 由草稿占位 0 改为新书 ID）。
    if (_draftModConfigs.isNotEmpty) {
      final ok = await modProvider.saveBookModConfigs(
        bookId,
        _draftModConfigs.map((c) => c.copyWith(bookId: bookId)).toList(),
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
              bookId: widget.book?.id,
              pendingEntries: _draftWorldBookEntries,
              onPendingChanged: (entries) => _draftWorldBookEntries = entries,
            );
          case 4:
            return _buildWritingStyle(context);
          default:
            return BookModPanel(
              bookId: widget.book?.id,
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
        UuidDisplay(label: '书籍 UUID', uuid: widget.book?.uuid ?? ''),
        const SizedBox(height: 12),
        _multiline(
          _writingRequirements,
          '文笔要求描述',
          hint: '描述本书的写作规则与风格要求（区别于文笔参考段落）',
        ),
        const SizedBox(height: 12),
        HistoryRoundStepper(
          value: _historyRounds,
          onChanged: (v) => setState(() => _historyRounds = v < 1 ? 1 : v),
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
          onChanged: (categories) => _roleCategories = List.of(categories),
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
