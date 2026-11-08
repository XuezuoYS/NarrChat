import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/mod.dart';
import '../providers/mod_provider.dart';
import '../theme/app_theme.dart';
import '../utils/pinyin_sort.dart';
import '../utils/search_utils.dart';
import 'app_empty_hint.dart';
import 'mod_detail_dialog.dart';
import 'responsive_builder.dart';
import 'settings/settings_kit.dart';
import 'type_badge.dart';

/// 书籍设置页的「Mod 管理」面板。
///
/// - 分为「已启用」与「未启用」两个标签（默认打开已启用）；
/// - 「已启用」：可拖动排序调整置入顺序（自上而下）；
/// - 「未启用」：按名称拼音 a~z 排序，不可拖动；
/// - 通过开关启用/禁用；发送请求时，本书启用中的 Mod 将按顺序自动置入
///   前置词、后置词、系统提示词与世界书；
/// - 点击条目主体（非开关、非拖动柄区域）打开【预览 mod】只读对话框。
///
/// 本面板是**纯草稿组件**：开关与拖动只改本地列表，并通过 [onChanged]
/// 回传完整配置；真正落库由书籍设置页在点「保存」时统一提交。
class BookModPanel extends StatefulWidget {
  /// 所属书籍 uuid；为 null 表示新建书籍草稿模式。
  final String? bookUuid;

  /// 父级持有的当前草稿（启用在前、未启用在后，带 `sortOrder`）。
  ///
  /// 首次加载与外部刷新时作为初始值；用户操作后由 [onChanged] 回传新快照。
  final List<BookModConfig> initialConfigs;

  /// 草稿变化回调（完整配置快照，启用在前按置入顺序）。
  final ValueChanged<List<BookModConfig>>? onChanged;

  const BookModPanel({
    super.key,
    this.bookUuid,
    this.initialConfigs = const [],
    this.onChanged,
  });

  @override
  State<BookModPanel> createState() => _BookModPanelState();
}

/// 书籍 Mod 面板的选项卡。
enum _BookModsTab { enabled, disabled }

class _BookModPanelState extends State<BookModPanel> {
  /// 已启用（按置入顺序，自上而下）。
  List<BookModConfig> _enabled = [];

  /// 未启用（按名称拼音 a~z 排序）。
  List<BookModConfig> _disabled = [];

  Map<String, Mod> _modByRef = {};
  bool _loaded = false;

  /// 最近一次回传给父级的配置签名：父级把自己的回声传回来时据此跳过重建，
  /// 只有真正的外部刷新（云同步落地等）才采纳新的初始值。
  String _lastEmittedSignature = '';

  /// 当前选项卡（默认「已启用」）。
  _BookModsTab _tab = _BookModsTab.enabled;

  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void didUpdateWidget(covariant BookModPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_loaded) return;
    if (identical(oldWidget.initialConfigs, widget.initialConfigs)) return;
    if (_signatureOf(widget.initialConfigs) == _lastEmittedSignature) return;
    setState(() => _applySaved(widget.initialConfigs));
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final provider = context.read<ModProvider>();
    await provider.loadUserMods();
    if (!mounted) return;
    _modByRef = {for (final mod in provider.allMods) mod.ref: mod};
    _applySaved(widget.initialConfigs);
    _lastEmittedSignature = _signatureOf(widget.initialConfigs);
    setState(() => _loaded = true);
  }

  /// 按父级草稿重建启用 / 未启用列表；尚未配置的 Mod 追加为未启用。
  void _applySaved(List<BookModConfig> saved) {
    final result = <BookModConfig>[];
    final seen = <String>{};

    // 1. 已保存 / 草稿的配置按置入顺序排列（引用已不存在的 Mod 则跳过）。
    final sorted = List.of(saved)
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    for (final c in sorted) {
      if (seen.contains(c.ref)) continue;
      seen.add(c.ref);
      if (_modByRef.containsKey(c.ref)) {
        result.add(c.copyWith(bookUuid: widget.bookUuid ?? ''));
      }
    }
    // 2. 尚未配置的 Mod 追加到末尾（默认禁用）。
    for (final mod in _modByRef.values) {
      final ref = mod.ref;
      if (seen.contains(ref)) continue;
      seen.add(ref);
      result.add(
        BookModConfig(
          bookUuid: widget.bookUuid ?? '',
          presetKey: mod.presetKey,
          // 预置 Mod 没有 uuid（[Mod.uuid] 为空串）：引用必须写 NULL 而非空串，
          // 否则 book_mods 的 mod_uuid 外键（FK → mods.uuid）匹配失败。
          modUuid: mod.isPreset ? null : mod.uuid,
          isEnabled: false,
          sortOrder: result.length,
        ),
      );
    }

    final enabled = result.where((c) => c.isEnabled).toList();
    final disabled = result.where((c) => !c.isEnabled).toList();
    _sortDisabledByPinyin(disabled);
    _enabled = enabled;
    _disabled = disabled;
  }

  /// 未启用列表按名称拼音 a~z 排序。
  void _sortDisabledByPinyin(List<BookModConfig> list) {
    list.sort(
      (a, b) => PinyinSort.compare(
        _modByRef[a.ref]?.name ?? '',
        _modByRef[b.ref]?.name ?? '',
      ),
    );
  }

  /// 把本地完整配置（启用在前 + 未启用在后）回传给父级。
  void _notifyChanged() {
    final bookUuid = widget.bookUuid ?? '';
    final configs = <BookModConfig>[
      for (var i = 0; i < _enabled.length; i++)
        _enabled[i].copyWith(bookUuid: bookUuid, sortOrder: i, isEnabled: true),
      for (var i = 0; i < _disabled.length; i++)
        _disabled[i].copyWith(
          bookUuid: bookUuid,
          sortOrder: _enabled.length + i,
          isEnabled: false,
        ),
    ];
    _lastEmittedSignature = _signatureOf(configs);
    widget.onChanged?.call(configs);
  }

  /// 配置签名：启用标志 + 引用 + 列表顺序（不含 bookUuid 等展示字段）。
  static String _signatureOf(List<BookModConfig> configs) =>
      configs.map((c) => '${c.isEnabled ? 1 : 0}:${c.ref}').join('|');

  /// 启用某个 Mod：从未启用移入已启用（追加到末尾）。
  void _enable(int index) {
    setState(() {
      final config = _disabled.removeAt(index);
      _enabled.add(config.copyWith(isEnabled: true));
    });
    _notifyChanged();
  }

  /// 禁用某个 Mod：移入未启用（按拼音重排）。
  void _disable(int index) {
    setState(() {
      final config = _enabled.removeAt(index);
      _disabled.add(config.copyWith(isEnabled: false));
      _sortDisabledByPinyin(_disabled);
    });
    _notifyChanged();
  }

  /// 已启用列表拖动排序。
  void _reorderEnabled(int oldIndex, int newIndex) {
    // 注意：onReorderItem 已自动修正 newIndex（向下移动时无需再减一）。
    setState(() {
      final item = _enabled.removeAt(oldIndex);
      _enabled.insert(newIndex, item);
    });
    _notifyChanged();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SettingsPageHeader(
          title: 'Mod 管理',
          description: '启用 Mod 后，发送请求时将按「已启用」列表顺序（自上而下）自动置入前置词、后置词、系统提示词与世界书，与手动填写效果一致；仅「已启用」支持拖动排序，「未启用」按名称拼音 a~z 排列。改动在点击顶栏「保存」后生效。',
        ),
        SettingsCard(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SettingsSegmented<_BookModsTab>(
                value: _tab,
                options: [
                  SettingsSegment(
                    value: _BookModsTab.enabled,
                    label: '已启用（${_enabled.length}）',
                    icon: Icons.check_circle_outline,
                  ),
                  SettingsSegment(
                    value: _BookModsTab.disabled,
                    label: '未启用（${_disabled.length}）',
                    icon: Icons.remove_circle_outline,
                  ),
                ],
                onChanged: (tab) => setState(() => _tab = tab),
              ),
              const SizedBox(height: 12),
              SettingsSearchField(
                controller: _searchController,
                hint: '搜索 Mod（名称 / 简介，空格分隔多关键词）',
                onChanged: (v) => setState(() => _searchQuery = v),
                onClear: () {
                  _searchController.clear();
                  setState(() => _searchQuery = '');
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (!_loaded)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_tab == _BookModsTab.enabled)
          _buildEnabledList()
        else
          _buildDisabledList(),
      ],
    );
  }

  /// 构建单条 Mod 条目：条目主体（非开关、非拖动柄区域）点击打开
  /// 【预览 mod】只读对话框。
  _BookModTile _buildTile({
    required Key key,
    required BookModConfig config,
    required int index,
    required ValueChanged<bool> onToggle,
    required bool showDragHandle,
  }) {
    final mod = _modByRef[config.ref];
    return _BookModTile(
      key: key,
      config: config,
      mod: mod,
      index: index,
      onToggle: onToggle,
      onPreview: mod == null ? null : () => showModPreview(context, mod),
      showDragHandle: showDragHandle,
    );
  }

  /// 「已启用」列表：支持拖动排序（自上而下）。
  Widget _buildEnabledList() {
    final keywords = splitKeywords(_searchQuery);
    final searching = keywords.isNotEmpty;
    // 只保留命中搜索的项；index 指向全量列表，确保开关/拖动操作准确对应。
    final filtered = <int>[
      for (var i = 0; i < _enabled.length; i++)
        if (modMatchesKeywords(keywords, _modByRef[_enabled[i].ref])) i,
    ];
    if (filtered.isEmpty) {
      return AppEmptyHint(
        icon: Icons.check_circle_outline,
        text: _enabled.isEmpty ? '暂无启用中的 Mod\n可在「未启用」标签中打开开关以启用' : '未找到匹配的 Mod',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '置入顺序（自上而下）：拖动右侧手柄调整',
          style: TextStyle(
            fontSize: 12,
            color: context.narrColors.textSecondary,
          ),
        ),
        const SizedBox(height: 8),
        // 不设内部滚动：与所在设置页的总滚动条一致。
        ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          onReorderItem: _reorderEnabled,
          children: [
            for (final i in filtered)
              _buildTile(
                key: ValueKey('book_mod_enabled_${_enabled[i].ref}'),
                config: _enabled[i],
                index: i,
                onToggle: (_) => _disable(i),
                // 搜索过滤时禁用拖动，避免过滤列表与全量列表索引错位。
                showDragHandle: !searching,
              ),
          ],
        ),
      ],
    );
  }

  /// 「未启用」列表：按名称拼音 a~z 排序，不可拖动。
  Widget _buildDisabledList() {
    final keywords = splitKeywords(_searchQuery);
    // 只保留命中搜索的项；index 指向全量列表，确保开关操作准确对应。
    final filtered = <int>[
      for (var i = 0; i < _disabled.length; i++)
        if (modMatchesKeywords(keywords, _modByRef[_disabled[i].ref])) i,
    ];
    if (filtered.isEmpty) {
      return AppEmptyHint(
        icon: Icons.remove_circle_outline,
        text: _disabled.isEmpty
            ? '暂无未启用的 Mod\n可在「已启用」标签中关闭开关以停用'
            : '未找到匹配的 Mod',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '按名称拼音 a~z 排序',
          style: TextStyle(
            fontSize: 12,
            color: context.narrColors.textSecondary,
          ),
        ),
        const SizedBox(height: 8),
        for (final i in filtered)
          _buildTile(
            key: ValueKey('book_mod_disabled_${_disabled[i].ref}'),
            config: _disabled[i],
            index: i,
            onToggle: (_) => _enable(i),
            showDragHandle: false,
          ),
      ],
    );
  }
}

/// 单条书籍 Mod 配置（启用开关 + 名称/简介 + 可选的拖动柄）。
class _BookModTile extends StatelessWidget {
  final BookModConfig config;
  final Mod? mod;
  final int index;
  final ValueChanged<bool> onToggle;

  /// 点击条目主体（非开关、非拖动柄区域）时回调：打开【预览 mod】只读对话框。
  final VoidCallback? onPreview;

  /// 是否显示拖动柄（仅「已启用」列表显示，用于调整置入顺序）。
  final bool showDragHandle;

  const _BookModTile({
    super.key,
    required this.config,
    required this.mod,
    required this.index,
    required this.onToggle,
    required this.showDragHandle,
    this.onPreview,
  });

  String get _name {
    if (mod != null && mod!.name.isNotEmpty) return mod!.name;
    return config.presetKey != null ? '预置 Mod' : '自定义 Mod';
  }

  String get _description {
    if (mod != null && mod!.description.trim().isNotEmpty) {
      return mod!.description.trim();
    }
    final fields = <String>[
      if (mod?.prePrompt.trim().isNotEmpty ?? false) '前置词',
      if (mod?.postPrompt.trim().isNotEmpty ?? false) '后置词',
      if (mod?.systemPrompt.trim().isNotEmpty ?? false) '系统提示词',
      if (mod?.worldBookEntries.isNotEmpty ?? false) '世界书',
    ];
    return fields.isEmpty ? '（无内容）' : '含：${fields.join('、')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = _name;
    final description = _description;
    final isPreset = config.presetKey != null;

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: config.isEnabled
            ? theme.colorScheme.surfaceContainerLow
            : Colors.transparent,
        borderRadius: BorderRadius.circular(NarrChatTheme.controlRadius),
        border: Border.all(
          color: config.isEnabled
              ? theme.colorScheme.outlineVariant
              : theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      // 条目主体可点击预览；开关与拖动柄各自处理手势，不会误触预览。
      child: Material(
        type: MaterialType.transparency,
        borderRadius: BorderRadius.circular(NarrChatTheme.controlRadius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPreview,
          child: Opacity(
            opacity: config.isEnabled ? 1 : 0.6,
            // 窄屏（竖版）时拖动柄移到第二行，标题与简介独占整行，避免被挤压。
            child: ResponsiveBuilder(
              builder: (context, isWide) {
                return isWide
                    ? _buildWide(context, theme, name, description, isPreset)
                    : _buildNarrow(context, name, description, isPreset);
              },
            ),
          ),
        ),
      ),
    );
  }

  /// 宽屏布局：开关 + 标题/简介 + 拖动柄同行。
  Widget _buildWide(
    BuildContext context,
    ThemeData theme,
    String name,
    String description,
    bool isPreset,
  ) {
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      leading: Switch(value: config.isEnabled, onChanged: onToggle),
      title: _buildTitle(name, isPreset),
      subtitle: Text(
        description,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, color: context.narrColors.textSecondary),
      ),
      trailing: showDragHandle ? _buildDragHandle() : null,
    );
  }

  /// 窄屏（竖版）布局：拖动柄移到第二行。
  Widget _buildNarrow(
    BuildContext context,
    String name,
    String description,
    bool isPreset,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        children: [
          Row(
            children: [
              Switch(value: config.isEnabled, onChanged: onToggle),
              const SizedBox(width: 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildTitle(name, isPreset),
                    const SizedBox(height: 2),
                    Text(
                      description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: context.narrColors.textSecondary,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (showDragHandle)
            Align(alignment: Alignment.centerRight, child: _buildDragHandle()),
        ],
      ),
    );
  }

  /// 标题行：名称 + 类型徽标。
  Widget _buildTitle(String name, bool isPreset) {
    return Row(
      children: [
        Flexible(
          child: Text(
            name,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 8),
        TypeBadge(
          text: isPreset ? '预置' : '自定义',
          color: isPreset ? const Color(0xFF7B3FE4) : NarrChatTheme.primary,
        ),
      ],
    );
  }

  /// 拖动排序手柄。
  ///
  /// 外层 [GestureDetector] 吸收点击（更深一级的点击识别器先赢得竞技场），
  /// 避免「轻点拖动柄」误触条目主体的预览；拖动仍由
  /// [ReorderableDragStartListener] 在指针按下时启动。
  Widget _buildDragHandle() {
    return GestureDetector(
      onTap: () {},
      child: ReorderableDragStartListener(
        index: index,
        child: const Padding(
          padding: EdgeInsets.all(4),
          child: Icon(Icons.drag_handle, size: 20),
        ),
      ),
    );
  }
}
