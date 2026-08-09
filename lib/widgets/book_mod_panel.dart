import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/mod.dart';
import '../providers/mod_provider.dart';
import '../theme/app_theme.dart';
import '../utils/pinyin_sort.dart';

/// 书籍设置页的「Mod 管理」面板。
///
/// - 分为「已启用」与「未启用」两个标签（默认打开已启用）；
/// - 「已启用」：可拖动排序调整置入顺序（自上而下）；
/// - 「未启用」：按名称拼音 a~z 排序，不可拖动；
/// - 通过开关启用/禁用，改动即时保存：发送请求时，本书启用中的 Mod 将
///   按顺序自动置入前置词、后置词、系统提示词与世界书。
class BookModPanel extends StatefulWidget {
  /// 所属书籍 ID；为 null 表示新建书籍尚未保存（此时仅显示提示）。
  final int? bookId;

  const BookModPanel({super.key, this.bookId});

  @override
  State<BookModPanel> createState() => _BookModPanelState();
}

class _BookModPanelState extends State<BookModPanel> {
  /// 已启用（按置入顺序，自上而下）。
  List<BookModConfig> _enabled = [];

  /// 未启用（按名称拼音 a~z 排序）。
  List<BookModConfig> _disabled = [];

  Map<String, Mod> _modByRef = {};
  bool _loaded = false;

  /// 0 = 已启用（默认），1 = 未启用。
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    final bookId = widget.bookId;
    if (bookId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load(bookId));
    }
  }

  Future<void> _load(int bookId) async {
    final provider = context.read<ModProvider>();
    await provider.loadUserMods();
    final saved = await provider.getBookModConfigs(bookId);
    if (!mounted) return;

    final allMods = provider.allMods;
    _modByRef = {for (final mod in allMods) mod.ref: mod};
    final result = <BookModConfig>[];
    final seen = <String>{};

    // 1. 已保存的配置按置入顺序排列（引用已不存在的 Mod 则跳过）。
    final sorted = List.of(saved)
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    for (final c in sorted) {
      if (seen.contains(c.ref)) continue;
      seen.add(c.ref);
      if (_modByRef.containsKey(c.ref)) {
        result.add(c.copyWith(bookId: bookId));
      }
    }
    // 2. 尚未配置的 Mod 追加到末尾（默认禁用）。
    for (final mod in allMods) {
      final ref = mod.ref;
      if (seen.contains(ref)) continue;
      seen.add(ref);
      result.add(
        BookModConfig(
          bookId: bookId,
          presetKey: mod.presetKey,
          modId: mod.id,
          isEnabled: false,
          sortOrder: result.length,
        ),
      );
    }

    final enabled = result.where((c) => c.isEnabled).toList();
    final disabled = result.where((c) => !c.isEnabled).toList();
    _sortDisabledByPinyin(disabled);

    setState(() {
      _enabled = enabled;
      _disabled = disabled;
      _loaded = true;
    });
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

  Future<void> _save() async {
    final bookId = widget.bookId;
    if (bookId == null) return;
    final configs = <BookModConfig>[
      for (var i = 0; i < _enabled.length; i++)
        _enabled[i].copyWith(bookId: bookId, sortOrder: i, isEnabled: true),
      for (var i = 0; i < _disabled.length; i++)
        _disabled[i].copyWith(
          bookId: bookId,
          sortOrder: _enabled.length + i,
          isEnabled: false,
        ),
    ];
    final provider = context.read<ModProvider>();
    final ok = await provider.saveBookModConfigs(bookId, configs);
    if (!ok && mounted) {
      _showMessage('保存失败：${provider.error ?? '未知错误'}');
    }
  }

  /// 启用某个 Mod：从未启用移入已启用（追加到末尾）。
  void _enable(int index) {
    setState(() {
      final config = _disabled.removeAt(index);
      _enabled.add(config.copyWith(isEnabled: true));
    });
    _save();
  }

  /// 禁用某个 Mod：移入未启用（按拼音重排）。
  void _disable(int index) {
    setState(() {
      final config = _enabled.removeAt(index);
      _disabled.add(config.copyWith(isEnabled: false));
      _sortDisabledByPinyin(_disabled);
    });
    _save();
  }

  /// 已启用列表拖动排序。
  void _reorderEnabled(int oldIndex, int newIndex) {
    // 注意：onReorderItem 已自动修正 newIndex（向下移动时无需再减一）。
    setState(() {
      final item = _enabled.removeAt(oldIndex);
      _enabled.insert(newIndex, item);
    });
    _save();
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final bookId = widget.bookId;
    if (bookId == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Mod 管理',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: context.narrColors.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '启用 Mod 后自动置入前置词、后置词、系统提示词与世界书。',
            style: TextStyle(
              fontSize: 12,
              color: context.narrColors.textSecondary,
            ),
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
            decoration: BoxDecoration(
              color: context.narrColors.background,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: context.narrColors.divider),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.extension_outlined,
                  size: 28,
                  color: context.narrColors.textSecondary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '保存新建书籍后，即可在此为本书启用 Mod 并调整置入顺序。',
                    style: TextStyle(
                      fontSize: 13,
                      color: context.narrColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }

    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Mod 管理',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: context.narrColors.textPrimary,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '启用 Mod 后，发送请求时将按「已启用」列表顺序（自上而下）自动置入前置词、后置词、系统提示词与世界书，与手动填写效果一致；仅「已启用」支持拖动排序，「未启用」按名称拼音 a~z 排列。',
          style: TextStyle(
            fontSize: 12,
            color: context.narrColors.textSecondary,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 12),
        SegmentedButton<int>(
          segments: [
            ButtonSegment(
              value: 0,
              icon: const Icon(Icons.check_circle_outline, size: 16),
              label: Text('已启用（${_enabled.length}）'),
            ),
            ButtonSegment(
              value: 1,
              icon: const Icon(Icons.remove_circle_outline, size: 16),
              label: Text('未启用（${_disabled.length}）'),
            ),
          ],
          selected: {_tab},
          onSelectionChanged: (s) => setState(() => _tab = s.first),
        ),
        const SizedBox(height: 12),
        if (!_loaded)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_tab == 0)
          _buildEnabledList(theme)
        else
          _buildDisabledList(theme),
      ],
    );
  }

  /// 「已启用」列表：支持拖动排序（自上而下）。
  Widget _buildEnabledList(ThemeData theme) {
    if (_enabled.isEmpty) {
      return _emptyHint(
        icon: Icons.check_circle_outline,
        text: '暂无启用中的 Mod\n可在「未启用」标签中打开开关以启用',
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
            for (var i = 0; i < _enabled.length; i++)
              _BookModTile(
                key: ValueKey('book_mod_enabled_${_enabled[i].ref}'),
                config: _enabled[i],
                mod: _modByRef[_enabled[i].ref],
                index: i,
                onToggle: (_) => _disable(i),
                showDragHandle: true,
              ),
          ],
        ),
      ],
    );
  }

  /// 「未启用」列表：按名称拼音 a~z 排序，不可拖动。
  Widget _buildDisabledList(ThemeData theme) {
    if (_disabled.isEmpty) {
      return _emptyHint(
        icon: Icons.remove_circle_outline,
        text: '暂无未启用的 Mod\n可在「已启用」标签中关闭开关以停用',
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
        for (var i = 0; i < _disabled.length; i++)
          _BookModTile(
            key: ValueKey('book_mod_disabled_${_disabled[i].ref}'),
            config: _disabled[i],
            mod: _modByRef[_disabled[i].ref],
            index: i,
            onToggle: (_) => _enable(i),
            showDragHandle: false,
          ),
      ],
    );
  }

  Widget _emptyHint({required IconData icon, required String text}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
      decoration: BoxDecoration(
        color: context.narrColors.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.narrColors.divider),
      ),
      child: Column(
        children: [
          Icon(
            icon,
            size: 40,
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
          const SizedBox(height: 8),
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: context.narrColors.textSecondary,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// 单条书籍 Mod 配置（启用开关 + 名称/简介 + 可选的拖动柄）。
class _BookModTile extends StatelessWidget {
  final BookModConfig config;
  final Mod? mod;
  final int index;
  final ValueChanged<bool> onToggle;

  /// 是否显示拖动柄（仅「已启用」列表显示，用于调整置入顺序）。
  final bool showDragHandle;

  const _BookModTile({
    super.key,
    required this.config,
    required this.mod,
    required this.index,
    required this.onToggle,
    required this.showDragHandle,
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
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: config.isEnabled
              ? theme.colorScheme.outlineVariant
              : theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: Opacity(
        opacity: config.isEnabled ? 1 : 0.6,
        // 窄屏（竖版）时拖动柄移到第二行，标题与简介独占整行，避免被挤压。
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth < 520) {
              return _buildNarrow(context, name, description, isPreset);
            }
            return _buildWide(context, theme, name, description, isPreset);
          },
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
      leading: Switch(
        value: config.isEnabled,
        onChanged: onToggle,
      ),
      title: _buildTitle(name, isPreset),
      subtitle: Text(
        description,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          color: context.narrColors.textSecondary,
        ),
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
              Switch(
                value: config.isEnabled,
                onChanged: onToggle,
              ),
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
            Align(
              alignment: Alignment.centerRight,
              child: _buildDragHandle(),
            ),
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
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: (isPreset ? const Color(0xFF7B3FE4) : NarrChatTheme.primary)
                .withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            isPreset ? '预置' : '自定义',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: isPreset ? const Color(0xFF7B3FE4) : NarrChatTheme.primary,
            ),
          ),
        ),
      ],
    );
  }

  /// 拖动排序手柄。
  Widget _buildDragHandle() {
    return ReorderableDragStartListener(
      index: index,
      child: const Padding(
        padding: EdgeInsets.all(4),
        child: Icon(Icons.drag_handle, size: 20),
      ),
    );
  }
}
