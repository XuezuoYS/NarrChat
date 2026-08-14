/// 统一、可复用的 GitHub 风格 Markdown 预览模块。
///
/// 设计目标：
/// - **外观对齐 GitHub 的 md preview**：标题字号/字重 + h1/h2 底部边框线、
///   引用左边框、代码块圆角浅底、行内代码浅底、表格边框、列表缩进等排版
///   均按 GitHub 渲染结果还原；
/// - **GitHub 特色元素**：`[!NOTE]`/`[!TIP]`/`[!IMPORTANT]`/`[!WARNING]`/
///   `[!CAUTION]` 渲染为 GitHub Alerts 彩色提示块；`==高亮==` 渲染为荧光标记；
///   `- [x]` 任务列表渲染为 GitHub 风格复选框；围栏代码块按 GitHub 语法
///   配色（注释/字符串/数字/关键字/函数）着色；
/// - **色彩对齐 NarrChat 主题**：正文 / 边框 / 代码块背景等一律取自
///   `NarrChatColors`（[context.narrColors]），随亮暗主题自动切换；
/// - 链接蓝、行内代码前景等 GitHub 语义色沿用既有 `MarkdownSyntaxColors` 中的
///   亮暗取值，保证预览与编辑器高亮观感一致。
///
/// ## 实现说明（已对照 flutter_markdown 0.7.7+1 源码验证）
/// - 使用 `md.ExtensionSet.gitHubWeb` 解析：启用 GitHub Alerts（[AlertBlockSyntax]）
///   与任务列表（checkbox）语法；
/// - GitHub Alerts 由解析器产出 `div.markdown-alert-*`，flutter_markdown 默认
///   不认识 `div`（会触发 `_addParentInlineIfNeeded` 空值断言崩溃），因此必须
///   注册自定义块级 builder（[_AlertBlockBuilder]），在其
///   `visitElementAfterWithContext` 中按 class 识别 alert 类型并递归构建子内容；
/// - 自定义块级 builder 返回非 null 时会**替换**默认渲染（子元素不会自动出现），
///   因此 alert 构建器需自行递归渲染 `md.Element` 子节点（标题行 + 正文块）；
/// - h1/h2 底部边框线同样通过自定义块级 builder 实现（在默认 Column 之上包一层
///   带 `border-bottom` 的容器），浅/深色边框颜色随主题。
library;

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;

import '../theme/app_theme.dart';

/// GitHub 语义色（浅色/深色两套精确取值，取自 GitHub 官方 palette）。
///
/// 与编辑器高亮配色 `MarkdownSyntaxColors` 解耦，供预览层独立使用。
class GitHubPalette {
  const GitHubPalette({
    required this.link,
    required this.codeInlineFg,
    required this.codeInlineBg,
    required this.codeBlockBg,
    required this.codeBlockBorder,
    required this.codeBlockFg,
    required this.muted,
    required this.divider,
    required this.hr,
    required this.headingBorder,
    required this.tableHeaderBg,
    required this.tableBorder,
    required this.markBg,
    required this.markFg,
    required this.comment,
    required this.string,
    required this.number,
    required this.keyword,
    required this.function,
    required this.type,
    required this.operator,
  });

  final Color link;
  final Color codeInlineFg;
  final Color codeInlineBg;
  final Color codeBlockBg;
  final Color codeBlockBorder;
  final Color codeBlockFg;
  final Color muted;
  final Color divider;
  final Color hr;
  final Color headingBorder;
  final Color tableHeaderBg;
  final Color tableBorder;

  /// `==高亮==` 荧光标记色（GitHub mark 样式）。
  final Color markBg;
  final Color markFg;

  // 代码高亮 token 色（GitHub 语法配色）。
  final Color comment;
  final Color string;
  final Color number;
  final Color keyword;
  final Color function;
  final Color type;
  final Color operator;

  /// GitHub 浅色（github-light 主题）。
  static const GitHubPalette light = GitHubPalette(
    link: Color(0xFF0969DA),
    codeInlineFg: Color(0xFF0550AE),
    codeInlineBg: Color(0xFFAFB8C1),
    codeBlockBg: Color(0xFFF6F8FA),
    codeBlockBorder: Color(0xFFD1D9E0),
    codeBlockFg: Color(0xFF1F2328),
    muted: Color(0xFF59636E),
    divider: Color(0xFFD0D7DE),
    hr: Color(0xFFD1D9E0),
    headingBorder: Color(0xFFD0D7DE),
    tableHeaderBg: Color(0xFFF6F8FA),
    tableBorder: Color(0xFFD0D7DE),
    markBg: Color(0xFFFFF8C5),
    markFg: Color(0xFF1F2328),
    comment: Color(0xFF6E7781),
    string: Color(0xFF0A3069),
    number: Color(0xFF0550AE),
    keyword: Color(0xFFCF222E),
    function: Color(0xFF8250DF),
    type: Color(0xFF953800),
    operator: Color(0xFF0550AE),
  );

  /// GitHub 深色（github-dark 主题）。
  static const GitHubPalette dark = GitHubPalette(
    link: Color(0xFF4493F8),
    codeInlineFg: Color(0xFFF0883E),
    codeInlineBg: Color(0xFF3D444D),
    codeBlockBg: Color(0xFF161B22),
    codeBlockBorder: Color(0xFF30363D),
    codeBlockFg: Color(0xFFF0F6FC),
    muted: Color(0xFF8B949E),
    divider: Color(0xFF3D444D),
    hr: Color(0xFF30363D),
    headingBorder: Color(0xFF30363D),
    tableHeaderBg: Color(0xFF21262D),
    tableBorder: Color(0xFF3D444D),
    markBg: Color(0xFF7D6B1F),
    markFg: Color(0xFFF0F6FC),
    comment: Color(0xFF8B949E),
    string: Color(0xFFA5D6FF),
    number: Color(0xFF79C0FF),
    keyword: Color(0xFFFF7B72),
    function: Color(0xFFD2A8FF),
    type: Color(0xFFFFA657),
    operator: Color(0xFF79C0FF),
  );

  /// 按当前主题亮度选取。
  static GitHubPalette of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;
}

/// 由当前 [BuildContext] 构建 GitHub 风格的 [MarkdownStyleSheet]。
///
/// 所有可推导的颜色均取自主题；仅 GitHub 语义色（链接蓝 / 行内代码前景）
/// 直接引用 [GitHubPalette]，避免在预览层重复硬编码。
class GitHubMarkdownStyle {
  GitHubMarkdownStyle._();

  /// 依据当前主题亮度返回 GitHub 风格的样式表。
  ///
  /// [base] 为正文基样式（默认主题 `bodyMedium`）；h1/h2 底部边框线由
  /// [headingBorderBuilder] 绘制，这里仅负责字号/字重/内边距。
  static MarkdownStyleSheet of(BuildContext context, {TextStyle? base}) {
    final theme = Theme.of(context);
    final colors = context.narrColors;
    final isDark = theme.brightness == Brightness.dark;
    final git = isDark ? GitHubPalette.dark : GitHubPalette.light;

    // 正文基样式：优先取主题正文（带默认字号/行高），再按需覆盖。
    final p = (base ?? theme.textTheme.bodyMedium) ?? const TextStyle();
    final linkStyle = TextStyle(
      color: git.link,
      decoration: TextDecoration.underline,
      decorationColor: git.link,
    );

    // 行内代码：GitHub 为浅灰底 + 圆角 + 等宽 + 略小字号。
    // 背景由 [_InlineCodeBuilder] 以圆角容器绘制，此处仅保留字形样式，
    // 并显式去掉从正文继承的 `backgroundColor`（避免与容器底色叠加出
    // 「白底」观感）。
    final code = p.copyWith(
      color: git.codeInlineFg,
      fontFamily: 'monospace',
      fontSize: (p.fontSize ?? 14) * 0.85,
      backgroundColor: null,
    );

    return MarkdownStyleSheet(
      // 链接：GitHub 蓝 + 下划线。
      a: linkStyle,
      p: p,
      pPadding: EdgeInsets.zero,
      code: code,
      // 标题字号/字重对齐 GitHub（h1 2em/600、h2 1.5em/600、h3 1.25em/600、
      // h4 1em/600、h5 0.875em/600、h6 0.85em/600+灰色），颜色随主题正文。
      // h1/h2 用 underline 近似 GitHub 的 `border-bottom` 标题分隔线
      // （自定义块级 builder 会破坏 flutter_markdown 的 `_inlines` 栈，不可用）。
      h1: p.copyWith(
        fontSize: (p.fontSize ?? 14) * 2,
        fontWeight: FontWeight.w600,
        decoration: TextDecoration.underline,
        decorationColor: git.headingBorder,
        decorationThickness: 1,
        decorationStyle: TextDecorationStyle.solid,
      ),
      h1Padding: const EdgeInsets.only(bottom: 8),
      h2: p.copyWith(
        fontSize: (p.fontSize ?? 14) * 1.5,
        fontWeight: FontWeight.w600,
        decoration: TextDecoration.underline,
        decorationColor: git.headingBorder,
        decorationThickness: 1,
        decorationStyle: TextDecorationStyle.solid,
      ),
      h2Padding: const EdgeInsets.only(top: 4, bottom: 6),
      h3: p.copyWith(
        fontSize: (p.fontSize ?? 14) * 1.25,
        fontWeight: FontWeight.w600,
      ),
      h3Padding: const EdgeInsets.only(top: 4, bottom: 4),
      h4: p.copyWith(fontWeight: FontWeight.w600),
      h4Padding: const EdgeInsets.only(top: 4, bottom: 2),
      h5: p.copyWith(
        fontSize: (p.fontSize ?? 14) * 0.875,
        fontWeight: FontWeight.w600,
      ),
      h5Padding: const EdgeInsets.only(top: 4, bottom: 2),
      h6: p.copyWith(
        fontSize: (p.fontSize ?? 14) * 0.85,
        fontWeight: FontWeight.w600,
        color: colors.textSecondary,
      ),
      h6Padding: const EdgeInsets.only(top: 4, bottom: 2),
      em: const TextStyle(fontStyle: FontStyle.italic),
      strong: const TextStyle(fontWeight: FontWeight.w600),
      del: const TextStyle(decoration: TextDecoration.lineThrough),
      // 引用：GitHub 左侧细边框 + 灰字（无底色）。
      blockquote: p.copyWith(color: git.muted),
      blockquotePadding: const EdgeInsets.fromLTRB(12, 0, 0, 0),
      blockquoteDecoration: BoxDecoration(
        border: Border(
          left: BorderSide(width: 3, color: git.divider),
        ),
      ),
      blockSpacing: 12,
      listIndent: 24,
      listBullet: p.copyWith(color: colors.textSecondary),
      listBulletPadding: const EdgeInsets.only(right: 8),
      // 表格：GitHub 全格细边框、左对齐、浅表头背景。
      tableHead: p.copyWith(fontWeight: FontWeight.w600),
      tableBody: p,
      tableHeadAlign: TextAlign.left,
      tablePadding: const EdgeInsets.only(bottom: 12),
      tableBorder: TableBorder.all(color: git.tableBorder, width: 1),
      tableColumnWidth: const FlexColumnWidth(),
      tableCellsPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      tableCellsDecoration: const BoxDecoration(),
      // 代码块：浅底 + 圆角 + 边框。
      codeblockPadding: const EdgeInsets.all(12),
      codeblockDecoration: BoxDecoration(
        color: git.codeBlockBg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: git.codeBlockBorder),
      ),
      // 分割线：GitHub 细灰线。
      horizontalRuleDecoration: BoxDecoration(
        border: Border(top: BorderSide(width: 1, color: git.hr)),
      ),
      // 列表项使用 baseline 对齐，保证列表符号与文本基线一致。
      textAlign: WrapAlignment.start,
      h1Align: WrapAlignment.start,
      h2Align: WrapAlignment.start,
      h3Align: WrapAlignment.start,
      h4Align: WrapAlignment.start,
      h5Align: WrapAlignment.start,
      h6Align: WrapAlignment.start,
    );
  }

  /// 统一的 Markdown 扩展集：gitHubWeb + `==高亮==` 内联语法。
  ///
  /// 供需要自行驱动 [MarkdownBody] 的调用点（如折叠编辑器）复用。
  static md.ExtensionSet get extensionSet => md.ExtensionSet(
        md.ExtensionSet.gitHubWeb.blockSyntaxes,
        [
          _HighlightSyntax(),
          ...md.ExtensionSet.gitHubWeb.inlineSyntaxes,
        ],
      );

  /// 统一的元素构建器集合（alerts 容器 / 行内代码）。
  ///
  /// ⚠️ 不在此注册 `pre`/`h1~h6` 块级 builder：自定义块级 builder 返回
  /// 非 null 时会破坏 flutter_markdown 的 `_inlines` 栈不变量
  /// （`_inlines.isEmpty` 断言崩溃），标题底边框改由样式表
  /// `decoration: underline` 近似实现；围栏代码块走默认 `pre` 渲染路径 +
  /// [syntaxHighlighter] 着色，行内 code 由 [_InlineCodeBuilder] 绘制圆角底。
  static Map<String, MarkdownElementBuilder> builders(BuildContext context) {
    return {
      'div': _AlertBlockBuilder(),
      'code': _InlineCodeBuilder(),
      'mark': _HighlightBuilder(),
    };
  }

  /// 代码块语法高亮器（GitHub 配色）。
  static SyntaxHighlighter syntaxHighlighter(BuildContext context) =>
      _GitHubSyntaxHighlighter(GitHubPalette.of(context));
}

/// 统一的 Markdown 预览组件。
///
/// - 默认即可选中文本（使用 [SelectionArea]，跨块连续选择），
///   右键/长按默认菜单被抑制，避免与业务侧自定义气泡菜单冲突；
/// - [base] 用于调整预览正文字号/行高（默认跟随主题 `bodyMedium`）。
class MarkdownPreview extends StatelessWidget {
  /// Markdown 源文本。
  final String data;

  /// 正文基样式（默认主题 `bodyMedium`，可覆盖字号/行高）。
  final TextStyle? base;

  /// 是否允许文本选中。默认 true（启用 [SelectionArea]）。
  final bool selectable;

  /// 链接点击回调。
  final MarkdownTapLinkCallback? onTapLink;

  const MarkdownPreview({
    super.key,
    required this.data,
    this.base,
    this.selectable = true,
    this.onTapLink,
  });

  @override
  Widget build(BuildContext context) {
    final styleSheet = GitHubMarkdownStyle.of(context, base: base);
    final git = GitHubPalette.of(context);
    // ⚠️ 不传 selectable 给 MarkdownBody（保持默认 false，内部用普通 Text 渲染），
    // 由外层 [SelectionArea] 统一处理选中——若 MarkdownBody.selectable=true
    // 或 builder 返回 SelectableText，会与外层 SelectionArea 冲突导致
    // 文本无法选中（已用官方 selection_area_compatibility_test 逻辑验证）。
    final body = MarkdownBody(
      data: data,
      styleSheet: styleSheet,
      onTapLink: onTapLink,
      fitContent: true,
      extensionSet: GitHubMarkdownStyle.extensionSet,
      syntaxHighlighter: GitHubMarkdownStyle.syntaxHighlighter(context),
      builders: GitHubMarkdownStyle.builders(context),
      checkboxBuilder: _buildCheckbox,
      bulletBuilder: (params) => _buildBullet(params, git),
      listItemCrossAxisAlignment: MarkdownListItemCrossAxisAlignment.baseline,
    );

    if (!selectable) return body;

    return SelectionArea(
      contextMenuBuilder: (context, selectableRegionState) =>
          const SizedBox.shrink(),
      child: body,
    );
  }

  /// GitHub 风格任务列表复选框。
  static Widget _buildCheckbox(bool checked) {
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Icon(
        checked ? Icons.check_box : Icons.check_box_outline_blank,
        size: 16,
        color: checked ? const Color(0xFF1F883D) : const Color(0xFF8D959E),
      ),
    );
  }

  /// GitHub 风格列表符号：有序列表渲染数字序号（`1.`），无序列表按嵌套
  /// 层级切换 `•` → `○` → `▪`（GitHub 顺序）。
  static Widget _buildBullet(
    MarkdownBulletParameters parameters,
    GitHubPalette git,
  ) {
    // 有序列表：渲染数字序号。
    if (parameters.style == BulletStyle.orderedList) {
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Text(
          '${parameters.index + 1}.',
          textAlign: TextAlign.right,
          style: TextStyle(color: git.muted, fontSize: 14),
        ),
      );
    }

    // 无序列表：按嵌套层级切换符号。
    final String mark = switch (parameters.nestLevel % 3) {
      0 => '•',
      1 => '○',
      _ => '▪',
    };
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Text(
        mark,
        textAlign: TextAlign.center,
        style: TextStyle(color: git.muted, fontSize: 14),
      ),
    );
  }
}

/// 行内代码构建器：为行内 `code` 绘制 GitHub 风格的浅灰圆角底，
/// 与围栏代码块（走默认 `pre` 渲染路径 + [GitHubMarkdownStyle.syntaxHighlighter]）
/// 区分。
///
/// ⚠️ 不注册 `pre` builder（会破坏 flutter_markdown 的 `_inlines` 栈），
/// 因此无法用进入/离开 `pre` 标记状态；改为通过 `code` 元素的 class
/// （围栏代码块解析为 `pre > code[class=language-x]`，行内 code 无 class）
/// 判断是否为围栏代码块内的 `code`。
class _InlineCodeBuilder extends MarkdownElementBuilder {
  @override
  bool isBlockElement() => false;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    // 围栏代码块内的 `code`（class=language-*）交由默认代码块渲染，
    // 避免覆盖其内容。
    if ((element.attributes['class'] ?? '').startsWith('language-')) {
      return null;
    }

    final git = GitHubPalette.of(context);
    // 用普通 Text（外层 SelectionArea 统一选中），显式以 git 色绘制文字，
    // 避免继承正文的 backgroundColor 造成「白底」。
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 2),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: git.codeInlineBg.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        element.textContent,
        style: TextStyle(
          color: git.codeInlineFg,
          fontFamily: 'monospace',
          fontSize: (preferredStyle?.fontSize ?? 14) * 0.85,
        ),
      ),
    );
  }
}

/// `==高亮==` 标记构建器：为 `mark` 元素绘制荧光黄底。
class _HighlightBuilder extends MarkdownElementBuilder {
  @override
  bool isBlockElement() => false;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final git = GitHubPalette.of(context);
    return Text(
      element.textContent,
      style: TextStyle(
        color: git.markFg,
        backgroundColor: git.markBg,
      ),
    );
  }
}

/// GitHub Alerts 块级构建器：识别 `div.markdown-alert-*` 并按类型渲染
/// 彩色提示块（左侧粗边框 + 浅色底 + 加粗标题 + 图标）。
class _AlertBlockBuilder extends MarkdownElementBuilder {
  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final cls = element.attributes['class'] ?? '';
    final type = _alertType(cls);
    if (type == null) return null; // 非 alert 的 div 走默认渲染

    final theme = Theme.of(context);
    final git = GitHubPalette.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final (bg, border, fg) = _AlertStyle.of(type, isDark);

    final children = <Widget>[];
    final title = <InlineSpan>[];
    for (final node in element.children ?? const <md.Node>[]) {
      if (node is md.Element &&
          node.attributes['class'] == 'markdown-alert-title') {
        // 标题行：图标 + 加粗文字。
        title.add(WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Icon(_alertIcon(type), size: 16, color: fg),
          ),
        ));
        title.add(TextSpan(
          text: node.textContent,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: fg,
            fontSize: (preferredStyle?.fontSize ?? 14) * 0.95,
          ),
        ));
      } else if (node is md.Text) {
        children.add(_text(context, node.text, git, preferredStyle));
      } else if (node is md.Element) {
        children.add(_block(context, node, git, preferredStyle));
      }
    }

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
        border: Border(left: BorderSide(color: border, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title.isNotEmpty) Text.rich(TextSpan(children: title)),
          ...children,
        ],
      ),
    );
  }

  static String? _alertType(String cls) {
    const types = ['note', 'tip', 'important', 'warning', 'caution'];
    for (final t in types) {
      if (cls.contains('markdown-alert-$t')) return t;
    }
    return null;
  }

  static IconData _alertIcon(String type) {
    switch (type) {
      case 'tip':
        return Icons.lightbulb_outline;
      case 'important':
        return Icons.report_gmailerrorred_outlined;
      case 'warning':
        return Icons.warning_amber_rounded;
      case 'caution':
        return Icons.dangerous_outlined;
      default:
        return Icons.info_outline;
    }
  }

  Widget _block(
    BuildContext context,
    md.Element el,
    GitHubPalette git,
    TextStyle? base,
  ) {
    final theme = Theme.of(context);
    switch (el.tag) {
      case 'p':
        return Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text.rich(_spans(context, el, git, base), style: base),
        );
      case 'ul':
        return Padding(
          padding: const EdgeInsets.only(left: 12, top: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final c in el.children ?? const <md.Node>[])
                if (c is md.Element && c.tag == 'li')
                  _listItem(context, c, git, base),
            ],
          ),
        );
      case 'ol':
        return Padding(
          padding: const EdgeInsets.only(left: 16, top: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < (el.children?.length ?? 0); i++)
                if (el.children![i] is md.Element &&
                    (el.children![i] as md.Element).tag == 'li')
                  _listItem(context, el.children![i] as md.Element, git, base,
                      number: i + 1),
            ],
          ),
        );
      case 'pre':
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.only(top: 6),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: git.codeBlockBg,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: git.codeBlockBorder),
          ),
          child: Text(
            el.textContent,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: (base?.fontSize ?? 14) * 0.85,
              color: git.codeBlockFg,
            ),
          ),
        );
      default:
        return Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            el.textContent,
            style: TextStyle(
              color: theme.colorScheme.onSurface,
              fontSize: base?.fontSize,
            ),
          ),
        );
    }
  }

  Widget _listItem(
    BuildContext context,
    md.Element li,
    GitHubPalette git,
    TextStyle? base, {
    int? number,
  }) {
    final bullet = number != null
        ? Text('$number. ',
            style: TextStyle(color: git.muted, fontSize: base?.fontSize))
        : Text('• ',
            style: TextStyle(color: git.muted, fontSize: base?.fontSize));
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          bullet,
          Flexible(
            child: Text.rich(_spans(context, li, git, base), style: base),
          ),
        ],
      ),
    );
  }

  /// 递归构建内联 span（strong / em / code / a / del）。
  InlineSpan _spans(
    BuildContext context,
    md.Element el,
    GitHubPalette git,
    TextStyle? base,
  ) =>
      _inlineSpans(context, el, git, base);

  Widget _text(
    BuildContext context,
    String text,
    GitHubPalette git,
    TextStyle? base,
  ) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(text, style: base),
    );
  }
}

/// 递归构建内联 span（strong / em / code / a / del）。
///
/// 供 [_AlertBlockBuilder] 渲染 alert 内容与列表项时复用。
InlineSpan _inlineSpans(
  BuildContext context,
  md.Element el,
  GitHubPalette git,
  TextStyle? base,
) {
  final children = <InlineSpan>[];
  for (final node in el.children ?? const <md.Node>[]) {
    if (node is md.Text) {
      children.add(TextSpan(text: node.text));
    } else if (node is md.Element) {
      children.add(_elementSpan(context, node, git, base));
    }
  }
  return TextSpan(children: children);
}

/// 单个元素的内联 span（应用样式并递归子级）。
InlineSpan _elementSpan(
  BuildContext context,
  md.Element el,
  GitHubPalette git,
  TextStyle? base,
) {
  TextStyle? style;
  switch (el.tag) {
    case 'strong':
      style = const TextStyle(fontWeight: FontWeight.w600);
    case 'em':
      style = const TextStyle(fontStyle: FontStyle.italic);
    case 'code':
      style = TextStyle(
        fontFamily: 'monospace',
        fontSize: (base?.fontSize ?? 14) * 0.85,
        color: git.codeInlineFg,
        backgroundColor: git.codeInlineBg.withValues(alpha: 0.25),
      );
    case 'del':
      style = const TextStyle(decoration: TextDecoration.lineThrough);
    case 'mark':
      style = TextStyle(
        color: git.markFg,
        backgroundColor: git.markBg,
      );
    case 'a':
      style = TextStyle(
        color: git.link,
        decoration: TextDecoration.underline,
        decorationColor: git.link,
      );
  }
  return TextSpan(
    style: style,
    children: [_inlineSpans(context, el, git, base)],
  );
}

/// Alert 类型配色（GitHub 官方 light/dark 取值）。
class _AlertStyle {
  final Color bg;
  final Color border;
  final Color fg;

  const _AlertStyle(this.bg, this.border, this.fg);

  static (Color, Color, Color) of(String type, bool isDark) {
    switch (type) {
      case 'note':
        return isDark
            ? (const Color(0xFF1F6FEB).withValues(alpha: 0.15),
                const Color(0xFF1F6FEB), const Color(0xFF4493F8))
            : (const Color(0xFFDDF4FF), const Color(0xFF0969DA),
                const Color(0xFF0969DA));
      case 'tip':
        return isDark
            ? (const Color(0xFF2EA043).withValues(alpha: 0.15),
                const Color(0xFF2EA043), const Color(0xFF3FB950))
            : (const Color(0xFFDAFBE1), const Color(0xFF1A7F37),
                const Color(0xFF1A7F37));
      case 'important':
        return isDark
            ? (const Color(0xFF8957E5).withValues(alpha: 0.15),
                const Color(0xFF8957E5), const Color(0xFFA371F7))
            : (const Color(0xFFFBEFFF), const Color(0xFF8250DF),
                const Color(0xFF8250DF));
      case 'warning':
        return isDark
            ? (const Color(0xFF9E6A03).withValues(alpha: 0.15),
                const Color(0xFF9E6A03), const Color(0xFFD29922))
            : (const Color(0xFFFFF8C5), const Color(0xFF9A6700),
                const Color(0xFF9A6700));
      case 'caution':
        return isDark
            ? (const Color(0xFFDA3633).withValues(alpha: 0.15),
                const Color(0xFFDA3633), const Color(0xFFF85149))
            : (const Color(0xFFFFEBE9), const Color(0xFFCF222E),
                const Color(0xFFCF222E));
      default:
        return isDark
            ? (const Color(0xFF1F6FEB).withValues(alpha: 0.15),
                const Color(0xFF1F6FEB), const Color(0xFF4493F8))
            : (const Color(0xFFDDF4FF), const Color(0xFF0969DA),
                const Color(0xFF0969DA));
    }
  }
}

/// `==高亮==` 内联语法：解析为 `<mark>` 元素。
class _HighlightSyntax extends md.InlineSyntax {
  _HighlightSyntax() : super(r'==(.+?)==', startCharacter: 0x3D);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element('mark', [md.Text(match[1]!)]));
    return true;
  }
}

/// 轻量 GitHub 语法高亮器（注释/字符串/数字/关键字/类型/函数/运算符）。
class _GitHubSyntaxHighlighter implements SyntaxHighlighter {
  final GitHubPalette git;

  _GitHubSyntaxHighlighter(this.git);

  @override
  TextSpan format(String source) {
    final base = TextStyle(
      fontFamily: 'monospace',
      fontSize: 12,
      height: 1.5,
      color: git.codeBlockFg,
    );

    // 正则需注意 Dart raw string 内不能出现未转义引号冲突；用 r"..." 包住。
    final tokens = <(RegExp, Color)>[
      (RegExp(r'//[^\n]*|#[^\n]*|/\*[\s\S]*?\*/'), git.comment),
      (RegExp(r'"(?:[^"\\\n]|\\.)*"', caseSensitive: true), git.string),
      (RegExp(r"'(?:[^'\\\n]|\\.)*'"), git.string),
      (RegExp(r'`[^`\n]*`'), git.string),
      (RegExp(r'\b\d[\d_]*(?:\.\d+)?[fFlL]?\b'), git.number),
      (
        RegExp(
          r'\b(?:import|export|return|if|else|for|while|do|switch|case|'
          r'default|break|continue|void|var|let|const|final|new|class|'
          r'struct|enum|interface|extends|implements|typedef|function|func|'
          r'def|async|await|yield|static|public|private|protected|try|catch|'
          r'finally|throw|assert|super|this|null|true|false|in|of|is|as|'
          r'where|with|when|match|operator|override|required|late|using|'
          r'namespace|package)\b',
        ),
        git.keyword
      ),
      (RegExp(r'\b[A-Z][A-Za-z0-9_]*\b'), git.type),
      (RegExp(r'\b[a-z_][A-Za-z0-9_]*\s*\('), git.function),
      (RegExp(r'[+\-*/%=<>!&|^~?:]+'), git.operator),
    ];

    final spans = <TextSpan>[];
    var pos = 0;
    while (pos < source.length) {
      Match? best;
      Color? bestColor;
      for (final (re, color) in tokens) {
        final m = re.matchAsPrefix(source, pos);
        if (m != null && (best == null || m.start < best.start)) {
          best = m;
          bestColor = color;
        }
      }
      if (best == null) {
        spans.add(TextSpan(text: source.substring(pos)));
        break;
      }
      if (best.start > pos) {
        spans.add(TextSpan(text: source.substring(pos, best.start)));
      }
      spans.add(
        TextSpan(text: best.group(0), style: TextStyle(color: bestColor)),
      );
      pos = best.end;
    }
    return TextSpan(style: base, children: spans);
  }
}
