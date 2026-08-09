import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/mod.dart';
import '../providers/mod_provider.dart';
import '../theme/app_theme.dart';

/// 全局设置页的「Mod 管理」面板。
///
/// - 预置 Mod：仅可查看，不可修改；
/// - 我的 Mod：可创建、编辑、删除、导出（JSON 文本）与导入。
///
/// Mod 的名称与简介仅用于辨识，不会发送给 AI；实际内容由前置词、后置词、
/// 系统提示词与世界书四段组成，在书籍启用后自动置入对应提示词位置。
class ModManagementPanel extends StatefulWidget {
  const ModManagementPanel({super.key});

  @override
  State<ModManagementPanel> createState() => _ModManagementPanelState();
}

class _ModManagementPanelState extends State<ModManagementPanel> {
  // 默认打开「我的 Mod」（自定义）选项卡，1 = 我的 Mod，0 = 预置 Mod。
  int _tab = 1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ModProvider>().loadUserMods();
    });
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// 查看（只读）对话框，预置与自定义共用。
  Future<void> _viewMod(Mod mod) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _ModDetailDialog(mod: mod, readOnly: true),
    );
  }

  /// 新建 / 编辑对话框。
  Future<void> _editMod({Mod? mod}) async {
    final isEdit = mod != null;
    final result = await showDialog<_ModFormData>(
      context: context,
      builder: (_) => _ModDetailDialog(mod: mod, readOnly: false),
    );
    if (result == null || !mounted) return;
    final provider = context.read<ModProvider>();
    final ok = isEdit
        ? await provider.updateMod(
            mod.copyWith(
              name: result.name,
              description: result.description,
              prePrompt: result.prePrompt,
              postPrompt: result.postPrompt,
              systemPrompt: result.systemPrompt,
              worldBookEntries: result.worldBookEntries,
            ),
          )
        : await provider.addMod(
            name: result.name,
            description: result.description,
            prePrompt: result.prePrompt,
            postPrompt: result.postPrompt,
            systemPrompt: result.systemPrompt,
            worldBookEntries: result.worldBookEntries,
          );
    if (!mounted) return;
    if (ok) {
      _showMessage(isEdit ? '已保存 Mod' : '已创建 Mod');
    } else {
      _showMessage('操作失败：${provider.error ?? '未知错误'}');
    }
  }

  Future<void> _deleteMod(Mod mod) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除 Mod'),
        content: Text('确定删除自定义 Mod「${mod.name}」吗？\n引用该 Mod 的书籍将不再注入其内容。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final provider = context.read<ModProvider>();
    final ok = await provider.deleteMod(mod.id!);
    if (!mounted) return;
    _showMessage(ok ? '已删除' : '删除失败：${provider.error ?? '未知错误'}');
  }

  /// 导出为 JSON 文本（可复制分享）。
  Future<void> _exportMod(Mod mod) async {
    final jsonText = const JsonEncoder.withIndent('  ').convert(mod.toJson());
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导出 Mod（JSON）'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '复制以下 JSON 文本即可分享或导入到其他设备：',
                style: TextStyle(fontSize: 12, color: NarrChatTheme.textSecondary),
              ),
              const SizedBox(height: 10),
              Container(
                constraints: const BoxConstraints(maxHeight: 320),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF7F7F8),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: NarrChatTheme.divider),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    jsonText,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('复制'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: jsonText));
              if (ctx.mounted) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(content: Text('已复制到剪贴板')),
                );
                Navigator.of(ctx).pop();
              }
            },
          ),
        ],
      ),
    );
  }

  /// 导入：粘贴 JSON 文本（支持单个对象或对象数组）。
  Future<void> _importMods() async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入 Mod'),
        content: SizedBox(
          width: 520,
          child: TextField(
            controller: controller,
            maxLines: 10,
            minLines: 6,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            decoration: const InputDecoration(
              hintText: '粘贴导出的 JSON 文本（支持单个对象或多个对象的数组）',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    if (text == null || text.trim().isEmpty || !mounted) return;

    dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      _showMessage('JSON 解析失败，请检查格式');
      return;
    }

    final items = <Map<String, dynamic>>[];
    if (decoded is List) {
      items.addAll(
        decoded.whereType<Map<String, dynamic>>(),
      );
    } else if (decoded is Map<String, dynamic>) {
      items.add(decoded);
    } else {
      _showMessage('JSON 格式不正确：需要对象或对象数组');
      return;
    }

    if (items.isEmpty) {
      _showMessage('未找到可导入的 Mod');
      return;
    }

    var imported = 0;
    var skipped = 0;
    final provider = context.read<ModProvider>();
    for (final item in items) {
      final mod = Mod.fromJson(item);
      if (mod == null) {
        skipped++;
        continue;
      }
      final ok = await provider.addMod(
        name: mod.name,
        description: mod.description,
        prePrompt: mod.prePrompt,
        postPrompt: mod.postPrompt,
        systemPrompt: mod.systemPrompt,
        worldBookEntries: mod.worldBookEntries,
      );
      if (ok) {
        imported++;
      } else {
        skipped++;
      }
    }
    if (!mounted) return;
    _showMessage(
      imported > 0
          ? '成功导入 $imported 个 Mod${skipped > 0 ? '，跳过 $skipped 个' : ''}'
          : '导入失败：${provider.error ?? '未知错误'}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<ModProvider>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Mod 管理',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: NarrChatTheme.textPrimary,
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Mod 是对前置词、后置词、系统提示词与世界书的自定义内容包。书籍启用后，发送请求时会自动置入对应位置，与手动填写效果一致；名称与简介仅用于辨识，不会发送给 AI。',
          style: TextStyle(fontSize: 12, color: NarrChatTheme.textSecondary, height: 1.5),
        ),
        const SizedBox(height: 16),
        SegmentedButton<int>(
          segments: [
            ButtonSegment(
              value: 0,
              icon: const Icon(Icons.extension_outlined, size: 16),
              label: Text('预置 Mod（${provider.presetMods.length}）'),
            ),
            ButtonSegment(
              value: 1,
              icon: const Icon(Icons.person_outline, size: 16),
              label: Text('我的 Mod（${provider.userMods.length}）'),
            ),
          ],
          selected: {_tab},
          onSelectionChanged: (s) => setState(() => _tab = s.first),
        ),
        const SizedBox(height: 12),
        if (_tab == 0)
          _buildPresetList(provider.presetMods)
        else
          _buildUserList(provider.userMods),
      ],
    );
  }

  /// 预置 Mod 列表（仅可查看）。
  Widget _buildPresetList(List<Mod> mods) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '预置 Mod 为应用内置，仅可查看、不可修改。',
          style: TextStyle(fontSize: 12, color: NarrChatTheme.textSecondary),
        ),
        const SizedBox(height: 8),
        if (mods.isEmpty)
          const _EmptyHint(text: '暂无预置 Mod')
        else
          for (final mod in mods)
            _ModTile(
              mod: mod,
              onView: () => _viewMod(mod),
            ),
      ],
    );
  }

  /// 用户自定义 Mod 列表（可编辑/导出/删除）。
  Widget _buildUserList(List<Mod> mods) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                '自定义 Mod 可查看、编辑、导出与导入。',
                style: TextStyle(fontSize: 12, color: NarrChatTheme.textSecondary),
              ),
            ),
            OutlinedButton.icon(
              onPressed: _importMods,
              icon: const Icon(Icons.file_download_outlined, size: 16),
              label: const Text('导入'),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: () => _editMod(),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('新建'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (mods.isEmpty)
          const _EmptyHint(text: '暂无自定义 Mod，点击「新建」创建，或「导入」分享来的 JSON。')
        else
          for (final mod in mods)
            _ModTile(
              mod: mod,
              onView: () => _viewMod(mod),
              onEdit: () => _editMod(mod: mod),
              onExport: () => _exportMod(mod),
              onDelete: () => _deleteMod(mod),
            ),
      ],
    );
  }
}

class _EmptyHint extends StatelessWidget {
  final String text;

  const _EmptyHint({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F7F8),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: NarrChatTheme.divider),
      ),
      child: Column(
        children: [
          Icon(Icons.extension_outlined, size: 40, color: Colors.grey.shade400),
          const SizedBox(height: 8),
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey.shade600, height: 1.5),
          ),
        ],
      ),
    );
  }
}

/// 单条 Mod 卡片。
class _ModTile extends StatelessWidget {
  final Mod mod;
  final VoidCallback onView;
  final VoidCallback? onEdit;
  final VoidCallback? onExport;
  final VoidCallback? onDelete;

  const _ModTile({
    required this.mod,
    required this.onView,
    this.onEdit,
    this.onExport,
    this.onDelete,
  });

  /// 非空内容段摘要（辅助辨识）。
  String get _fieldsSummary {
    final parts = <String>[
      if (mod.prePrompt.trim().isNotEmpty) '前置词',
      if (mod.postPrompt.trim().isNotEmpty) '后置词',
      if (mod.systemPrompt.trim().isNotEmpty) '系统提示词',
      if (mod.worldBookEntries.isNotEmpty) '世界书',
    ];
    return parts.isEmpty ? '（无内容）' : '含：${parts.join('、')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        leading: Icon(
          Icons.extension_outlined,
          color: mod.isPreset
              ? const Color(0xFF7B3FE4)
              : NarrChatTheme.primary,
        ),
        title: Row(
          children: [
            Flexible(
              child: Text(
                mod.name.isEmpty ? '（未命名）' : mod.name,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            _Badge(
              text: mod.isPreset ? '预置' : '自定义',
              color: mod.isPreset ? const Color(0xFF7B3FE4) : NarrChatTheme.primary,
            ),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (mod.description.trim().isNotEmpty)
              Text(
                mod.description.trim(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: theme.colorScheme.outline),
              ),
            Text(
              _fieldsSummary,
              style: TextStyle(
                fontSize: 11,
                color: theme.colorScheme.outline.withValues(alpha: 0.8),
              ),
            ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.visibility_outlined, size: 20),
              tooltip: '查看',
              onPressed: onView,
            ),
            if (onEdit != null)
              IconButton(
                icon: const Icon(Icons.edit_outlined, size: 20),
                tooltip: '编辑',
                onPressed: onEdit,
              ),
            if (onExport != null)
              IconButton(
                icon: const Icon(Icons.ios_share, size: 20),
                tooltip: '导出',
                onPressed: onExport,
              ),
            if (onDelete != null)
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 20),
                tooltip: '删除',
                onPressed: onDelete,
              ),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final String text;
  final Color color;

  const _Badge({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 新建/编辑/查看 Mod 对话框返回的数据。
class _ModFormData {
  final String name;
  final String description;
  final String prePrompt;
  final String postPrompt;
  final String systemPrompt;
  final List<ModWorldBookEntry> worldBookEntries;

  const _ModFormData({
    required this.name,
    required this.description,
    required this.prePrompt,
    required this.postPrompt,
    required this.systemPrompt,
    required this.worldBookEntries,
  });
}

/// Mod 详情对话框（新建 / 编辑 / 只读查看共用）。
///
/// 使用 5 个标签页：基本信息、前置词、后置词、系统提示词、世界书。
class _ModDetailDialog extends StatefulWidget {
  final Mod? mod;
  final bool readOnly;

  const _ModDetailDialog({this.mod, required this.readOnly});

  @override
  State<_ModDetailDialog> createState() => _ModDetailDialogState();
}

class _ModDetailDialogState extends State<_ModDetailDialog> {
  late final TextEditingController _name;
  late final TextEditingController _description;
  late final TextEditingController _prePrompt;
  late final TextEditingController _postPrompt;
  late final TextEditingController _systemPrompt;
  late List<ModWorldBookEntry> _worldBookEntries;

  bool get _readOnly => widget.readOnly;
  bool get _isEdit => widget.mod != null;

  @override
  void initState() {
    super.initState();
    final mod = widget.mod;
    _name = TextEditingController(text: mod?.name ?? '');
    _description = TextEditingController(text: mod?.description ?? '');
    _prePrompt = TextEditingController(text: mod?.prePrompt ?? '');
    _postPrompt = TextEditingController(text: mod?.postPrompt ?? '');
    _systemPrompt = TextEditingController(text: mod?.systemPrompt ?? '');
    _worldBookEntries = List.of(mod?.worldBookEntries ?? const []);
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _prePrompt.dispose();
    _postPrompt.dispose();
    _systemPrompt.dispose();
    super.dispose();
  }

  void _save() {
    if (_name.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('名称不能为空')),
      );
      return;
    }
    Navigator.of(context).pop(
      _ModFormData(
        name: _name.text.trim(),
        description: _description.text,
        prePrompt: _prePrompt.text,
        postPrompt: _postPrompt.text,
        systemPrompt: _systemPrompt.text,
        worldBookEntries: List.of(_worldBookEntries),
      ),
    );
  }

  Widget _multiline(TextEditingController controller, String hint) {
    return TextField(
      controller: controller,
      readOnly: _readOnly,
      maxLines: null,
      minLines: 6,
      keyboardType: TextInputType.multiline,
      style: const TextStyle(fontSize: 13, height: 1.5),
      decoration: InputDecoration(
        hintText: hint,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = _readOnly
        ? '查看 Mod'
        : (_isEdit ? '编辑 Mod' : '新建 Mod');
    return Dialog(
      child: Container(
        width: 600,
        height: 520,
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.extension_outlined, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: NarrChatTheme.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            DefaultTabController(
              length: 5,
              child: Expanded(
                child: Column(
                  children: [
                    const TabBar(
                      isScrollable: true,
                      tabAlignment: TabAlignment.start,
                      tabs: [
                        Tab(text: '基本信息'),
                        Tab(text: '前置词'),
                        Tab(text: '后置词'),
                        Tab(text: '系统提示词'),
                        Tab(text: '世界书'),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: TabBarView(
                        children: [
                          // 基本信息
                          SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                TextField(
                                  controller: _name,
                                  readOnly: _readOnly,
                                  decoration: const InputDecoration(
                                    labelText: '名称 *（仅用于辨识，不发送给 AI）',
                                    hintText: '如：文笔润色',
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                TextField(
                                  controller: _description,
                                  readOnly: _readOnly,
                                  maxLines: 3,
                                  minLines: 2,
                                  decoration: const InputDecoration(
                                    labelText: '简介（仅用于辨识，不发送给 AI）',
                                    hintText: '简要说明这个 Mod 的作用',
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          _multiline(_prePrompt, '发送请求时自动置入「前置词」区'),
                          _multiline(_postPrompt, '发送请求时自动置入「后置词」区'),
                          _multiline(_systemPrompt, '自动追加到 System Prompt'),
                          _ModWorldBookEditor(
                            initialEntries: _worldBookEntries,
                            readOnly: _readOnly,
                            onChanged: (entries) => _worldBookEntries = entries,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(_readOnly ? '关闭' : '取消'),
                ),
                if (!_readOnly)
                  FilledButton.icon(
                    onPressed: _save,
                    icon: const Icon(Icons.save_outlined, size: 18),
                    label: const Text('保存'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Mod 世界书条目编辑器（关键词 + 内容，与书籍世界书一致）。
///
/// - 关键词非空的条目：扫描本轮输入与最近历史轮次，命中才注入；
/// - 关键词留空的条目：恒定生效（无需命中）。
class _ModWorldBookEditor extends StatefulWidget {
  final List<ModWorldBookEntry> initialEntries;
  final bool readOnly;
  final ValueChanged<List<ModWorldBookEntry>> onChanged;

  const _ModWorldBookEditor({
    required this.initialEntries,
    required this.readOnly,
    required this.onChanged,
  });

  @override
  State<_ModWorldBookEditor> createState() => _ModWorldBookEditorState();
}

class _ModWorldBookEditorState extends State<_ModWorldBookEditor> {
  late final List<ModWorldBookEntry> _entries = List.of(widget.initialEntries);

  void _notify() {
    widget.onChanged(List.of(_entries));
  }

  Future<void> _addOrEdit({ModWorldBookEntry? entry}) async {
    final isEdit = entry != null;
    final result = await showDialog<ModWorldBookEntry>(
      context: context,
      builder: (_) => _WorldBookEntryDialog(entry: entry, readOnly: widget.readOnly),
    );
    if (result == null) return;
    setState(() {
      if (isEdit) {
        final index = _entries.indexOf(entry);
        if (index >= 0) _entries[index] = result;
      } else {
        _entries.add(result);
      }
    });
    _notify();
  }

  void _remove(ModWorldBookEntry entry) {
    setState(() => _entries.remove(entry));
    _notify();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '关键词命中后自动注入（与书籍世界书一致）；关键词留空则恒定生效。',
          style: TextStyle(fontSize: 12, color: theme.colorScheme.outline),
        ),
        const SizedBox(height: 8),
        if (!widget.readOnly)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => _addOrEdit(),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('添加条目'),
            ),
          ),
        const SizedBox(height: 4),
        if (_entries.isEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
            decoration: BoxDecoration(
              color: const Color(0xFFF7F7F8),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: NarrChatTheme.divider),
            ),
            child: Column(
              children: [
                Icon(Icons.menu_book_outlined,
                    size: 40, color: Colors.grey.shade400),
                const SizedBox(height: 8),
                Text(
                  '暂无世界书条目\n添加关键词与内容，剧情输入命中关键词时将自动注入',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey.shade600, height: 1.5),
                ),
              ],
            ),
          )
        else
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _entries.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final entry = _entries[index];
              final isConstant = entry.keywords.isEmpty;
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  isConstant ? Icons.public : Icons.manage_search,
                  size: 20,
                  color: isConstant
                      ? NarrChatTheme.primary
                      : NarrChatTheme.textSecondary,
                ),
                title: Text(
                  isConstant ? '（恒定生效）' : entry.keyword,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Text(
                  entry.content,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: theme.colorScheme.outline),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.edit_outlined, size: 20),
                      tooltip: '查看/编辑',
                      onPressed: () => _addOrEdit(entry: entry),
                    ),
                    if (!widget.readOnly)
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 20),
                        tooltip: '删除',
                        onPressed: () => _remove(entry),
                      ),
                  ],
                ),
              );
            },
          ),
      ],
    );
  }
}

/// 世界书条目（关键词 + 内容）编辑对话框。
class _WorldBookEntryDialog extends StatefulWidget {
  final ModWorldBookEntry? entry;
  final bool readOnly;

  const _WorldBookEntryDialog({this.entry, required this.readOnly});

  @override
  State<_WorldBookEntryDialog> createState() => _WorldBookEntryDialogState();
}

class _WorldBookEntryDialogState extends State<_WorldBookEntryDialog> {
  late final TextEditingController _keyword;
  late final TextEditingController _content;

  @override
  void initState() {
    super.initState();
    _keyword = TextEditingController(text: widget.entry?.keyword ?? '');
    _content = TextEditingController(text: widget.entry?.content ?? '');
  }

  @override
  void dispose() {
    _keyword.dispose();
    _content.dispose();
    super.dispose();
  }

  void _save() {
    if (_content.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('内容不能为空')),
      );
      return;
    }
    Navigator.of(context).pop(
      ModWorldBookEntry(
        keyword: _keyword.text.trim(),
        content: _content.text,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.entry != null;
    return AlertDialog(
      title: Text(
        widget.readOnly
            ? '查看世界书条目'
            : (isEdit ? '编辑世界书条目' : '添加世界书条目'),
      ),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _keyword,
              readOnly: widget.readOnly,
              decoration: const InputDecoration(
                labelText: '触发关键词',
                hintText: '多个关键词用逗号/顿号分隔；留空则恒定生效',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _content,
              readOnly: widget.readOnly,
              minLines: 4,
              maxLines: 8,
              decoration: const InputDecoration(
                labelText: '注入内容',
                hintText: '命中关键词后写入 System Prompt',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(widget.readOnly ? '关闭' : '取消'),
        ),
        if (!widget.readOnly)
          FilledButton(
            onPressed: _save,
            child: const Text('保存'),
          ),
      ],
    );
  }
}
