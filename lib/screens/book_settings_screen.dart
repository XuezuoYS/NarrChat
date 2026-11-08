import 'dart:async';

import 'package:flutter/foundation.dart';
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
import '../widgets/book_settings_exit_dialog.dart';
import '../widgets/draggable_role_list.dart';
import '../widgets/history_round_stepper.dart';
import '../widgets/load_error_hint.dart';
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
///
/// 保存语义：整页所有设置（文本 / 轮次数 / 角色类别 / 封面 / 世界书 / Mod）
/// 都是**页面草稿**，只有点顶栏「保存」（或退出弹窗的「保存并退出设置」）才
/// 统一落库：先写 book_meta（刷新 updated_at），再整体提交世界书与启用 Mod，
/// 最后只触发一次云同步。顶栏在草稿与已保存内容不一致时显示「存在变更未保存」，
/// 此时关闭 / 返回会弹确认框。
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
        builder: (_) =>
            BookSettingsScreen(book: book, coverService: coverService),
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

  /// 世界书草稿（编辑态打开时从库加载；新建态从空开始）。
  List<WorldBookEntry> _worldBookEntries = [];

  /// 世界书「已保存」基线：仅用于脏判定，不参与展示。
  List<WorldBookEntry> _worldBookBaseline = [];
  bool _worldBookDirty = false;

  /// Mod 草稿（启用在前、未启用在后；只把启用项与顺序落库）。
  List<BookModConfig> _modConfigs = [];

  /// Mod 启用清单基线（按置入顺序的 UI ref），仅用于脏判定。
  List<String> _modBaselineRefs = [];
  bool _modDirty = false;

  /// 世界书 / Mod 草稿的加载状态（两个面板在就绪前显示统一的占位）。
  bool _draftsLoading = false;
  bool _draftsReady = false;
  bool _worldBookLoadFailed = false;
  bool _modLoadFailed = false;
  String _worldBookLoadError = '';
  String _modLoadError = '';

  /// 「存在变更未保存」的缓存：只在真假翻转时刷新界面，
  /// 避免每次输入都重建整页（世界书 / Mod 列表也在同一棵树里）。
  bool _hasUnsavedChanges = false;

  /// 退出确认弹窗是否已打开（防快速连点重复弹出）。
  bool _exitDialogOpen = false;

  @override
  void initState() {
    super.initState();
    _book = widget.book == null ? null : _resolveFresh(widget.book!);
    final b = _book;
    _title = TextEditingController(text: b?.title ?? '');
    _category = TextEditingController(text: b?.category ?? '');
    _writingRequirements = MarkdownEditingController(
      text: b?.writingRequirements ?? '',
    );
    _baseSetting = MarkdownEditingController(text: b?.baseSetting ?? '');
    _writingStyle = MarkdownEditingController(text: b?.writingStyle ?? '');
    _globalPrePrompt = MarkdownEditingController(
      text: b?.globalPrePrompt ?? '',
    );
    _globalPostPrompt = MarkdownEditingController(
      text: b?.globalPostPrompt ?? '',
    );
    _historyRounds = (b?.historyRounds ?? 1) < 1 ? 1 : (b?.historyRounds ?? 1);
    // 模型已把越界档位收敛为 0（见 Book.memorySummaryRounds）。
    _memorySummaryRounds = b?.memorySummaryRounds ?? 0;
    _roleCategories = List.of(
      b?.roleCategories ?? Constants.defaultRoleCategories,
    );
    _coverImg = b?.bookCoverImg;
    // 新建态没有需要从库加载的世界书 / Mod 草稿。
    if (_isCreate) {
      _draftsReady = true;
    }
    // 打开书籍设置即触发一次静默同步：另一台设备刚改过的书籍设置就近拉到本地
    // （编辑态打开时展示最新值；已无空闲轮询，此处是编辑前唯一的拉取点）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Provider.of<CloudSyncProvider?>(
        context,
        listen: false,
      )?.triggerSync(silent: true);
      if (!_isCreate) unawaited(_loadDrafts());
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
        _syncDirtyState();
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
    _syncDirtyState();
    // 未保存的世界书 / Mod 草稿不被远端冲掉；未编辑则跟随最新落库值。
    if (!_isSaving) unawaited(_reloadDraftsAfterExternalChange());
  }

  /// 把 [book] 的最新字段同步到编辑控件；跳过用户已编辑过的字段。
  void _applyBookToFields(Book book) {
    _syncing = true;
    try {
      if (!_dirtyControllers.contains(_title)) {
        _title.text = book.title;
      }
      if (!_dirtyControllers.contains(_category)) {
        _category.text = book.category;
      }
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

  // ---------- 草稿加载 -------------------------------------------------------

  /// 编辑态首次加载世界书 / Mod 草稿（也用于读取失败后的重试）。
  Future<void> _loadDrafts() async {
    final uuid = _book?.uuid ?? '';
    if (uuid.isEmpty) {
      if (!mounted) return;
      setState(() {
        _draftsReady = true;
        _draftsLoading = false;
      });
      return;
    }
    setState(() => _draftsLoading = true);
    final worldBook = context.read<WorldBookProvider>();
    final mods = context.read<ModProvider>();
    await worldBook.loadEntries(uuid);
    final worldBookError = worldBook.error;
    final entries = worldBookError == null
        ? List.of(worldBook.entries)
        : const <WorldBookEntry>[];
    final configs = await mods.getBookModConfigs(uuid);
    if (!mounted) return;
    setState(() {
      _draftsLoading = false;
      _draftsReady = true;
      _worldBookLoadFailed = worldBookError != null;
      _worldBookLoadError = worldBookError ?? '';
      if (worldBookError == null) {
        _worldBookEntries = entries;
        _worldBookBaseline = List.of(entries);
        _worldBookDirty = false;
      }
      _modLoadFailed = configs == null;
      _modLoadError = configs == null ? (mods.error ?? '未知错误') : '';
      if (configs != null) {
        _modConfigs = List.of(configs);
        _modBaselineRefs = _enabledRefsOf(configs);
        _modDirty = false;
      }
    });
    _syncDirtyState();
  }

  /// 云同步落地后刷新未编辑的世界书 / Mod 草稿（已编辑的保留用户草稿）。
  Future<void> _reloadDraftsAfterExternalChange() async {
    if (_isCreate || !_draftsReady || _draftsLoading) return;
    final uuid = _book?.uuid ?? '';
    if (uuid.isEmpty) return;
    final worldBook = context.read<WorldBookProvider>();
    final mods = context.read<ModProvider>();
    await worldBook.loadEntries(uuid);
    final worldBookError = worldBook.error;
    final entries = worldBookError == null ? List.of(worldBook.entries) : null;
    final configs = await mods.getBookModConfigs(uuid);
    if (!mounted) return;
    setState(() {
      if (entries != null && !_worldBookDirty) {
        _worldBookLoadFailed = false;
        _worldBookLoadError = '';
        _worldBookEntries = entries;
        _worldBookBaseline = List.of(entries);
      }
      if (configs != null && !_modDirty) {
        _modLoadFailed = false;
        _modLoadError = '';
        _modConfigs = List.of(configs);
        _modBaselineRefs = _enabledRefsOf(configs);
      }
    });
    _syncDirtyState();
  }

  // ---------- 脏判定 ---------------------------------------------------------

  /// 草稿与「已保存内容」逐项比较；任一不同即视为存在未保存变更。
  ///
  /// 文本 / 轮次数 / 角色类别 / 封面直接与最新 [Book] 比；世界书 / Mod 与
  /// 各自加载时的基线比（这样“改了又改回去”不会误报）。
  bool _computeDirty() {
    final base = _book;
    if (_title.text != (base?.title ?? '') ||
        _category.text != (base?.category ?? '') ||
        _writingRequirements.text != (base?.writingRequirements ?? '') ||
        _baseSetting.text != (base?.baseSetting ?? '') ||
        _writingStyle.text != (base?.writingStyle ?? '') ||
        _globalPrePrompt.text != (base?.globalPrePrompt ?? '') ||
        _globalPostPrompt.text != (base?.globalPostPrompt ?? '')) {
      return true;
    }
    final baselineHistory = base == null || base.historyRounds < 1
        ? 1
        : base.historyRounds;
    if (_historyRounds != baselineHistory) return true;
    if (_memorySummaryRounds != (base?.memorySummaryRounds ?? 0)) return true;
    final baselineRoles =
        base?.roleCategories ?? Constants.defaultRoleCategories;
    if (!listEquals(_roleCategories, baselineRoles)) return true;
    if (_coverImg != base?.bookCoverImg) return true;
    return _worldBookDirty || _modDirty;
  }

  /// 重新计算并（仅在真假翻转时）刷新顶栏提示。
  void _syncDirtyState() {
    if (!mounted) return;
    final dirty = _computeDirty();
    if (dirty == _hasUnsavedChanges) return;
    setState(() => _hasUnsavedChanges = dirty);
  }

  /// 世界书草稿变化。
  void _onWorldBookChanged(List<WorldBookEntry> entries) {
    setState(() {
      _worldBookEntries = List.of(entries);
      _worldBookDirty = !WorldBookEntry.sameList(_worldBookBaseline, entries);
    });
    _syncDirtyState();
  }

  /// Mod 草稿变化。
  void _onModChanged(List<BookModConfig> configs) {
    setState(() {
      _modConfigs = List.of(configs);
      _modDirty = !listEquals(_enabledRefsOf(configs), _modBaselineRefs);
    });
    _syncDirtyState();
  }

  /// 草稿里**会落库**的 Mod 启用清单（按置入顺序的 UI ref）。
  static List<String> _enabledRefsOf(List<BookModConfig> configs) {
    final sorted = List.of(configs)
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return [
      for (final config in sorted)
        if (config.isEnabled) config.ref,
    ];
  }

  // ---------- 保存 -----------------------------------------------------------

  /// 保存全部草稿并退出设置页。
  ///
  /// 顺序：book_meta（刷新 updated_at）→ 世界书 → 启用 Mod → 回收旧封面
  /// → 触发**一次**云同步 → 退出。任一步失败都会提示；book_meta 失败则留在页内。
  Future<void> _save() async {
    if (_isSaving) return;
    final title = _title.text.trim();
    if (title.isEmpty) {
      context.notices.warning('书籍标题不能为空');
      return;
    }
    // 清掉 / 换掉的旧封面（保存成功后再回收它的图片）。
    final previousCover = _book?.bookCoverImg;
    // 所有依赖在首个 await 之前取好，避免跨异步间隙使用 context。
    final provider = context.read<BookProvider>();
    final worldBook = context.read<WorldBookProvider>();
    final mods = context.read<ModProvider>();
    final cloud = context.read<CloudSyncProvider?>();
    final notices = context.notices;

    setState(() => _isSaving = true);
    var ok = false;
    final errors = <String>[];
    try {
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
        roleHierarchy: Constants.joinRoleHierarchy(
          _roleCategories.map((c) => c.name).toList(),
        ),
        roleCategories: List.of(_roleCategories),
        bookCoverImg: _coverImg,
      );

      ok = _isCreate
          ? await provider.createBook(book, triggerSync: false)
          : await provider.updateBook(book, triggerSync: false);
      if (ok) {
        final bookUuid = _isCreate
            ? (provider.currentBook?.uuid ?? '')
            : book.uuid;
        if (bookUuid.isNotEmpty) {
          errors.addAll(
            await _commitDrafts(bookUuid, worldBook: worldBook, mods: mods),
          );
        }
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
    if (!mounted) return;
    if (!ok) {
      notices.error('保存失败：${provider.error ?? '未知错误'}');
      return;
    }
    // 封面被清除 / 换掉：旧图若全库都没人再用，顺手删掉（本机 + 云端墓碑）。
    await _releaseCoverImageIfUnused(previousCover);
    if (!mounted) return;
    // 所有数据写完后只触发一次：设置页里改多少项，云端都只多这一代。
    cloud?.triggerSync();
    Navigator.of(context).pop(true);
    if (errors.isNotEmpty) {
      notices.error('部分数据保存失败：${errors.join('；')}', copyable: true);
    }
  }

  /// 提交世界书与启用 Mod 草稿（只在有改动 / 新建草稿非空时写库）。
  Future<List<String>> _commitDrafts(
    String bookUuid, {
    required WorldBookProvider worldBook,
    required ModProvider mods,
  }) async {
    final errors = <String>[];

    final saveWorldBook =
        (_isCreate && _worldBookEntries.isNotEmpty) || _worldBookDirty;
    if (saveWorldBook) {
      final ok = await worldBook.saveEntries(
        bookUuid,
        _worldBookEntries,
        triggerSync: false,
      );
      if (!ok) {
        errors.add('世界书保存失败：${worldBook.error ?? '未知错误'}');
      }
    }

    final saveMods = (_isCreate && _modConfigs.isNotEmpty) || _modDirty;
    if (saveMods) {
      final ok = await mods.saveBookModConfigs(
        bookUuid,
        _modConfigs,
        triggerSync: false,
      );
      if (!ok) {
        errors.add('Mod 配置保存失败：${mods.error ?? '未知错误'}');
      }
    }

    return errors;
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
      _syncDirtyState();
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
    _syncDirtyState();
  }

  // ---------- 退出 -----------------------------------------------------------

  /// 关闭 / 返回的统一入口：有未保存变更时先确认。
  Future<void> _handleExit() async {
    if (_isSaving || _exitDialogOpen) return;
    if (!_hasUnsavedChanges) {
      Navigator.of(context).pop();
      return;
    }
    _exitDialogOpen = true;
    final choice = await showBookSettingsExitDialog(context);
    _exitDialogOpen = false;
    if (!mounted) return;
    switch (choice) {
      case BookSettingsExitChoice.saveAndExit:
        await _save();
      case BookSettingsExitChoice.discard:
        Navigator.of(context).pop();
      case BookSettingsExitChoice.continueEditing:
      case null:
        // 取消退出（含弹窗内系统返回）：只关弹窗，留在设置页。
        break;
    }
  }

  // ---------- 构建 -----------------------------------------------------------

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
                        _importingCover ? '处理中…' : (hasCover ? '更换封面' : '导入封面'),
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

  /// 顶栏「存在变更未保存」提示（保存按钮左侧）。
  ///
  /// 窄屏（手机宽度）顶栏空间有限，退化为「未保存」小字 + 提示气泡；
  /// 宽屏显示完整文案。
  Widget _buildUnsavedHint(BuildContext context) {
    final color = context.narrColors.warning;
    final compact = MediaQuery.sizeOf(context).width < 600;
    return Tooltip(
      message: '存在变更未保存',
      child: Padding(
        padding: const EdgeInsets.only(left: 8, right: 10),
        child: Row(
          key: const ValueKey('book_settings_unsaved_hint'),
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
            Text(
              compact ? '未保存' : '存在变更未保存',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.book != null;
    return PopScope(
      // 拦截系统返回键与顶栏自动返回箭头：与关闭按钮共用「未保存」确认逻辑。
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _handleExit();
      },
      child: SettingsShell(
        title: isEdit ? '书籍设置' : '新建书籍',
        icon: Icons.book_outlined,
        navItems: [
          const SettingsNavItem(icon: Icons.menu_book_outlined, label: '书籍概览'),
          const SettingsNavItem(
            icon: Icons.category_outlined,
            label: '角色类别与描述格式',
          ),
          const SettingsNavItem(icon: Icons.public_outlined, label: '基础设定'),
          const SettingsNavItem(icon: Icons.menu_book_outlined, label: '世界书'),
          const SettingsNavItem(
            icon: Icons.format_quote_outlined,
            label: '文笔参考段落',
          ),
          const SettingsNavItem(
            icon: Icons.extension_outlined,
            label: 'Mod 管理',
          ),
          // 新建态还没有任何代，不显示纯维护性质的「其它设置」。
          if (isEdit)
            const SettingsNavItem(icon: Icons.tune_outlined, label: '其它设置'),
        ],
        actions: [
          if (_hasUnsavedChanges) _buildUnsavedHint(context),
          FilledButton.icon(
            onPressed: _isSaving ? null : _save,
            icon: const Icon(Icons.save_outlined, size: 18),
            label: Text(_isSaving ? '保存中…' : '保存'),
          ),
          const SizedBox(width: 4),
        ],
        onClose: _handleExit,
        contentBuilder: (context, index) {
          switch (index) {
            case 0:
              return _buildOverview(context);
            case 1:
              return _buildRoleCategories(context);
            case 2:
              return _buildBaseSetting(context);
            case 3:
              return _panelPage(_buildWorldBookPage());
            case 4:
              return _buildWritingStyle(context);
            case 6:
              // 编辑态才有的维护页；新建态导航项不会出现（防御性兜底空 uuid）。
              return BookOtherSettingsPanel(bookUuid: widget.book?.uuid ?? '');
            default:
              return _panelPage(_buildModPage());
          }
        },
      ),
    );
  }

  /// 世界书页：加载中 / 读取失败 / 真实面板。
  Widget _buildWorldBookPage() {
    if (_draftsLoading || !_draftsReady) return _draftLoadingPlaceholder();
    if (_worldBookLoadFailed) {
      return LoadErrorHint(
        message: '世界书读取失败：$_worldBookLoadError\n请重试，或关闭设置页后再打开。',
        onRetry: _loadDrafts,
      );
    }
    return WorldBookPanel(
      entries: _worldBookEntries,
      onChanged: _onWorldBookChanged,
    );
  }

  /// Mod 页：加载中 / 读取失败 / 真实面板。
  Widget _buildModPage() {
    if (_draftsLoading || !_draftsReady) return _draftLoadingPlaceholder();
    if (_modLoadFailed) {
      return LoadErrorHint(
        message: 'Mod 配置读取失败：$_modLoadError\n请重试，或关闭设置页后再打开。',
        onRetry: _loadDrafts,
      );
    }
    return BookModPanel(
      bookUuid: widget.book?.uuid,
      initialConfigs: _modConfigs,
      onChanged: _onModChanged,
    );
  }

  Widget _draftLoadingPlaceholder() {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 40),
      child: Center(child: CircularProgressIndicator()),
    );
  }

  /// 面板页（世界书 / Mod 管理）：面板自带标题与内容，这里只补统一的输入提示。
  Widget _panelPage(Widget child) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [const PromptInputHint(), const SizedBox(height: 12), child],
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
        _sectionHeader('书籍概览', '书籍基本信息与对话行为配置。'),
        _buildCoverCard(context),
        const SizedBox(height: 16),
        SettingsTextField(controller: _title, label: '书籍标题 *', hint: '如：玄幻后宫'),
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
            _syncDirtyState();
          },
        ),
        const SizedBox(height: 12),
        MemorySummaryRoundSelector(
          value: _memorySummaryRounds,
          onChanged: (v) {
            _memorySummaryRoundsDirty = true;
            setState(() => _memorySummaryRounds = v);
            _syncDirtyState();
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
        _sectionHeader('角色类别与描述格式', '定义角色分类及其属性描述模板，可拖拽排序、增删。'),
        DraggableRoleList(
          initialCategories: _roleCategories,
          onChanged: (categories) {
            _rolesDirty = true;
            _roleCategories = List.of(categories);
            _syncDirtyState();
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
        _sectionHeader('基础设定', '书籍的世界观与不变设定，AI 将在每轮创作中遵循。'),
        _multiline(_baseSetting, '基础设定（不会变更）'),
      ],
    );
  }

  /// 文笔参考段落。
  Widget _buildWritingStyle(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionHeader('文笔参考段落', '风格范例文本，仅注入系统提示词（与「文笔要求描述」不同）。'),
        _multiline(_writingStyle, '文笔参考段落'),
      ],
    );
  }
}
