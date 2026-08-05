import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/book.dart';
import '../models/round.dart';
import '../providers/book_provider.dart';
import '../providers/round_provider.dart';
import '../providers/sidebar_provider.dart';
import '../providers/world_book_provider.dart';
import '../widgets/ai_bubble_actions.dart';
import '../widgets/chat_bubble.dart';
import '../widgets/debug_prompt_dialog.dart';
import '../widgets/round_action_dialogs.dart';
import '../widgets/sidebar_panel.dart';

/// 对话界面（书籍已选定后显示）。
///
/// - 桌面端（宽屏）：左右两栏布局，左侧主对话区，右侧侧边栏。
/// - 移动端（窄屏）：主对话区全屏，侧边栏为从右向左滑出的抽屉，
///   通过悬浮按钮呼出。
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _inputController = TextEditingController();
  final TextEditingController _tempPreController = TextEditingController();
  final TextEditingController _tempPostController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  bool _showTempPrompts = false;
  bool _drawerOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final book = context.read<BookProvider>().currentBook;
      if (book != null) {
        context.read<RoundProvider>().loadRounds(book.id!);
        // 加载当前书籍的世界书条目（供关键词扫描注入 System Prompt）。
        context.read<WorldBookProvider>().loadEntries(book.id!);
      }
    });
  }

  @override
  void dispose() {
    _inputController.dispose();
    _tempPreController.dispose();
    _tempPostController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _send() async {
    final input = _inputController.text.trim();
    if (input.isEmpty) return;
    final book = context.read<BookProvider>().currentBook;
    if (book == null) return;

    _inputController.clear();
    _scrollToBottom();

    final roundProvider = context.read<RoundProvider>();
    final ok = await roundProvider.sendRound(
      userInput: input,
      tempPrePrompt: _tempPreController.text,
      tempPostPrompt: _tempPostController.text,
      book: book,
    );

    if (!ok && mounted) {
      // 请求失败：恢复输入并提示错误。
      _inputController.text = input;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('请求失败：${roundProvider.error ?? '未知错误'}'),
          duration: const Duration(seconds: 4),
        ),
      );
    }
    _scrollToBottom();
  }

  void _onViewSidebar(Round round) {
    final rounds = context.read<RoundProvider>().rounds;
    final latest = rounds.isEmpty ? null : rounds.last;
    context.read<SidebarProvider>().showRound(round, latest);
    if (!_isWide && !_drawerOpen) {
      setState(() => _drawerOpen = true);
    }
  }

  Future<void> _handleDelete(Round round) async {
    final choice = await showDeleteRoundDialog(context, round);
    if (choice == null || !mounted) return;
    await context.read<RoundProvider>().deleteRound(
          round,
          deleteFollowing: choice == DeleteRoundChoice.all,
        );
  }

  /// 查看最新一轮的调试信息（发送的 Prompt 与 AI 原始返回）。
  void _showDebugDialog() {
    final rp = context.read<RoundProvider>();
    DebugPromptDialog.show(
      context,
      requestBody: rp.debugRequestBody,
      rawResponse: rp.debugRawResponse,
    );
  }

  /// 长按 / 右键气泡触发的上下文菜单。
  void _onBubbleContextMenu(Round round, bool isAi, Offset position) {
    final rp = context.read<RoundProvider>();
    final chatRounds = rp.rounds.where((r) => r.roundIndex > 0).toList();
    final isLatest = chatRounds.isNotEmpty && round.id == chatRounds.last.id;

    final items = <PopupMenuEntry<String>>[
      if (isAi) ...[
        const PopupMenuItem(
          value: 'edit',
          child: _MenuAction(icon: Icons.edit_outlined, label: '编辑正文'),
        ),
      ] else ...[
        const PopupMenuItem(
          value: 'editInput',
          child: _MenuAction(icon: Icons.edit_outlined, label: '编辑输入'),
        ),
        const PopupMenuItem(
          value: 'editReask',
          child: _MenuAction(
            icon: Icons.edit_note,
            label: '修改并重新提问',
          ),
        ),
      ],
      PopupMenuItem(
        value: 'copy',
        child: _MenuAction(
          icon: Icons.copy_outlined,
          label: isAi ? '复制正文' : '复制内容',
        ),
      ),
      const PopupMenuItem(
        value: 'reask',
        child: _MenuAction(icon: Icons.replay, label: '重新提问'),
      ),
      if (isAi) ...[
        const PopupMenuItem(
          value: 'sidebar',
          child: _MenuAction(icon: Icons.view_sidebar_outlined, label: '查看侧边栏'),
        ),
        if (isLatest)
          const PopupMenuItem(
            value: 'debug',
            child: _MenuAction(icon: Icons.bug_report_outlined, label: '调试'),
          ),
        const PopupMenuItem(
          value: 'delete',
          child: _MenuAction(
            icon: Icons.delete_outline,
            label: '删除本轮',
            color: Color(0xFFE5484D),
          ),
        ),
      ],
    ];

    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: items,
    ).then((value) {
      if (value == null || !mounted) return;
      switch (value) {
        case 'edit':
          _showEditTextDialog(
            title: '编辑正文（第 ${round.roundIndex} 轮）',
            initial: round.aiNarrative,
            onSave: (text) =>
                context.read<RoundProvider>().updateNarrative(round.id!, text),
          );
        case 'editInput':
          _showEditTextDialog(
            title: '编辑输入（第 ${round.roundIndex} 轮）',
            initial: round.userInput,
            onSave: (text) =>
                context.read<RoundProvider>().updateUserInput(round.id!, text),
          );
        case 'editReask':
          _handleEditAndReAsk(round);
        case 'copy':
          _copyBubbleText(round, isAi);
        case 'reask':
          _handleReAsk(round);
        case 'sidebar':
          _onViewSidebar(round);
        case 'debug':
          _showDebugDialog();
        case 'delete':
          _handleDelete(round);
      }
    });
  }

  /// 复制气泡内容到剪贴板。
  void _copyBubbleText(Round round, bool isAi) {
    final text = isAi ? round.aiNarrative : round.userInput;
    Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已复制'), duration: Duration(seconds: 1)),
      );
    }
  }

  /// 通用文本编辑对话框。
  Future<void> _showEditTextDialog({
    required String title,
    required String initial,
    required Future<void> Function(String text) onSave,
  }) async {
    final controller = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 560,
          child: TextField(
            controller: controller,
            maxLines: null,
            minLines: 10,
            style: const TextStyle(fontSize: 13, height: 1.5),
            decoration: const InputDecoration(hintText: '内容'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result != null && mounted) {
      await onSave(result);
    }
  }

  /// 修改用户输入并重新提问：先编辑该轮输入，保存后删除本轮及后续所有轮次，
  /// 再以修改后的输入重新生成（替换而非追加）。
  Future<void> _handleEditAndReAsk(Round round) async {
    final book = context.read<BookProvider>().currentBook;
    if (book == null) return;
    String? edited;
    await _showEditTextDialog(
      title: '修改并重新提问（第 ${round.roundIndex} 轮）',
      initial: round.userInput,
      onSave: (text) async {
        edited = text;
        await context.read<RoundProvider>().updateUserInput(round.id!, text);
      },
    );
    if (edited == null || !mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改并重新提问'),
        content: Text(
          '将删除本轮及之后的所有轮次，并以修改后的输入重新生成第 ${round.roundIndex} 轮。是否继续？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('继续'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await context.read<RoundProvider>().editAndReAsk(round, edited!, book: book);
    _scrollToBottom();
  }

  /// 重新提问（与「刷新本轮」合并）：删除本轮及后续所有轮次，
  /// 再以该轮的用户输入重新请求 AI（替换而非追加）。
  Future<void> _handleReAsk(Round round) async {
    final ok = await showReAskConfirmDialog(context, round);
    if (!ok || !mounted) return;
    final book = context.read<BookProvider>().currentBook;
    if (book == null) return;
    await context.read<RoundProvider>().refreshRound(round, book: book);
    _scrollToBottom();
  }

  bool get _isWide {
    final size = MediaQuery.sizeOf(context);
    return size.width >= 900;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 900;
        final chat = _buildChatArea(context);
        final sidebar = _buildSidebar(context);

        if (wide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: chat),
              SizedBox(
                width: 380,
                child: sidebar,
              ),
            ],
          );
        }

        // 移动端：抽屉布局。
        final drawerWidth = constraints.maxWidth * 0.88;
        return Stack(
          children: [
            chat,
            if (_drawerOpen)
              Positioned.fill(
                child: GestureDetector(
                  onTap: () => setState(() => _drawerOpen = false),
                  child: Container(color: Colors.black26),
                ),
              ),
            AnimatedPositioned(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              top: 0,
              bottom: 0,
              right: _drawerOpen ? 0 : -drawerWidth,
              width: drawerWidth,
              child: Material(
                elevation: 12,
                child: sidebar,
              ),
            ),
            if (!_drawerOpen)
              Positioned(
                right: 16,
                bottom: 110,
                child: FloatingActionButton.small(
                  heroTag: 'sidebar_fab',
                  onPressed: () => setState(() => _drawerOpen = true),
                  tooltip: '打开状态侧边栏',
                  child: const Icon(Icons.view_sidebar_outlined),
                ),
              ),
          ],
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // 对话区
  // ---------------------------------------------------------------------------
  Widget _buildChatArea(BuildContext context) {
    final roundProvider = context.watch<RoundProvider>();
    final bookProvider = context.watch<BookProvider>();
    final rounds = roundProvider.rounds;
    // 第零轮（初始状态）不参与气泡展示。
    final chatRounds = rounds.where((r) => r.roundIndex > 0).toList();
    final isSending = roundProvider.isSending;
    final isStreaming = roundProvider.isStreaming;
    final showPending = isSending || isStreaming;

    return Column(
      children: [
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Theme.of(context).colorScheme.surfaceContainerLowest,
                  const Color(0xFFF7F5FB),
                ],
              ),
            ),
            child: chatRounds.isEmpty && !showPending
                ? _buildEmptyState(context, bookProvider.currentBook)
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(16),
                    itemCount: chatRounds.length * 2 + (showPending ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (showPending && index == chatRounds.length * 2) {
                        return isStreaming
                            ? _StreamingBubble(
                                content: roundProvider.streamingContent,
                                reasoning: roundProvider.streamingReasoning,
                              )
                            : const _TypingBubble();
                      }
                      final round = chatRounds[index ~/ 2];
                      final isAi = index.isOdd;
                      // 调试数据仅保留最新一轮：只有最新 AI 气泡提供「调试」入口。
                      final isLatest =
                          chatRounds.isNotEmpty && round.id == chatRounds.last.id;
                      if (!isAi) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: ChatBubble(
                            isUser: true,
                            text: round.userInput,
                            onContextMenu: (pos) =>
                                _onBubbleContextMenu(round, isAi, pos),
                          ),
                        );
                      }
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 20),
                        child: ChatBubble(
                          isUser: false,
                          text: round.aiNarrative.isEmpty
                              ? '（AI 未返回剧情正文）'
                              : round.aiNarrative,
                          recommendedAction: round.recommendedAction,
                          onContextMenu: (pos) =>
                              _onBubbleContextMenu(round, isAi, pos),
                          footer: AiBubbleActions(
                            round: round,
                            onViewSidebar: () => _onViewSidebar(round),
                            onDelete: () => _handleDelete(round),
                            onRefresh: () => _handleReAsk(round),
                            onViewDebug: isLatest ? _showDebugDialog : null,
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ),
        _buildComposer(context),
      ],
    );
  }

  Widget _buildEmptyState(BuildContext context, Book? book) {
    final theme = Theme.of(context);
    return Center(
      child: Container(
        margin: const EdgeInsets.all(32),
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 28),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    theme.colorScheme.primary.withValues(alpha: 0.15),
                    theme.colorScheme.tertiary.withValues(alpha: 0.15),
                  ],
                ),
              ),
              child: Icon(
                Icons.auto_stories_outlined,
                size: 36,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              book == null ? '尚未选择书籍' : '《${book.title}》的创作从这里开始',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              '建议先在右侧「第 0 轮」侧边栏填写世界状态与角色状态，\n再输入剧情指令开始创作',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: theme.colorScheme.outline,
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildComposer(BuildContext context) {
    final roundProvider = context.watch<RoundProvider>();
    final isSending = roundProvider.isSending;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 12,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 本轮临时指令开关
          Row(
            children: [
              TextButton.icon(
                onPressed: () => setState(() => _showTempPrompts = !_showTempPrompts),
                icon: Icon(
                  _showTempPrompts ? Icons.expand_less : Icons.tune,
                  size: 16,
                ),
                label: const Text('本轮临时指令'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  textStyle: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
          if (_showTempPrompts) ...[
            TextField(
              controller: _tempPreController,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: '本轮临时前置词',
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _tempPostController,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: '本轮临时后置词',
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: _inputController,
                  minLines: 1,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    hintText: '输入你的行动或对话…',
                    isDense: true,
                  ),
                  onSubmitted: (_) => _send(),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 46,
                height: 46,
                child: IconButton.filled(
                  onPressed: isSending ? null : _send,
                  tooltip: '发送',
                  icon: isSending
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.send),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 侧边栏
  // ---------------------------------------------------------------------------
  Widget _buildSidebar(BuildContext context) {
    final roundProvider = context.watch<RoundProvider>();
    final sidebarProvider = context.watch<SidebarProvider>();
    final rounds = roundProvider.rounds;
    final latest = rounds.isEmpty ? null : rounds.last;

    final viewedRound = sidebarProvider.isHistoryView
        ? (rounds.where((r) => r.id == sidebarProvider.historyRoundId).isNotEmpty
            ? rounds.firstWhere((r) => r.id == sidebarProvider.historyRoundId)
            : latest)
        : latest;

    return SidebarPanel(
      key: ValueKey(viewedRound?.id),
      round: viewedRound,
      isHistoryView: sidebarProvider.isHistoryView && viewedRound != null,
      onBackToCurrent: () => context.read<SidebarProvider>().showCurrent(),
      onAutoSaveField: (round, field, value) async {
        await context.read<RoundProvider>().updateRoundField(
              round.id!,
              field,
              value,
            );
      },
    );
  }
}

/// AI 正在创作中的气泡。
class _TypingBubble extends StatelessWidget {
  const _TypingBubble();

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.secondaryContainer.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Text(
              'AI 正在创作…',
              style: TextStyle(color: Theme.of(context).colorScheme.onSecondaryContainer),
            ),
          ],
        ),
      ),
    );
  }
}

/// AI 流式输出气泡：实时显示剧情正文；思考内容默认折叠，
/// 通过「思考中」提示点击展开查看（内容非斜体）。
class _StreamingBubble extends StatefulWidget {
  final String content;
  final String reasoning;

  const _StreamingBubble({required this.content, required this.reasoning});

  @override
  State<_StreamingBubble> createState() => _StreamingBubbleState();
}

class _StreamingBubbleState extends State<_StreamingBubble> {
  bool _reasoningExpanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxWidth = MediaQuery.sizeOf(context).width * 0.78;
    final content = widget.content;
    final reasoning = widget.reasoning;
    final hasContent = content.isNotEmpty;
    final hasReasoning = reasoning.isNotEmpty;

    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth.clamp(240, 560)),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.45),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(12),
              topRight: Radius.circular(12),
              bottomLeft: Radius.circular(12),
              bottomRight: Radius.circular(4),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // 思考区：默认折叠，点击「思考中」展开。
              if (hasReasoning) ...[
                InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => setState(() => _reasoningExpanded = !_reasoningExpanded),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _reasoningExpanded ? Icons.expand_more : Icons.chevron_right,
                          size: 16,
                          color: theme.colorScheme.primary,
                        ),
                        Icon(Icons.psychology_outlined,
                            size: 14, color: theme.colorScheme.primary),
                        const SizedBox(width: 4),
                        Text(
                          '思考中',
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(width: 6),
                        if (!hasContent) ...[
                          const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 4),
                        ],
                        Text(
                          _reasoningExpanded ? '收起' : '点击查看',
                          style: TextStyle(
                            fontSize: 11,
                            color: theme.colorScheme.outline,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_reasoningExpanded) ...[
                  const SizedBox(height: 2),
                  SelectableText(
                    reasoning,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.5,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                if (hasContent) const Divider(height: 14),
              ],
              if (hasContent)
                SelectableText(
                  '$content▍',
                  style: const TextStyle(fontSize: 15, height: 1.5),
                )
              else if (!hasReasoning)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'AI 正在创作…',
                      style: TextStyle(color: theme.colorScheme.outline, fontSize: 13),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 上下文菜单项（图标 + 文字）。
class _MenuAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? color;

  const _MenuAction({required this.icon, required this.label, this.color});

  @override
  Widget build(BuildContext context) {
    final fg = color ?? Theme.of(context).colorScheme.onSurface;
    return Row(
      children: [
        Icon(icon, size: 18, color: fg),
        const SizedBox(width: 10),
        Text(label, style: TextStyle(fontSize: 13, color: fg)),
      ],
    );
  }
}

