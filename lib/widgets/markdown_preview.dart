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

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:provider/provider.dart';

import '../services/app_notice_center.dart';
import '../theme/app_theme.dart';
import 'selection_toolbar.dart';

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

  /// 列表符号列宽度（[of] 的 `listIndent`）。
  static const double listIndent = 24;

  /// 列表符号右侧间距（[of] 的 `listBulletPadding` 右值）。
  static const double listBulletRightPadding = 8;

  /// 列表符号右侧内边距。
  static const EdgeInsets listBulletPadding =
      EdgeInsets.only(right: listBulletRightPadding);

  /// 列表项「符号 + 内容」布局中符号占位的总宽度。
  ///
  /// 与 `MarkdownBuilder` 内部算式（`listIndent + listBulletPadding.horizontal`）
  /// 一致；单独渲染列表项（如推荐行动选项行）时按此宽度对齐符号列。
  static const double listBulletWidth = listIndent + listBulletRightPadding;

  /// 块与块之间的垂直间距（`MarkdownBody` 内部相邻块的间距）。
  ///
  /// 把一段 Markdown 拆成多个 `MarkdownBody` 渲染时（见
  /// `StreamingMarkdown` 的按块增量渲染），块间隔由调用方按本值补出，
  /// 观感才与整体解析一致。
  static const double blockSpacing = 12;

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
      blockSpacing: blockSpacing,
      listIndent: listIndent,
      listBullet: p.copyWith(color: colors.textSecondary),
      listBulletPadding: listBulletPadding,
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
  /// 语法对象无状态（[md.Document] 只读取传入列表，不写入），可安全全局共享，
  /// 避免每次构建都重新分配。
  static final md.ExtensionSet extensionSet = md.ExtensionSet(
    md.ExtensionSet.gitHubWeb.blockSyntaxes,
    [
      _HighlightSyntax(),
      ...md.ExtensionSet.gitHubWeb.inlineSyntaxes,
    ],
  );

  /// 统一的元素构建器集合（alerts 容器 / 行内代码 / 高亮）。
  ///
  /// ⚠️ 不在此注册 `pre`/`h1~h6` 块级 builder：自定义块级 builder 返回
  /// 非 null 时会破坏 flutter_markdown 的 `_inlines` 栈不变量
  /// （`_inlines.isEmpty` 断言崩溃），标题底边框改由样式表
  /// `decoration: underline` 近似实现；围栏代码块走默认 `pre` 渲染路径 +
  /// [syntaxHighlighter] 着色，行内 code 由 [_InlineCodeBuilder] 绘制圆角底。
  ///
  /// 构建器本身无状态（`visit*` 时按 [BuildContext] 现取配色），共享同一实例
  /// 即可；以不可变 Map 暴露，避免调用点误改全局状态。
  static final Map<String, MarkdownElementBuilder> builders =
      Map<String, MarkdownElementBuilder>.unmodifiable({
    'div': _AlertBlockBuilder(),
    'code': _InlineCodeBuilder(),
    'mark': _HighlightBuilder(),
  });

  /// 代码块语法高亮器（GitHub 配色）。
  static SyntaxHighlighter syntaxHighlighter(BuildContext context) =>
      _GitHubSyntaxHighlighter(GitHubPalette.of(context));
}

/// 归一化换行符：`\r\n` / `\r` → `\n`，使后续的判定与渲染不受平台差异影响。
String _normalizeNewlines(String data) =>
    data.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

/// 纯文本展示内容：换行归一化，并去掉**末尾**多余的空白行（打字时多敲的回车
/// 不该在气泡里占出一行高度）；行内换行原样保留。
String _plainDisplayText(String data) =>
    _normalizeNewlines(data).replaceFirst(RegExp(r'[ \t]*(?:\n[ \t]*)+$'), '');

/// Markdown 结构特征模式集：**任一命中**即认为文本按 Markdown 排版。
///
/// 判定对象是「换行归一化 + 去掉首尾空白后」的文本；行首锚定模式以
/// `multiLine` 逐行匹配。刻意保守收录，误判方向一律偏向纯文本（宁可少渲染
/// 一点 md，也不能把用户手打的换行折叠成空格）：
///
/// - 列表/标题/编号/引用等行首标记一律要求**空格 + 非空内容**，故 `#话题`、
///   `-不是列表`、`2.十点半`、`>_<` 这类口语与颜文字写法不会被误判；
/// - 只认成对的 `**粗体**`，不认单 `*` / `_` / `__` 强调，避免 `10*20*30`、
///   `snake_case`、`__init__` 被误判；
/// - 不认 `~~删除线~~` 与 `==高亮==`：这两个符号在聊天里更常被当作语气波浪线 /
///   等号颜文字使用（渲染侧仍支持，只是不作为「这是 Markdown」的判定依据）；
/// - 围栏只认反引号、不认 `~~~`（同上，`~` 属语气符号）；
/// - HTML 只认标签白名单，避免 `a < b`、`>=` 命中。
final List<RegExp> _markdownSignalPatterns = [
  // ── 块级：段落分隔（内部空行；空行允许只含空格/Tab）。
  RegExp(r'\n[ \t]*\n'),
  // ── 块级：ATX 标题（`#` ~ `######` + 空白 + 内容，最多 3 个前导空格）。
  RegExp(r'^[ \t]{0,3}#{1,6}[ \t]+\S', multiLine: true),
  // ── 块级：无序列表项（`- ` / `* ` / `+ ` + 内容；任务列表 `- [x]` 同样命中）。
  RegExp(r'^[ \t]{0,3}[-*+][ \t]+\S', multiLine: true),
  // ── 块级：有序列表项（`1.` / `1)` + 内容）。
  RegExp(r'^[ \t]{0,3}\d{1,9}[.)][ \t]+\S', multiLine: true),
  // ── 块级：引用（要求 `>` 后有空格；GitHub Alerts `> [!NOTE]` 亦命中）。
  RegExp(r'^[ \t]{0,3}>[ \t]+\S', multiLine: true),
  // ── 块级：围栏代码块（行首三个及以上反引号）。
  RegExp(r'^[ \t]{0,3}`{3,}'),
  // ── 块级：表格分隔行（`| --- | --- |`，需 ≥2 列，避免与分割线混淆）。
  RegExp(
    r'^[ \t]{0,3}\|?[ \t]*:?-{1,}:?[ \t]*(?:\|[ \t]*:?-{1,}:?[ \t]*)+\|?[ \t]*$',
    multiLine: true,
  ),
  // ── 块级：分割线（整行只有 `---` / `***` / `___`）。
  RegExp(r'^[ \t]{0,3}(?:-{3,}|\*{3,}|_{3,})[ \t]*$', multiLine: true),
  // ── 块级：HTML 标签（白名单，含 `<br>` 单独成行）。
  RegExp(
    r'^[ \t]{0,3}</?(?:div|span|p|br|hr|img|a|table|thead|tbody|tr|td|th|ul|'
    r'ol|li|dl|dt|dd|blockquote|pre|code|kbd|sup|sub|b|i|u|s|em|strong|del|'
    r'ins|mark|details|summary|center|h[1-6])\b',
    multiLine: true,
  ),
  // ── 内联：`**粗体**`（成对、内容两端不留空格、内部不含 `*`）。
  RegExp(r'\*\*(?![ \t*])[^*\n]*?[^ \t*]\*\*'),
  // ── 内联：`` `行内代码` ``（同一行内的成对反引号）。
  RegExp(r'`[^`\n]+`'),
  // ── 内联：`[文本](链接)` / `![图片](链接)`（方括号与圆括号紧邻）。
  RegExp(r'!?\[[^\]\n]*\]\([^)\n]*\)'),
  // ── 内联：自动链接 `<https://…>` / `<mailto:…>`。
  RegExp(r'<(?:https?|ftp|mailto):[^>\n]+>'),
];

/// 判断 [data] 是否具有 Markdown 排版特征（见 [_markdownSignalPatterns]）。
///
/// Markdown 会把段内单个换行当作「软换行」折叠成空格，而用户手打消息里的
/// 换行是真实意图。因此对**没有任何 md 结构**的文本直接按纯文本渲染；只要
/// 出现空行分段、块级标记或成对内联标记，就按 Markdown 渲染（此时遵循标准
/// md 规则，段内单换行仍会被折叠——这是使用 md 语法的自然结果）。
bool isMarkdownFormatted(String data) {
  final text = _normalizeNewlines(data).trim();
  if (text.isEmpty) return false;
  return _markdownSignalPatterns.any((p) => p.hasMatch(text));
}

/// 统一的 Markdown 预览组件。
///
/// - 默认即可选中文本（使用 [SelectionArea]，跨块连续选择），
///   右键/长按默认菜单被抑制，避免与业务侧自定义气泡菜单冲突；
/// - [base] 用于调整预览正文字号/行高（默认跟随主题 `bodyMedium`）；
/// - 样式表 / 语法高亮器按主题与 [base] 缓存，父级重建时不重复推导
///   （流式生成期间整页会持续重建，历史内容不变的预览不应有增量开销）；
/// - 明确不需要 Markdown 语义的调用点改用 [PlainTextPreview]（零解析开销）。
class MarkdownPreview extends StatefulWidget {
  /// Markdown 源文本。
  final String data;

  /// 正文基样式（默认主题 `bodyMedium`，可覆盖字号/行高）。
  final TextStyle? base;

  /// 是否允许文本选中。默认 true（启用 [SelectionArea]）。
  final bool selectable;

  /// 链接点击回调。
  final MarkdownTapLinkCallback? onTapLink;

  /// 文本无 Markdown 特征（见 [isMarkdownFormatted]）时按**纯文本**渲染。
  ///
  /// 用于用户气泡等「多半是手打纯文本」的场景：保留用户输入的单个换行，
  /// 不被 Markdown 软换行折叠成空格。默认 false（始终走 Markdown 渲染）。
  final bool plainTextWhenNotMarkdown;

  const MarkdownPreview({
    super.key,
    required this.data,
    this.base,
    this.selectable = true,
    this.onTapLink,
    this.plainTextWhenNotMarkdown = false,
  });

  /// 列表项符号：有序列表渲染数字序号（`1.`），无序列表按嵌套层级切换
  /// `•` → `○` → `▪`（GitHub 顺序）。
  ///
  /// [MarkdownBody.bulletBuilder] 的单一真源。需要单独渲染列表项并绑定手势的
  /// 调用点（如推荐行动选项行）复用它 + [GitHubMarkdownStyle.listBulletWidth]
  /// 对齐符号列，无需重复一份列表外观。
  static Widget buildListBullet(
    BuildContext context,
    MarkdownBulletParameters parameters,
  ) =>
      _buildBullet(parameters, GitHubPalette.of(context));

  /// 把**内联** Markdown 文本渲染为 [InlineSpan]（递归处理 strong / em / code /
  /// del / a / mark）。
  ///
  /// 供需要把**单行**内容直接拼进 `Text.rich` 的调用点复用（如推荐行动选项行）：
  /// 与 [MarkdownPreview] 共用同一套语法（[GitHubMarkdownStyle.extensionSet]）与
  /// 配色，但**不建 `MarkdownBody`**——省掉一次块级解析与整棵子树构建。
  ///
  /// ⚠️ 只做内联解析：调用点须保证 [data] 是单行、不含块级结构。
  static InlineSpan buildInlineSpans(
    BuildContext context,
    String data, {
    TextStyle? base,
  }) =>
      _nodesToSpans(
        context,
        _inlineMarkdownDocument.parseInline(data),
        GitHubPalette.of(context),
        base,
      );

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

  @override
  State<MarkdownPreview> createState() => _MarkdownPreviewState();
}

class _MarkdownPreviewState extends State<MarkdownPreview> {
  /// 样式表与语法高亮器缓存。
  ///
  /// 二者只随主题（亮暗 / [NarrChatColors]）与 [MarkdownPreview.base] 变化，
  /// 而 [build] 会在父级每次重建时重跑（如流式生成期间整页重建）。此前每次
  /// 构建都重新推导（约 15 个 [TextStyle] 与一份完整样式表），历史消息等
  /// 「内容不变」的预览因此持续付出无谓开销。
  MarkdownStyleSheet? _styleSheet;
  SyntaxHighlighter? _syntaxHighlighter;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 主题（亮暗 / NarrChatColors）变化 → 依赖变更 → 重新推导。
    _resolveStyle();
  }

  @override
  void didUpdateWidget(covariant MarkdownPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    // base 由调用点按当前主题现算：值变化（含主题切换后重算）才需重新推导。
    if (oldWidget.base != widget.base) _resolveStyle();
  }

  /// 按当前主题与 [MarkdownPreview.base] 推导样式表 / 语法高亮器。
  void _resolveStyle() {
    _styleSheet = GitHubMarkdownStyle.of(context, base: widget.base);
    _syntaxHighlighter = GitHubMarkdownStyle.syntaxHighlighter(context);
  }

  @override
  Widget build(BuildContext context) {
    // 无 Markdown 结构特征时按纯文本渲染（保留换行，见 plainTextWhenNotMarkdown）。
    if (widget.plainTextWhenNotMarkdown && !isMarkdownFormatted(widget.data)) {
      return PlainTextPreview(
        data: widget.data,
        base: widget.base,
        selectable: widget.selectable,
      );
    }
    return _markdownBody(context);
  }

  /// Markdown 正文（GitHub 风格样式表 + 统一扩展集 / builders）。
  Widget _markdownBody(BuildContext context) {
    final git = GitHubPalette.of(context);
    // ⚠️ 不传 selectable 给 MarkdownBody（保持默认 false，内部用普通 Text 渲染），
    // 由外层 [SelectionArea] 统一处理选中——若 MarkdownBody.selectable=true
    // 或 builder 返回 SelectableText，会与外层 SelectionArea 冲突导致
    // 文本无法选中（已用官方 selection_area_compatibility_test 逻辑验证）。
    final body = MarkdownBody(
      data: widget.data,
      styleSheet: _styleSheet!,
      onTapLink: widget.onTapLink,
      fitContent: true,
      extensionSet: GitHubMarkdownStyle.extensionSet,
      syntaxHighlighter: _syntaxHighlighter!,
      builders: GitHubMarkdownStyle.builders,
      checkboxBuilder: MarkdownPreview._buildCheckbox,
      bulletBuilder: (params) => MarkdownPreview._buildBullet(params, git),
      listItemCrossAxisAlignment: MarkdownListItemCrossAxisAlignment.baseline,
    );
    return widget.selectable ? SelectableTextArea(child: body) : body;
  }
}

/// 统一选中容器：外层 [SelectionArea] 负责跨块连续选中，选中后**自动弹出**
/// 「复制 / 全选」横排工具条（见 [_SelectionCopyToolbar]）。
///
/// **全应用唯一的可选中文本入口**：要「可选中 / 可复制」的展示文本一律用它，
/// 不要再引入 `SelectableText`（另一套 `EditableText` 选区，与作用域互斥、冷排版
/// 更慢）或裸 `SelectionArea`（会绕过自动工具条与作用域让位）。
///
/// [MarkdownPreview] 与 [PlainTextPreview] 共用；自定义组装的内容（如推荐行动
/// 选项行）把它当代理用即可（内部文本 `selectable: false`）。
///
/// **作用域内自动让位**：上层已有 [SelectableTextScope]（整块内容统一选中，如对话页
/// 消息列）时不再另建 [SelectionArea]——框架里两个 [SelectableRegion] 互为硬边界
/// （`widgets/selectable_region.dart:189-192`），嵌套会让「跨条目连续选中」失效。
/// 因此子组件无需知道自己在不在作用域内。
class SelectableTextArea extends StatelessWidget {
  const SelectableTextArea({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (_SelectableScopeMarker.isInside(context)) return child;
    return _SelectionCopyToolbar(child: child);
  }
}

/// 工具条「复制」项文案（[ContextMenuButtonItem.label] 优先于平台默认文案）。
const String _copyLabel = '复制';

/// 工具条「全选」项文案。
const String _selectAllLabel = '全选';

/// 鼠标 / 触控笔判定「拖拽选中」的最小位移。
///
/// 远小于触屏的 `kTouchSlop`：桌面上拖选一两个字符也只有几个像素，
/// 阈值过大会把这类选择误判成「原地单击」而不弹工具条。
const double _kPreciseDragSlop = 4;

/// 「选中即弹」的复制工具条。
///
/// **弹**：鼠标 / 触控笔拖拽选中、双击选词，触屏双击 / 三击选词（含双击后拖动
/// 扩展选区）——都在指针抬起、选区落定之后。
/// **不弹**：触屏长按归气泡业务菜单（复制正文 / 刷新本轮…），鼠标右键归业务右键
/// 菜单；原地单击只是收起选区，没有内容可复制。
///
/// 形态见 [SelectionToolbar]（恒为横排横条、不铺遮罩）；点条以外、滚动、选区被
/// 清空都会收起。改这里前先读两个坑：
/// - `showMenu` 不能用：它是模态路由，会夺走焦点，框架 `SelectableRegionState`
///   失焦即 `clearSelection()`（`widgets/selectable_region.dart:526-543`），刚框选
///   的区域会当场消失。所以用 [OverlayEntry] 自己挂（见 [_toolbarEntry]）。
/// - 桌面平台（Windows / macOS / Linux）在拖拽与双击结束后**不会**显示框架自带的
///   选中工具栏（`selectable_region.dart` 的 `_handleMouseDragEnd` /
///   `_handleMouseTapUp` 桌面分支直接 break），所以只能自己弹。
class _SelectionCopyToolbar extends StatefulWidget {
  const _SelectionCopyToolbar({required this.child});

  /// 选中区域的内容子树。
  final Widget child;

  @override
  State<_SelectionCopyToolbar> createState() => _SelectionCopyToolbarState();
}

class _SelectionCopyToolbarState extends State<_SelectionCopyToolbar> {
  /// 选中区域：用于「全选」与读取选区锚点。
  final GlobalKey<SelectionAreaState> _areaKey =
      GlobalKey<SelectionAreaState>();

  /// 当前选区文本（由 [SelectionArea.onSelectionChanged] 维护；空串 = 无选区）。
  String _selectedText = '';

  /// 正在显示的横排工具条（null = 未显示）。
  ///
  /// 用 [OverlayEntry] 而不是模态路由：不夺焦点（失焦会让框架清空选区）、不铺
  /// 遮罩，选区原样保留，用户还能接着拖手柄微调（详见类文档）。
  OverlayEntry? _toolbarEntry;

  /// 本次按下的设备类型与按键（判断该不该弹的关键输入）。
  PointerDeviceKind? _downKind;
  bool _downIsSecondaryMouse = false;
  Offset _downPosition = Offset.zero;

  /// 本次按下后的最大位移：用于区分「拖拽选中」与「原地单击」
  /// （单击只是收起选区，不该弹工具条）。
  double _dragDistance = 0;

  /// 上一次按下的时刻与位置（双击判定，鼠标与触屏同一口径）。
  Duration? _lastDownTime;
  Offset _lastDownPosition = Offset.zero;

  /// 本次按下是否为「双击的第二下」。
  bool _doubleTapCandidate = false;

  @override
  void dispose() {
    _hideToolbar();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _handlePointerDown,
      onPointerMove: _handlePointerMove,
      onPointerUp: _handlePointerUp,
      // 区域内滚轮（含触控板）：锚点位置随之失效，直接收起工具条。
      onPointerSignal: (_) => _hideToolbar(),
      child: NotificationListener<ScrollNotification>(
        // 选区底下的滚动（如对话页消息列）会让锚点漂移：收起工具条。
        onNotification: (notification) {
          if (notification is ScrollStartNotification ||
              notification is ScrollUpdateNotification) {
            _hideToolbar();
          }
          return false;
        },
        child: SelectionArea(
          key: _areaKey,
          // 框架自带工具栏照旧抑制：长按 / 右键归业务菜单（见类文档）。
          contextMenuBuilder: (context, selectableRegionState) =>
              const SizedBox.shrink(),
          onSelectionChanged: (content) {
            _selectedText = content?.plainText ?? '';
            // 选区被清掉（例如点别处）→ 工具条失去落点。
            if (_selectedText.trim().isEmpty) _hideToolbar();
          },
          child: widget.child,
        ),
      ),
    );
  }

  void _handlePointerDown(PointerDownEvent event) {
    _downKind = event.kind;
    _downIsSecondaryMouse = event.kind == PointerDeviceKind.mouse &&
        event.buttons == kSecondaryMouseButton;
    _downPosition = event.position;
    _dragDistance = 0;

    // 双击判定用「按下—按下」间隔（与框架的手势口径一致）。
    final now = SchedulerBinding.instance.currentSystemFrameTimeStamp;
    final last = _lastDownTime;
    _doubleTapCandidate = last != null &&
        now - last <= kDoubleTapTimeout &&
        (event.position - _lastDownPosition).distance <= kDoubleTapSlop;
    _lastDownTime = now;
    _lastDownPosition = event.position;
  }

  void _handlePointerMove(PointerMoveEvent event) {
    final distance = (event.position - _downPosition).distance;
    if (distance > _dragDistance) _dragDistance = distance;
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (_toolbarEntry != null) return;
    final device = _downKind ?? event.kind;
    final slop =
        device == PointerDeviceKind.touch ? kTouchSlop : _kPreciseDragSlop;
    final bool dragged = _dragDistance > slop;
    final bool doubleTapped = _doubleTapCandidate;
    // 触屏：只有双击（含「双击后拖动」扩展选区）才算选中文本，长按归业务菜单；
    // 鼠标 / 触控笔：拖拽选中、双击选词都弹，右键归业务菜单。
    final bool shouldShow = device == PointerDeviceKind.touch
        ? doubleTapped
        : !_downIsSecondaryMouse && (dragged || doubleTapped);

    _doubleTapCandidate = false;
    _downKind = null;
    if (!shouldShow) return;
    // 等本次事件分发结束（微任务）再弹：框架的「抬手」回调排在指针事件之后，
    // 选区到那时才是最终值。
    scheduleMicrotask(() {
      if (mounted) _showToolbar();
    });
  }

  /// 弹出横排工具条（选区为空时按需延后一个微任务再判断一次）。
  void _showToolbar() {
    if (_toolbarEntry != null) return;
    if (_selectedText.trim().isEmpty) {
      // 兜底：选区回调偶发排在指针事件之后（如拖到视口边缘时选区仍在滚动扩展）。
      scheduleMicrotask(() {
        if (mounted && _toolbarEntry == null && _selectedText.trim().isNotEmpty) {
          _showToolbar();
        }
      });
      return;
    }
    final OverlayState? overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    final entry = OverlayEntry(builder: _buildToolbar);
    _toolbarEntry = entry;
    overlay.insert(entry);
  }

  void _hideToolbar() {
    final entry = _toolbarEntry;
    if (entry == null) return;
    _toolbarEntry = null;
    if (entry.mounted) entry.remove();
  }

  /// 「复制 / 全选」横排工具条（外观与定位见 [SelectionToolbar]）。
  Widget _buildToolbar(BuildContext context) {
    final SelectableRegionState? region = _areaKey.currentState?.selectableRegion;
    if (region == null || _selectedText.trim().isEmpty) {
      return const SizedBox.shrink();
    }
    final TextSelectionToolbarAnchors anchors;
    try {
      anchors = region.contextMenuAnchors;
    } catch (_) {
      // 选区几何已消失（如刚被外部清空）：本帧留白，选区回调会收起工具条。
      return const SizedBox.shrink();
    }
    return TapRegion(
      // 点工具条之外即收起（不铺遮罩、不吃掉这次点击）。
      onTapOutside: (_) => _hideToolbar(),
      child: SelectionToolbar(
        anchors: anchors,
        items: [
          ContextMenuButtonItem(label: _copyLabel, onPressed: _copySelection),
          ContextMenuButtonItem(label: _selectAllLabel, onPressed: _selectAll),
        ],
      ),
    );
  }

  /// 复制当前选区（并收起工具条；选区保留，可继续操作）。
  void _copySelection() {
    final text = _selectedText;
    _hideToolbar();
    if (text.trim().isEmpty) return;
    unawaited(_copyToClipboard(text));
  }

  /// 全选：工具条保持显示（用户接着多半要「复制」）。
  ///
  /// 框架的 `selectAll` 内部会先 `clearSelection()`，那一次「选区清空」回调会
  /// 把工具条收掉；故等新选区落定后按新锚点重新弹回来（同一轮微任务内完成，
  /// 用户看不到闪动）。
  void _selectAll() {
    _areaKey.currentState?.selectableRegion
        .selectAll(SelectionChangedCause.toolbar);
    scheduleMicrotask(() {
      if (mounted) _showToolbar();
    });
  }

  /// 写入系统剪贴板，并给出与气泡「复制」同一口径的应用内提示。
  ///
  /// 通知中心取自上层 Provider：隔离用例等没有通知中心的环境下静默跳过。
  Future<void> _copyToClipboard(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    context
        .read<AppNoticeCenter?>()
        ?.success('已复制', dwell: const Duration(seconds: 1));
  }
}

/// 容器级选中作用域：为**整块内容**（如对话页消息列）建立唯一的
/// [SelectionArea]，使选区可以跨越子项边界（跨气泡连续选中）。
///
/// 作用域内的 [SelectableTextArea] 自动退化为普通包裹（见其文档），因此
/// 每个气泡 / 思考框 / 推荐行动各自都不再建区域；作用域**外**的调用点行为
/// 不变（各自一个区域）。
///
/// 与「列表 + 滚动」的协作由框架负责：`SelectableRegion` 之下的 [Scrollable]
/// 会自动注册选区滚动同步（`widgets/scrollable.dart:1062-1071`），拖动选区
/// 到视口边缘仍会自动滚动。
class SelectableTextScope extends StatelessWidget {
  const SelectableTextScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => SelectableTextArea(
        child: _SelectableScopeMarker(child: child),
      );
}

/// [SelectableTextScope] 的作用域标记：仅用于让下层 [SelectableTextArea]
/// 判断「上层是否已有统一选中区域」。
class _SelectableScopeMarker extends InheritedWidget {
  const _SelectableScopeMarker({required super.child});

  /// [context] 是否位于某个 [SelectableTextScope] 内。
  static bool isInside(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_SelectableScopeMarker>() !=
      null;

  @override
  bool updateShouldNotify(_SelectableScopeMarker oldWidget) => false;
}

/// 纯文本预览：与 [MarkdownPreview] 共用同一套选中约定，但**不做任何 Markdown
/// 解析**。
///
/// 用于「按纯文本渲染」的调用点。内容高频增长时（如生成中的思考框），全量
/// Markdown 解析与 widget 构树是纯开销；且 Markdown 的「段内单换行折叠为空格」
/// 规则会破坏原始分行。行为：
/// - 保留 `\n` 硬换行（不套用 Markdown 软换行规则）；
/// - 归一化 CRLF 并去掉末尾空行（末尾回车不占出一行高度，见 [_plainDisplayText]）；
/// - 归一化结果按内容缓存：父级每帧重建而内容不变时（如已完成的思考框在后续
///   流式增量中反复重建），不再重复付出 O(全文) 的归一化开销。
class PlainTextPreview extends StatefulWidget {
  /// 纯文本源内容。
  final String data;

  /// 正文基样式（默认主题 `bodyMedium`，可覆盖字号/行高）。
  final TextStyle? base;

  /// 是否允许文本选中。默认 true（启用 [SelectionArea]）。
  final bool selectable;

  const PlainTextPreview({
    super.key,
    required this.data,
    this.base,
    this.selectable = true,
  });

  @override
  State<PlainTextPreview> createState() => _PlainTextPreviewState();
}

class _PlainTextPreviewState extends State<PlainTextPreview> {
  /// 归一化后的展示文本（随 [PlainTextPreview.data] 变化重算）。
  late String _text = _plainDisplayText(widget.data);

  @override
  void didUpdateWidget(covariant PlainTextPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data != widget.data) {
      _text = _plainDisplayText(widget.data);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Text(
      _text,
      style: widget.base ?? Theme.of(context).textTheme.bodyMedium,
    );
    return widget.selectable ? SelectableTextArea(child: text) : text;
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
          child: Text.rich(
            _nodesToSpans(context, el.children ?? const <md.Node>[], git, base),
            style: base,
          ),
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
            child: Text.rich(
              _nodesToSpans(
                context,
                li.children ?? const <md.Node>[],
                git,
                base,
              ),
              style: base,
            ),
          ),
        ],
      ),
    );
  }

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

/// 内联 Markdown 的共享解析器（与 [MarkdownPreview] 同一套语法与 `encodeHtml`）。
///
/// 语法对象无状态、[md.Document.parseInline] 只读取语法表，故全局共享一份，
/// 避免每次构建都为「选项行内联内容」重新装配一遍语法集合。
final md.Document _inlineMarkdownDocument = md.Document(
  extensionSet: GitHubMarkdownStyle.extensionSet,
  encodeHtml: false,
);

/// 内联节点列表 → [InlineSpan]（strong / em / code / del / a / mark 递归）。
///
/// [MarkdownPreview.buildInlineSpans] 与 [_AlertBlockBuilder] 共用，
/// 保证「自行组装 `Text.rich`」的调用点与 [MarkdownPreview] 的内联观感一致。
InlineSpan _nodesToSpans(
  BuildContext context,
  List<md.Node> nodes,
  GitHubPalette git,
  TextStyle? base,
) {
  final children = <InlineSpan>[];
  for (final node in nodes) {
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
    children: [
      _nodesToSpans(context, el.children ?? const <md.Node>[], git, base),
    ],
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
