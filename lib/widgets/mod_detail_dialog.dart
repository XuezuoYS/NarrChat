import 'package:flutter/material.dart';

import '../models/mod.dart';
import '../theme/app_theme.dart';
import 'app_notice_overlay.dart';
import 'markdown_editing_controller.dart';
import 'prompt_input_hint.dart';
import 'settings/settings_kit.dart';
import 'uuid_display.dart';

/// 打开 Mod 详情对话框（新建 / 编辑 / 只读查看共用）。
///
/// - 只读（[readOnly] 为 true）：仅「关闭」，不可修改；
/// - 可编辑：返回 [ModFormData]，取消时返回 null。
Future<ModFormData?> showModDetailDialog(
  BuildContext context, {
  Mod? mod,
  bool readOnly = false,
}) {
  return showDialog<ModFormData>(
    context: context,
    builder: (_) => ModDetailDialog(mod: mod, readOnly: readOnly),
  );
}

/// 【预览 mod】只读查看对话框：展示名称、简介与七个注入通道的全部内容
/// （8 个面板），不可修改。
Future<void> showModPreview(BuildContext context, Mod mod) {
  return showModDetailDialog(context, mod: mod, readOnly: true);
}

/// 新建/编辑/查看 Mod 对话框返回的数据。
class ModFormData {
  final String name;
  final String description;
  final String prePrompt;
  final String postPrompt;
  final String systemMust;
  final String systemPrompt;
  final String systemSetting;
  final String systemWritingStyle;
  final List<ModWorldBookEntry> worldBookEntries;

  const ModFormData({
    required this.name,
    required this.description,
    required this.prePrompt,
    required this.postPrompt,
    required this.systemMust,
    required this.systemPrompt,
    required this.systemSetting,
    required this.systemWritingStyle,
    required this.worldBookEntries,
  });
}

/// Mod 内容面板（顺序 = `docs/mods.md` §七 的面板顺序）。
///
/// 数据库物理列序是追加的，UI 顺序以本枚举与 [_ModPanelMeta] 为准。
enum ModPanel { basic, pre, post, misc, setting, writing, must, worldBook }

/// 四个 **system 通道**面板的显示名（单一来源：对话框与两个 Mod 列表共用）。
///
/// 统一带 `System 提示词 - ` 前缀，一眼能看出这几段是往 system 里塞的；
/// 文笔那一栏用完整的「文笔要求与参考段落」（它注入的块就叫这个名字）。
const String kModPanelMiscTitle = 'System 提示词 - 杂项';
const String kModPanelSettingTitle = 'System 提示词 - 设定';
const String kModPanelWritingTitle = 'System 提示词 - 文笔要求与参考段落';
const String kModPanelMustTitle = 'System 提示词 - 强指令';

/// Mod 详情对话框（新建 / 编辑 / 只读查看共用）。
///
/// 宽屏（可用宽度 ≥720）左右分栏：左侧 8 个面板导航、右侧编辑区；
/// 窄屏整页：顶栏 + 面板下拉选择器 + 撑满的编辑区 + 底部等宽按钮。
class ModDetailDialog extends StatefulWidget {
  final Mod? mod;
  final bool readOnly;

  const ModDetailDialog({super.key, this.mod, required this.readOnly});

  @override
  State<ModDetailDialog> createState() => _ModDetailDialogState();
}

class _ModDetailDialogState extends State<ModDetailDialog> {
  late final TextEditingController _name;
  late final TextEditingController _description;
  late final MarkdownEditingController _prePrompt;
  late final MarkdownEditingController _postPrompt;
  late final MarkdownEditingController _systemMust;
  late final MarkdownEditingController _systemPrompt;
  late final MarkdownEditingController _systemSetting;
  late final MarkdownEditingController _systemWritingStyle;
  late List<ModWorldBookEntry> _worldBookEntries;

  /// 当前面板：宽度变化只换外壳，**不重建控制器**（切面板不丢草稿）。
  ModPanel _panel = ModPanel.basic;

  bool get _readOnly => widget.readOnly;
  bool get _isEdit => widget.mod != null;

  @override
  void initState() {
    super.initState();
    final mod = widget.mod;
    _name = TextEditingController(text: mod?.name ?? '');
    _description = TextEditingController(text: mod?.description ?? '');
    _prePrompt = MarkdownEditingController(text: mod?.prePrompt ?? '');
    _postPrompt = MarkdownEditingController(text: mod?.postPrompt ?? '');
    _systemMust = MarkdownEditingController(text: mod?.systemMust ?? '');
    _systemPrompt = MarkdownEditingController(text: mod?.systemPrompt ?? '');
    _systemSetting = MarkdownEditingController(text: mod?.systemSetting ?? '');
    _systemWritingStyle = MarkdownEditingController(
      text: mod?.systemWritingStyle ?? '',
    );
    _worldBookEntries = List.of(mod?.worldBookEntries ?? const []);
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _prePrompt.dispose();
    _postPrompt.dispose();
    _systemMust.dispose();
    _systemPrompt.dispose();
    _systemSetting.dispose();
    _systemWritingStyle.dispose();
    super.dispose();
  }

  void _save() {
    if (_name.text.trim().isEmpty) {
      context.notices.warning('名称不能为空');
      return;
    }
    Navigator.of(context).pop(
      ModFormData(
        name: _name.text.trim(),
        description: _description.text,
        prePrompt: _prePrompt.text,
        postPrompt: _postPrompt.text,
        systemMust: _systemMust.text,
        systemPrompt: _systemPrompt.text,
        systemSetting: _systemSetting.text,
        systemWritingStyle: _systemWritingStyle.text,
        worldBookEntries: List.of(_worldBookEntries),
      ),
    );
  }

  /// 多行输入框（md 高亮由 [MarkdownEditingController] 提供）。
  ///
  /// 用 `expands` 让它**铺满面板剩余高度、自己在框内滚动**：窄屏整页布局下
  /// 这是编辑区最省地方的形态，也不会出现「外层滚动 + 内层滚动」两层套娃。
  /// `textAlignVertical: top` 是必须的——`expands` 时 Flutter 默认把文字垂直居中，
  /// 看起来就像「输入框里内容飘在中间」。
  Widget _multiline(TextEditingController controller, String hint) {
    return SettingsTextField(
      controller: controller,
      hint: hint,
      readOnly: _readOnly,
      expands: true,
      maxLines: null,
      textAlignVertical: TextAlignVertical.top,
      style: const TextStyle(fontSize: 13, height: 1.5),
    );
  }

  /// 宽屏断点：可用宽度 `>= 720` 用左右分栏，否则整页（全屏 Dialog）+ 顶部选择器。
  ///
  /// 与全局 `kResponsiveBreakpoint`（520）不同——Mod 面板里有长文本编辑框，
  /// 侧边导航 + 编辑区需要更宽，否则正文会被挤成一行。
  static const double _kWideBreakpoint = 720;

  /// 对话框标题（新建 / 编辑 / 查看）。
  String get _dialogTitle =>
      _readOnly ? '查看 Mod' : (_isEdit ? '编辑 Mod' : '新建 Mod');

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return size.width >= _kWideBreakpoint
        ? _buildWideDialog(context, size)
        : _buildNarrowDialog(context);
  }

  // ---------------------------------------------------------------------------
  // 宽屏：左侧面板导航 + 右侧编辑区
  // ---------------------------------------------------------------------------

  Widget _buildWideDialog(BuildContext context, Size size) {
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 960, maxHeight: size.height - 48),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildTitleRow(context),
              const SizedBox(height: 10),
              // 七个内容面板都会注入提示词：与书籍设置各页共用同一条灰字提示。
              const PromptInputHint(),
              const SizedBox(height: 10),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 224 而不是 200：四个 system 通道的标题带前缀，需要稍宽。
                    SizedBox(
                      width: 224,
                      child: ListView(
                        children: [
                          for (final meta in _panelMetas)
                            _buildNavTile(context, meta),
                        ],
                      ),
                    ),
                    const VerticalDivider(width: 17),
                    Expanded(child: _buildPanelBody(context, showTitle: true)),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _buildFooter(context),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 窄屏：悬浮窗（单栏 + 顶部面板选择器）
  // ---------------------------------------------------------------------------

  Widget _buildNarrowDialog(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        // 宽一些的窄屏（平板竖屏）也别把窗口拉满：520 之外留白更像悬浮窗。
        constraints: BoxConstraints(
          maxWidth: 520,
          maxHeight: size.height - 48,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildTitleRow(context),
              const SizedBox(height: 10),
              // 下拉框本身就是「当前面板」的标题，窄屏不再重复标题行。
              _buildPanelSelector(context),
              const SizedBox(height: 10),
              // 面板说明（列名 / 注入位置 / 3.0 提醒）紧贴选择器，一并属于这块。
              Expanded(child: _buildPanelBody(context, showTitle: false)),
              const SizedBox(height: 6),
              // #/## 提示挪到编辑区下方当脚注，上面留出更多空间给正文。
              const PromptInputHint(),
              const SizedBox(height: 6),
              _buildFooter(context),
            ],
          ),
        ),
      ),
    );
  }

  /// 窄屏面板选择器（下拉框本身就是标题，不再单独重复一行面板名）。
  Widget _buildPanelSelector(BuildContext context) {
    final colors = context.narrColors;
    return Container(
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(NarrChatTheme.controlRadius),
        border: Border.all(color: colors.divider),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<ModPanel>(
          key: const ValueKey('mod_panel_dropdown'),
          value: _panel,
          isExpanded: true,
          isDense: true,
          borderRadius: BorderRadius.circular(NarrChatTheme.controlRadius),
          padding: const EdgeInsets.symmetric(vertical: 10),
          icon: const Icon(Icons.expand_more, size: 20),
          items: [
            for (final meta in _panelMetas)
              DropdownMenuItem<ModPanel>(
                value: meta.panel,
                child: Text(
                  meta.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13.5),
                ),
              ),
          ],
          onChanged: (value) {
            if (value == null) return;
            _selectPanel(value);
          },
        ),
      ),
    );
  }

  /// 底部按钮（两种布局共用；只读模式只有「关闭」）。
  Widget _buildFooter(BuildContext context) {
    return Row(
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
    );
  }

  /// 宽屏顶部标题。
  Widget _buildTitleRow(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.extension_outlined, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            _dialogTitle,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: context.narrColors.textPrimary,
            ),
          ),
        ),
      ],
    );
  }

  void _selectPanel(ModPanel panel) {
    if (_panel == panel) return;
    setState(() => _panel = panel);
  }

  /// 宽屏左侧导航项（选中高亮；标题较长时最多两行）。
  Widget _buildNavTile(BuildContext context, _ModPanelMeta meta) {
    final selected = meta.panel == _panel;
    final colors = context.narrColors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: selected ? colors.background : Colors.transparent,
        borderRadius: BorderRadius.circular(NarrChatTheme.controlRadius),
        child: InkWell(
          key: ValueKey('mod_panel_nav_${meta.panel.name}'),
          borderRadius: BorderRadius.circular(NarrChatTheme.controlRadius),
          onTap: () => _selectPanel(meta.panel),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Text(
              meta.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? colors.textPrimary : colors.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 面板正文：标题（宽屏才有）+ 列名 / 注入位置灰字 +（新列）提醒条 + 内容。
  ///
  /// 窄屏不重复标题——顶部选择器已经写着当前面板名，省下的高度全给编辑区。
  Widget _buildPanelBody(BuildContext context, {required bool showTitle}) {
    final meta = _metaOf(_panel);
    final colors = context.narrColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showTitle) ...[
          Text(
            meta.title,
            key: ValueKey('mod_panel_title_${meta.panel.name}'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
        ],
        Text(
          meta.caption,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 11.5, color: colors.textSecondary),
        ),
        if (!meta.activeIn30) ...[
          const SizedBox(height: 8),
          _buildInactiveReminder(context),
        ],
        const SizedBox(height: 10),
        Expanded(
          child: KeyedSubtree(
            key: ValueKey('mod_panel_content_${meta.panel.name}'),
            child: _buildPanelContent(meta.panel),
          ),
        ),
      ],
    );
  }

  /// 三个新列的提醒条（查看模式同样显示）：该列在 3.0 不生效。
  Widget _buildInactiveReminder(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(NarrChatTheme.controlRadius),
      ),
      child: Text(
        '该列在 3.0 不生效',
        style: TextStyle(fontSize: 12, color: scheme.onErrorContainer),
      ),
    );
  }

  /// 各面板的内容区（所有控制器常驻 State，切面板不丢草稿）。
  Widget _buildPanelContent(ModPanel panel) => switch (panel) {
        ModPanel.basic => SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SettingsTextField(
                  controller: _name,
                  label: '名称 *（仅用于辨识，不发送给 AI）',
                  hint: '如：文笔润色',
                  readOnly: _readOnly,
                ),
                const SizedBox(height: 12),
                SettingsTextField(
                  controller: _description,
                  label: '简介（仅用于辨识，不发送给 AI）',
                  hint: '简要说明这个 Mod 的作用',
                  readOnly: _readOnly,
                  minLines: 2,
                  maxLines: 3,
                ),
                const SizedBox(height: 8),
                UuidDisplay(label: 'Mod UUID', uuid: widget.mod?.uuid ?? ''),
              ],
            ),
          ),
        ModPanel.pre => _multiline(_prePrompt, '发送请求时自动置入「前置词」区'),
        ModPanel.post => _multiline(_postPrompt, '发送请求时自动置入「后置词」区'),
        ModPanel.misc =>
          _multiline(_systemPrompt, '跨模块的通用补充：格式偏好、口吻、禁忌等'),
        ModPanel.setting => _multiline(_systemSetting, '紧随本书设定之后注入'),
        ModPanel.writing =>
          _multiline(_systemWritingStyle, '排在本书「文笔参考范文」之前，只做补充'),
        ModPanel.must =>
          _multiline(_systemMust, '硬约束：进入「必须遵循」段，并在结尾逆序复述一次'),
        // 世界书条目可能较多，需可滚动（与其它面板一致）。
        ModPanel.worldBook => SingleChildScrollView(
            child: _ModWorldBookEditor(
              initialEntries: _worldBookEntries,
              readOnly: _readOnly,
              onChanged: (entries) => _worldBookEntries = entries,
            ),
          ),
      };

  /// 面板元数据：顺序 = 枚举顺序 = `docs/mods.md` §七 的面板顺序。
  static const List<_ModPanelMeta> _panelMetas = [
    _ModPanelMeta(
      panel: ModPanel.basic,
      title: '基本信息',
      column: '',
      injection: '仅用于辨识，不发送给 AI',
      activeIn30: true,
    ),
    _ModPanelMeta(
      panel: ModPanel.pre,
      title: '前置词',
      column: 'pre_prompt',
      injection: '用户消息前置词区（用户前置词之后）',
      activeIn30: true,
    ),
    _ModPanelMeta(
      panel: ModPanel.post,
      title: '后置词',
      column: 'post_prompt',
      injection: '用户消息后置词区（用户后置词之前）',
      activeIn30: true,
    ),
    _ModPanelMeta(
      panel: ModPanel.misc,
      title: kModPanelMiscTitle,
      column: 'system_prompt',
      injection: '`{system_extra}` 的「杂项要求」块',
      activeIn30: true,
    ),
    _ModPanelMeta(
      panel: ModPanel.setting,
      title: kModPanelSettingTitle,
      column: 'system_setting',
      injection: '书籍设定之后（设定块）',
      activeIn30: false,
    ),
    _ModPanelMeta(
      panel: ModPanel.writing,
      title: kModPanelWritingTitle,
      column: 'system_writing_style',
      injection: '「文笔要求与参考段落」块（书范文之前）',
      activeIn30: false,
    ),
    _ModPanelMeta(
      panel: ModPanel.must,
      title: kModPanelMustTitle,
      column: 'system_must',
      injection: '「必须遵循」段 2~n，末尾会复述一次（token ×2）',
      activeIn30: false,
    ),
    _ModPanelMeta(
      panel: ModPanel.worldBook,
      title: '世界书',
      column: 'world_book',
      injection: '世界书块，按关键词命中',
      activeIn30: true,
    ),
  ];

  static _ModPanelMeta _metaOf(ModPanel panel) =>
      _panelMetas.firstWhere((meta) => meta.panel == panel);
}

/// 单个面板的元数据：中文名 / 数据库列名 / 注入位置文案 / 是否 3.0 生效。
class _ModPanelMeta {
  const _ModPanelMeta({
    required this.panel,
    required this.title,
    required this.column,
    required this.injection,
    required this.activeIn30,
  });

  final ModPanel panel;
  final String title;

  /// 数据库列名；基本信息没有列（空串）。
  final String column;

  /// 「注入到哪」的一句话说明（用户看得懂的说法，不写模块名代号）。
  final String injection;

  /// 3.0 是否识别这一列（否则该列在 3.0 既不显示也不注入）。
  final bool activeIn30;

  /// 面板标题下的一行灰字。
  String get caption =>
      column.isEmpty ? injection : '数据库列 $column · 注入位置：$injection';
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
              color: context.narrColors.background,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: context.narrColors.divider),
            ),
            child: Column(
              children: [
                Icon(
                  Icons.menu_book_outlined,
                  size: 40,
                  color: theme.colorScheme.outlineVariant,
                ),
                const SizedBox(height: 8),
                Text(
                  '暂无世界书条目\n添加关键词与内容，剧情输入命中关键词时将自动注入',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: context.narrColors.textSecondary,
                    height: 1.5,
                  ),
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
                      : context.narrColors.textSecondary,
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
  late final MarkdownEditingController _content;

  @override
  void initState() {
    super.initState();
    _keyword = TextEditingController(text: widget.entry?.keyword ?? '');
    _content = MarkdownEditingController(text: widget.entry?.content ?? '');
  }

  @override
  void dispose() {
    _keyword.dispose();
    _content.dispose();
    super.dispose();
  }

  void _save() {
    if (_content.text.trim().isEmpty) {
      context.notices.warning('内容不能为空');
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
            SettingsTextField(
              controller: _keyword,
              label: '触发关键词',
              hint: '多个关键词用逗号/顿号分隔；留空则恒定生效',
              readOnly: widget.readOnly,
            ),
            const SizedBox(height: 12),
            SettingsTextField(
              controller: _content,
              label: '注入内容',
              hint: '命中关键词后写入 System Prompt',
              readOnly: widget.readOnly,
              minLines: 4,
              maxLines: 8,
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
