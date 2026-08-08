import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/book.dart';
import '../models/round.dart';
import '../providers/book_provider.dart';
import '../providers/round_provider.dart';
import '../providers/sidebar_provider.dart';
import '../providers/world_book_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/ai_bubble_actions.dart';
import '../widgets/app_menu.dart';
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

class _ChatScreenState extends State<ChatScreen>
    with SingleTickerProviderStateMixin {
  final TextEditingController _inputController = TextEditingController();
  final TextEditingController _tempPreController = TextEditingController();
  final TextEditingController _tempPostController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  bool _showTempPrompts = false;
  bool _drawerOpen = false;

  /// 宽屏右侧栏开合动画控制器（0=收起，1=展开；初始 0，首帧后滑入入场）。
  late final AnimationController _sidebarController;
  late final Animation<double> _sidebarAnim;

  /// 右侧栏是否展开（以动画进度 0.5 为界）。
  bool get _sidebarOpen => _sidebarController.value > 0.5;

  @override
  void initState() {
    super.initState();
    _sidebarController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
      value: 1, // 默认展开（不依赖入场动画，避免初始隐藏导致“空白”观感）。
    );
    _sidebarAnim = CurvedAnimation(
      parent: _sidebarController,
      curve: Curves.easeOutCubic,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final book = context.read<BookProvider>().currentBook;
      if (book != null) {
        context.read<RoundProvider>().loadRounds(book.id!);
        // 加载当前书籍的世界书条目（供关键词扫描注入 System Prompt）。
        context.read<WorldBookProvider>().loadEntries(book.id!);
      }
    });
  }

  /// 展开 / 收起右侧栏（带动画）。
  void _setSidebarOpen(bool open) {
    if (open && _sidebarController.value < 1) {
      _sidebarController.forward();
    } else if (!open && _sidebarController.value > 0) {
      _sidebarController.reverse();
    }
    // 刷新「打开侧栏」按钮等随状态变化的 UI。
    setState(() {});
  }

  @override
  void dispose() {
    _sidebarController.dispose();
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

    if (!ok && mounted && roundProvider.error != null) {
      // 请求失败：恢复输入并提示错误（用户主动中断时不提示）。
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
    if (_isWide) {
      // 宽屏：若右侧栏已收起则带动画打开。
      if (!_sidebarOpen) {
        _setSidebarOpen(true);
      }
    } else if (!_drawerOpen) {
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
      rawReasoning: rp.debugRawReasoning,
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
          child: AppMenuAction(icon: Icons.edit_outlined, label: '编辑正文'),
        ),
      ] else ...[
        const PopupMenuItem(
          value: 'editInput',
          child: AppMenuAction(icon: Icons.edit_outlined, label: '编辑输入'),
        ),
        const PopupMenuItem(
          value: 'editReask',
          child: AppMenuAction(
            icon: Icons.edit_note,
            label: '修改并重新提问',
          ),
        ),
      ],
      PopupMenuItem(
        value: 'copy',
        child: AppMenuAction(
          icon: Icons.copy_outlined,
          label: isAi ? '复制正文' : '复制内容',
        ),
      ),
      const PopupMenuItem(
        value: 'reask',
        child: AppMenuAction(icon: Icons.replay, label: '重新提问'),
      ),
      if (isAi) ...[
        const PopupMenuItem(
          value: 'sidebar',
          child: AppMenuAction(icon: Icons.view_sidebar_outlined, label: '查看侧边栏'),
        ),
        if (isLatest)
          const PopupMenuItem(
            value: 'debug',
            child: AppMenuAction(icon: Icons.bug_report_outlined, label: '调试'),
          ),
        const PopupMenuItem(
          value: 'delete',
          child: AppMenuAction(
            icon: Icons.delete_outline,
            label: '删除本轮',
            color: Color(0xFFE5484D),
          ),
        ),
      ],
    ];

    showAppMenu<String>(
      context: context,
      position: position,
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
        final sidebar = _buildSidebar(
          context,
          onClose: wide
              ? () => _setSidebarOpen(false)
              : () => setState(() => _drawerOpen = false),
        );

        if (wide) {
          // 关键设计：聊天区宽度固定（W-380）永不重排 → 滚动条不乱飞、动画不卡顿；
          // 右侧栏独占固定 380 槽位，用 SlideTransition 从右缘滑入/滑出（不覆盖、不空白）。
          // 用 AnimatedBuilder 逐帧驱动，使「打开侧栏」按钮随动画进度正确显隐。
          return AnimatedBuilder(
            animation: _sidebarController,
            builder: (context, _) {
              final open = _sidebarOpen;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 聊天区：固定宽度，绝不因侧栏开合而重排。
                  Expanded(child: chat),
                  // 右侧栏固定槽位（380px）。
                  SizedBox(
                    width: 380,
                    child: Stack(
                      children: [
                        // 收起时：居中显示「打开侧栏」按钮。
                        if (!open)
                          Center(
                            child: Material(
                              color: const Color(0xFFF4F4F5),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(12),
                                onTap: () => _setSidebarOpen(true),
                                child: const Padding(
                                  padding: EdgeInsets.symmetric(
                                      horizontal: 16, vertical: 12),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.view_sidebar_outlined,
                                        color: NarrChatTheme.textSecondary,
                                        size: 20,
                                      ),
                                      SizedBox(height: 6),
                                      Text(
                                        '打开侧栏',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: NarrChatTheme.textSecondary,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        // 侧栏：value=1 时在槽位内原位（可见），value=0 时滑出右侧（裁剪隐藏）。
                        // 固定 key：避免条件按钮增删导致元素重建、丢失动画。
                        ClipRect(
                          key: const Key('sidebar_panel_clip'),
                          child: SlideTransition(
                            key: const Key('sidebar_panel_slide'),
                            position: Tween<Offset>(
                              begin: const Offset(1, 0),
                              end: Offset.zero,
                            ).animate(_sidebarAnim),
                            child: Material(elevation: 12, child: sidebar),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
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
              // 固定 key：避免遮罩/FAB 条件渲染导致元素索引变化而重建、丢失动画。
              key: const Key('right_sidebar_drawer'),
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
    // 生成期间不隐藏用户刚发送的文本：作为用户气泡展示在流式气泡之前。
    final pendingInput = roundProvider.pendingUserInput;
    final showPendingUser = showPending && pendingInput.isNotEmpty;

    // 流式输出时若用户位于底部附近（未主动上翻阅读历史），自动跟随新内容，
    // 避免内容不断增长造成视口漂移、滚动条位置飘忽的“不稳定滚动”观感。
    // 仅在帧末执行 jumpTo（非动画），不会与用户手动滚动/动画滚动冲突。
    if (showPending && _scrollController.hasClients) {
      final pos = _scrollController.position;
      if (pos.pixels >= pos.maxScrollExtent - 80.0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients) {
            _scrollController.jumpTo(
              _scrollController.position.maxScrollExtent,
            );
          }
        });
      }
    }

    // 消息列：ListView 铺满整个对话主屏（全屏可滚动、鼠标任意位置可滚），
    // 每条消息在内部居中限宽（视觉上限制在 760 内）；
    // 左右留 20px 边距，避免内容在窄窗口下贴边（滚动条在最右，不计入边距）。
    final messagesList = ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
      itemCount: chatRounds.length * 2 +
          (showPending ? 1 : 0) +
          (showPendingUser ? 1 : 0),
      itemBuilder: (context, index) {
        Widget item;
        // 生成中的用户气泡（未落库，紧跟历史消息之后）。
        if (showPendingUser && index == chatRounds.length * 2) {
          item = Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: ChatBubble(
              isUser: true,
              text: pendingInput,
            ),
          );
        } else if (showPending &&
            index == chatRounds.length * 2 + (showPendingUser ? 1 : 0)) {
          item = isStreaming
              ? _StreamingBubble(
                  content: roundProvider.streamingContent,
                  reasoning: roundProvider.streamingReasoning,
                )
              : const _TypingBubble();
        } else {
          final round = chatRounds[index ~/ 2];
          final isAi = index.isOdd;
          // 调试数据仅保留最新一轮：只有最新 AI 气泡提供「调试」入口。
          final isLatest =
              chatRounds.isNotEmpty && round.id == chatRounds.last.id;
          if (!isAi) {
            item = Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: ChatBubble(
                isUser: true,
                text: round.userInput,
                onContextMenu: (pos) =>
                    _onBubbleContextMenu(round, isAi, pos),
              ),
            );
          } else {
            item = Padding(
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
          }
        }
        // 每条消息居中限宽（视觉约束），滚动区域仍为全屏。
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: item,
          ),
        );
      },
    );

    return Column(
      children: [
        Expanded(
          child: Container(
            // 与各边栏一致的纯白背景。
            color: Colors.white,
            child: chatRounds.isEmpty && !showPending
                ? _buildEmptyState(context, bookProvider.currentBook)
                // 原生滚动条（主题已统一为常显细圆角拇指），流式/滚动自动跟随。
                : messagesList,
          ),
        ),
        _buildComposer(context),
      ],
    );
  }

  /// 空状态：DeepSeek 风格问候 + 建议指令卡片。
  Widget _buildEmptyState(BuildContext context, Book? book) {
    final suggestions = [
      ('✍️ 写出开篇', '请以引人入胜的方式，写出本故事的开篇。'),
      ('🎬 推进剧情', '请继续推进剧情，让情节更加精彩。'),
      ('⚡ 制造转折', '请为本轮剧情安排一个意想不到的转折。'),
      ('🔍 检查一致性', '请检查当前剧情与世界设定、角色状态是否一致，如有冲突请指出。'),
    ];
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      gradient: NarrChatTheme.brandGradient,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: const Icon(Icons.auto_awesome,
                        size: 19, color: Colors.white),
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    'NarrChat',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: NarrChatTheme.textPrimary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Text(
                book == null ? '你好，我是 NarrChat，你的专属剧情创作引擎' : '《${book.title}》的创作，从这里开始',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: NarrChatTheme.textPrimary,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '先在右侧「第 0 轮」侧边栏设定世界状态与角色状态，\n再输入行动或对话指令，开始推进剧情。',
                style: TextStyle(
                  fontSize: 13,
                  color: NarrChatTheme.textSecondary,
                  height: 1.6,
                ),
              ),
              const SizedBox(height: 24),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final s in suggestions)
                    Material(
                      color: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: const BorderSide(color: NarrChatTheme.divider),
                      ),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => _inputController.text = s.$2,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 10),
                          child: Text(
                            s.$1,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: NarrChatTheme.textPrimary,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 输入区：DeepSeek 风格——居中圆角输入框 + 圆形发送按钮 + 底部提示。
  Widget _buildComposer(BuildContext context) {
    final roundProvider = context.watch<RoundProvider>();
    final isSending = roundProvider.isSending;

    final composerColumn = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 本轮临时指令开关（类似 DeepSeek 的功能开关行）
              Row(
                mainAxisAlignment: MainAxisAlignment.start,
                children: [
                  TextButton.icon(
                    onPressed: () =>
                        setState(() => _showTempPrompts = !_showTempPrompts),
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
                  // 滚动到底部
                  TextButton.icon(
                    onPressed: _scrollToBottom,
                    icon: const Icon(
                      Icons.vertical_align_bottom,
                      size: 16,
                    ),
                    label: const Text('滚动到底部'),
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
              // 圆角输入容器 + 发送按钮
              Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: NarrChatTheme.divider),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _inputController,
                        minLines: 1,
                        maxLines: 5,
                        style: const TextStyle(
                          fontSize: 15,
                          height: 1.5,
                          color: NarrChatTheme.textPrimary,
                        ),
                        decoration: const InputDecoration(
                          hintText: '输入你的行动或对话…',
                          hintStyle: TextStyle(color: Color(0xFF9CA1A9)),
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          filled: false,
                          contentPadding:
                              EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        ),
                        onSubmitted: (_) => _send(),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(right: 8, bottom: 8),
                      child: SizedBox(
                        width: 36,
                        height: 36,
                        child: IconButton.filled(
                          // 生成中：点击中断生成（仍显示加载图标）；空闲：发送。
                          onPressed: isSending
                              ? roundProvider.cancelGeneration
                              : _send,
                          tooltip: isSending ? '停止生成' : '发送',
                          style: IconButton.styleFrom(
                            backgroundColor: NarrChatTheme.primary,
                            disabledBackgroundColor:
                                const Color(0xFFD3D5DA),
                          ),
                          icon: isSending
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.arrow_upward,
                                  size: 18, color: Colors.white),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                '内容由 AI 生成，仅供创作参考，请仔细甄别',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: NarrChatTheme.textSecondary),
              ),
            ],
      ),
    );

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: NarrChatTheme.divider)),
      ),
      child: Center(child: composerColumn),
    );
  }

  // ---------------------------------------------------------------------------
  // 侧边栏
  // ---------------------------------------------------------------------------
  Widget _buildSidebar(BuildContext context, {VoidCallback? onClose}) {
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
      onClose: onClose,
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

/// AI 正在创作中的指示（极简，无气泡）。
class _TypingBubble extends StatelessWidget {
  const _TypingBubble();

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              gradient: NarrChatTheme.brandGradient,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.auto_awesome,
                size: 16, color: Colors.white),
          ),
          const SizedBox(width: 10),
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: NarrChatTheme.primary,
            ),
          ),
          const SizedBox(width: 8),
          const Text(
            'AI 正在创作…',
            style: TextStyle(
              color: NarrChatTheme.textSecondary,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

/// AI 流式输出气泡：实时显示剧情正文；思考内容默认折叠，
/// 通过「思考中」提示点击展开查看（内容非斜体）。极简无气泡样式。
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
    final maxWidth = MediaQuery.sizeOf(context).width * 0.8;
    final content = widget.content;
    final reasoning = widget.reasoning;
    final hasContent = content.isNotEmpty;
    final hasReasoning = reasoning.isNotEmpty;

    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth.clamp(240, 680)),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                gradient: NarrChatTheme.brandGradient,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.auto_awesome,
                  size: 16, color: Colors.white),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 思考区：默认折叠，点击「思考中」展开。
                  if (hasReasoning) ...[
                    InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: () =>
                          setState(() => _reasoningExpanded = !_reasoningExpanded),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _reasoningExpanded
                                  ? Icons.expand_more
                                  : Icons.chevron_right,
                              size: 16,
                              color: NarrChatTheme.primary,
                            ),
                            const Icon(Icons.psychology_outlined,
                                size: 14, color: NarrChatTheme.primary),
                            const SizedBox(width: 4),
                            const Text(
                              '思考中',
                              style: TextStyle(
                                fontSize: 12,
                                color: NarrChatTheme.primary,
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
                              style: const TextStyle(
                                fontSize: 11,
                                color: NarrChatTheme.textSecondary,
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
                        style: const TextStyle(
                          fontSize: 13,
                          height: 1.5,
                          color: NarrChatTheme.textSecondary,
                        ),
                      ),
                    ],
                    if (hasContent) const Divider(height: 14),
                  ],
                  if (hasContent)
                    SelectableText(
                      '$content▍',
                      style: const TextStyle(
                        fontSize: 15,
                        height: 1.65,
                        color: NarrChatTheme.textPrimary,
                      ),
                    )
                  else if (!hasReasoning)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        SizedBox(width: 8),
                        Text(
                          'AI 正在创作…',
                          style: TextStyle(
                            color: NarrChatTheme.textSecondary,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

