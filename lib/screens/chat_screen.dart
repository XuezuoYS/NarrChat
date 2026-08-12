import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/agent_event.dart';
import '../models/book.dart';
import '../models/round.dart';
import '../providers/ai_settings_provider.dart';
import '../providers/book_provider.dart';
import '../providers/round_provider.dart';
import '../providers/sidebar_provider.dart';
import '../providers/world_book_provider.dart';
import '../services/html_search_service.dart';
import '../theme/app_theme.dart';
import '../utils/focus_utils.dart';
import '../widgets/ai_bubble_actions.dart';
import '../widgets/app_menu.dart';
import '../widgets/brand_logo.dart';
import '../widgets/chat_bubble.dart';
import '../widgets/failed_attempt_bubble.dart';
import '../widgets/markdown_editing_controller.dart';
import '../widgets/raw_dialog.dart';
import '../widgets/round_action_dialogs.dart';
import '../widgets/sidebar_panel.dart';
import 'book_settings_screen.dart';
import 'settings_screen.dart';

/// 宽屏（桌面端）断点：宽度 ≥ 此值时使用左右双栏布局。
const double _kWideBreakpoint = 900;

/// 右侧栏固定宽度。
const double _kSidebarWidth = 380;

/// 消息与输入框的最大内容宽度。
const double _kContentMaxWidth = 760;

/// 流式自动跟随滚动：距底部小于该距离视为「位于底部」。
const double _kAutoScrollThreshold = 80;

/// 右侧栏开合动画时长。
const Duration _kSidebarAnimDuration = Duration(milliseconds: 300);

/// 移动端抽屉动画时长。
const Duration _kDrawerAnimDuration = Duration(milliseconds: 260);

/// 侧栏开合进度阈值（进度大于该值视为展开）。
const double _kSidebarOpenThreshold = 0.5;

/// 移动端悬浮按钮距底部距离。
const double _kFabBottom = 110;

/// 滑动手势触发速度阈值（px/s）：横向快速甩动超过该值视为一次有效滑动。
const double _kSwipeVelocityThreshold = 200;

/// 滑动手势触发距离阈值（px）：慢速长距离横向拖动超过该值同样视为有效滑动。
const double _kSwipeMinDistance = 80;

/// 对话界面（独立页面，由书籍列表点击进入）。
///
/// - 自带顶栏：返回按钮 + 书名 + 书籍设置 / 全局设置入口；
/// - 桌面端（宽屏）：左右两栏布局，左侧主对话区，右侧侧边栏；
/// - 移动端（窄屏）：主对话区全屏，侧边栏为从右向左滑出的抽屉，
///   通过悬浮按钮或「聊天区左滑」呼出，抽屉内右滑或点遮罩关闭；
/// - 系统返回键：右侧抽屉打开时先关抽屉，否则返回书籍列表。
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen>
    with SingleTickerProviderStateMixin {
  /// 主输入框控制器：支持 Markdown 语法高亮（继承 TextEditingController）。
  final MarkdownEditingController _inputController = MarkdownEditingController();
  final ScrollController _scrollController = ScrollController();

  bool _drawerOpen = false;

  /// 当前横向拖动累计位移（用于慢速长距离滑动也能触发抽屉开合）。
  double _swipeDistance = 0;

  /// 当前指针是否为触屏（滑动开合抽屉仅对触屏生效，避免干扰桌面鼠标操作）。
  bool _swipePointerIsTouch = false;

  /// 自动跟随滚动是否已在本帧注册 postFrame 回调（防止同帧多次 rebuild 重复 jumpTo）。
  bool _autoFollowPending = false;

  /// 用户是否已手动上翻离开底部（期间暂停自动跟随，回到底部附近后自动恢复）。
  bool _userScrolledAway = false;

  /// 宽屏右侧栏开合动画控制器（0=收起，1=展开；初始 0，首帧后滑入入场）。
  late final AnimationController _sidebarController;
  late final Animation<double> _sidebarAnim;

  /// 右侧栏是否展开（以动画进度阈值 [_kSidebarOpenThreshold] 为界）。
  bool get _sidebarOpen => _sidebarController.value > _kSidebarOpenThreshold;

  @override
  void initState() {
    super.initState();
    _sidebarController = AnimationController(
      vsync: this,
      duration: _kSidebarAnimDuration,
      value: 1, // 默认展开（不依赖入场动画，避免初始隐藏导致“空白”观感）。
    );
    _sidebarAnim = CurvedAnimation(
      parent: _sidebarController,
      curve: Curves.easeOutCubic,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final book = context.read<BookProvider>().currentBook;
      if (book == null) return;
      await context.read<RoundProvider>().loadRounds(book.id!);
      if (!mounted) return;
      // 打开书籍后自动滚动到底部，直接查看最新剧情 / 状态。
      _scrollToBottom();
      // 加载当前书籍的世界书条目（供关键词扫描注入 System Prompt）。
      context.read<WorldBookProvider>().loadEntries(book.id!);
    });
  }

  /// 展开 / 收起右侧栏（带动画）。
  void _setSidebarOpen(bool open) {
    if (open && _sidebarController.value < 1) {
      _sidebarController.forward();
    } else if (!open && _sidebarController.value > 0) {
      _sidebarController.reverse();
    } else {
      return; // 目标状态已是当前状态，无需刷新。
    }
    // 刷新「打开侧栏」按钮等随状态变化的 UI。
    setState(() {});
  }

  /// 打开移动端右侧状态抽屉（带动画）。
  void _openDrawer() {
    if (_drawerOpen) return;
    setState(() => _drawerOpen = true);
  }

  /// 关闭移动端右侧状态抽屉。
  void _closeDrawer() {
    if (!_drawerOpen) return;
    setState(() => _drawerOpen = false);
  }

  /// 包裹横向滑动手势识别（用于移动端抽屉开合）：
  /// - [leftward] 为 true 时左滑（从右向左）触发 [onSwipe]，false 时右滑触发；
  /// - 仅触屏指针生效；快速甩动（速度超阈值）或慢速长距离拖动（距离超阈值）均触发。
  Widget _wrapSwipeGesture({
    required Widget child,
    required bool leftward,
    required VoidCallback onSwipe,
  }) {
    return Listener(
      onPointerDown: (event) =>
          _swipePointerIsTouch = event.kind == PointerDeviceKind.touch,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragStart: (_) => _swipeDistance = 0,
        onHorizontalDragUpdate: (details) => _swipeDistance += details.delta.dx,
        onHorizontalDragEnd: (details) {
          if (!_swipePointerIsTouch) return;
          final velocity = details.primaryVelocity ?? 0;
          final distance = _swipeDistance;
          final triggered = leftward
              ? velocity < -_kSwipeVelocityThreshold ||
                    distance < -_kSwipeMinDistance
              : velocity > _kSwipeVelocityThreshold ||
                    distance > _kSwipeMinDistance;
          if (triggered) onSwipe();
        },
        child: child,
      ),
    );
  }

  @override
  void dispose() {
    _sidebarController.dispose();
    _inputController.dispose();
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

  /// 监听用户主动滚动：上翻阅读历史时暂停自动跟随，回到底部附近后恢复。
  bool _onChatScrollNotification(ScrollNotification notification) {
    if (notification is UserScrollNotification) {
      if (notification.direction == ScrollDirection.reverse) {
        // 用户上翻（offset 减小，向历史/顶部方向）→ 已离开底部，暂停自动跟随。
        _userScrolledAway = true;
      } else if (notification.direction == ScrollDirection.idle &&
          _userScrolledAway &&
          _scrollController.hasClients) {
        // 滚动停止（松手/惯性结束）后若已回到底部附近 → 恢复自动跟随。
        final pos = _scrollController.position;
        if (pos.pixels >= pos.maxScrollExtent - _kAutoScrollThreshold) {
          _userScrolledAway = false;
        }
      }
    }
    return false;
  }

  Future<void> _send() async {
    final input = _inputController.text.trim();
    if (input.isEmpty) return;
    final book = context.read<BookProvider>().currentBook;
    if (book == null) return;
    final roundProvider = context.read<RoundProvider>();
    // 生成期间防重复提交（输入框 onSubmitted 回车也可能触发 _send）。
    if (roundProvider.isSending) return;

    _inputController.clear();
    // 发送新消息时恢复自动跟随（用户重新回到最新内容）。
    _userScrolledAway = false;
    _scrollToBottom();

    final ok = await roundProvider.sendRound(userInput: input, book: book);

    if (!ok && mounted && roundProvider.error != null) {
      // 请求失败已以「失败条目」气泡落库（用户输入 + 红框），不再弹消息提示；
      // 仅当失败条目落库也失败时才恢复输入并提示错误兜底。
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

  /// 重新提问失败条目：以失败时的输入重新生成（sendRound 会先清空失败条目）。
  Future<void> _retryFailure() async {
    final rp = context.read<RoundProvider>();
    final input = rp.failedUserInput;
    if (input.isEmpty || rp.isSending) return;
    final book = context.read<BookProvider>().currentBook;
    if (book == null) return;
    _userScrolledAway = false;
    await rp.sendRound(userInput: input, book: book);
    _scrollToBottom();
  }

  /// 修改并重新提问失败条目：编辑失败时的输入后重新生成。
  Future<void> _editAndRetryFailure() async {
    final rp = context.read<RoundProvider>();
    final input = rp.failedUserInput;
    if (input.isEmpty || rp.isSending) return;
    final book = context.read<BookProvider>().currentBook;
    if (book == null) return;
    String? edited;
    await _showEditTextDialog(
      title: '修改并重新提问',
      initial: input,
      onSave: (text) async => edited = text,
    );
    if (edited == null || !mounted) return;
    _userScrolledAway = false;
    await rp.sendRound(userInput: edited!, book: book);
    _scrollToBottom();
  }

  /// 清除失败条目。
  Future<void> _clearFailure() async {
    await context.read<RoundProvider>().clearFailedAttempt();
  }

  /// 查看指定轮次的 RAW 数据（请求 JSON + AI 返回三块）。
  void _showRawDialog(Round round) {
    final exchanges = context.read<RoundProvider>().rawExchangesFor(round.id!);
    if (exchanges == null) return;
    showRawDataDialog(context, exchanges: exchanges);
  }

  /// 查看失败条目的 RAW 数据（请求 JSON + 失败原因）。
  void _showFailedRawDialog() {
    final rp = context.read<RoundProvider>();
    final exchanges = rp.failedRawExchanges;
    if (exchanges == null) return;
    showRawDataDialog(
      context,
      exchanges: exchanges,
      failedError: rp.failedErrorMessage.isEmpty
          ? null
          : rp.failedErrorMessage,
    );
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
      _openDrawer();
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

  /// 长按 / 右键气泡触发的上下文菜单。
  void _onBubbleContextMenu(Round round, bool isAi, Offset position) {
    final items = _buildMenuItems(round, isAi);

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
        case 'raw':
          _showRawDialog(round);
        case 'delete':
          _handleDelete(round);
      }
    });
  }

  /// 构建气泡上下文菜单项（AI / 用户气泡的入口差异集中于此）。
  List<PopupMenuEntry<String>> _buildMenuItems(Round round, bool isAi) {
    final hasRaw = isAi &&
        round.id != null &&
        context.read<RoundProvider>().rawExchangesFor(round.id!) != null;
    return <PopupMenuEntry<String>>[
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
          child: AppMenuAction(icon: Icons.edit_note, label: '修改并重新提问'),
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
          child: AppMenuAction(
            icon: Icons.view_sidebar_outlined,
            label: '查看侧边栏',
          ),
        ),
        if (hasRaw)
          const PopupMenuItem(
            value: 'raw',
            child: AppMenuAction(icon: Icons.raw_on, label: 'RAW'),
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
    final controller = MarkdownEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 560,
          child: TextField(
            controller: controller,
            onTapOutside: unfocusOnTapOutside,
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
      // 仅记录修改后的文本；落库由 editAndReAsk 统一处理，避免重复写库。
      onSave: (text) async {
        edited = text;
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
    await context.read<RoundProvider>().editAndReAsk(
      round,
      edited!,
      book: book,
    );
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
    return size.width >= _kWideBreakpoint;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // 移动端右侧状态抽屉打开时拦截系统返回：优先关闭抽屉而非返回列表。
      canPop: !_drawerOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_drawerOpen) {
          _closeDrawer();
        }
      },
      child: Scaffold(
        appBar: _buildAppBar(context),
        body: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= _kWideBreakpoint;
            final chat = _buildChatArea(context);
            final sidebar = _buildSidebar(
              context,
              onClose: wide ? () => _setSidebarOpen(false) : _closeDrawer,
            );
            return wide
                ? _buildWideLayout(context, chat, sidebar)
                : _buildMobileLayout(context, chat, sidebar);
          },
        ),
      ),
    );
  }

  /// 对话页顶栏：返回书籍列表 + 书名 + 书籍设置 / 全局设置。
  PreferredSizeWidget _buildAppBar(BuildContext context) {
    final book = context.watch<BookProvider>().currentBook;
    return PreferredSize(
      preferredSize: const Size.fromHeight(kToolbarHeight),
      child: Container(
        decoration: BoxDecoration(
          color: context.narrColors.surface,
          border: Border(bottom: BorderSide(color: context.narrColors.divider)),
        ),
        child: AppBar(
          // 收紧返回按钮与书名之间的间距（默认 titleSpacing=16 使箭头右侧空白偏大）。
          titleSpacing: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: '返回书籍列表',
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          // 书名可点击：点击直接进入书籍设置页（无视觉提示，仅友好性交互）。
          title: GestureDetector(
            onTap: book == null
                ? null
                : () => BookSettingsScreen.open(context, book: book),
            child: Text(
              book?.title ?? '对话',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: context.narrColors.textPrimary,
              ),
            ),
          ),
          actions: [
            if (book != null)
              IconButton(
                icon: const Icon(Icons.book_outlined),
                tooltip: '书籍设置',
                onPressed: () => BookSettingsScreen.open(context, book: book),
              ),
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              tooltip: '设置',
              onPressed: () => SettingsScreen.open(context),
            ),
          ],
        ),
      ),
    );
  }

  /// 宽屏布局：聊天区 + 右侧栏固定槽位（带开合动画）。
  Widget _buildWideLayout(BuildContext context, Widget chat, Widget sidebar) {
    // 关键设计：聊天区宽度固定（W-380）永不重排 → 滚动条不乱飞、动画不卡顿；
    // 右侧栏独占固定槽位，用 SlideTransition 从右缘滑入/滑出（不覆盖、不空白）。
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
            // 右侧栏固定槽位。
            SizedBox(
              width: _kSidebarWidth,
              child: Stack(
                children: [
                  // 收起时：居中显示「打开侧栏」按钮。
                  if (!open) _buildOpenSidebarButton(context),
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

  /// 收起状态下的「打开侧栏」按钮。
  Widget _buildOpenSidebarButton(BuildContext context) {
    return Center(
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _setSidebarOpen(true),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.view_sidebar_outlined,
                  color: context.narrColors.textSecondary,
                  size: 20,
                ),
                const SizedBox(height: 6),
                Text(
                  '打开侧栏',
                  style: TextStyle(
                    fontSize: 11,
                    color: context.narrColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 移动端布局：主对话区全屏 + 右侧抽屉（动画滑入/滑出）+ 悬浮按钮。
  Widget _buildMobileLayout(BuildContext context, Widget chat, Widget sidebar) {
    final drawerWidth = MediaQuery.sizeOf(context).width * 0.88;
    return Stack(
      children: [
        // 聊天区任意位置左滑（从右向左）打开右侧抽屉。
        _wrapSwipeGesture(leftward: true, onSwipe: _openDrawer, child: chat),
        if (_drawerOpen)
          Positioned.fill(
            child: GestureDetector(
              onTap: _closeDrawer,
              child: Container(color: Colors.black26),
            ),
          ),
        AnimatedPositioned(
          // 固定 key：避免遮罩/FAB 条件渲染导致元素索引变化而重建、丢失动画。
          key: const Key('right_sidebar_drawer'),
          duration: _kDrawerAnimDuration,
          curve: Curves.easeOutCubic,
          top: 0,
          bottom: 0,
          right: _drawerOpen ? 0 : -drawerWidth,
          width: drawerWidth,
          // ClipRect 把 Material 的阴影裁剪在抽屉边界内：
          // 收起滑出屏幕后阴影不再投射到屏幕边缘内。
          child: ClipRect(
            child: Material(
              elevation: 12,
              // 抽屉内右滑（从左向右）关闭。
              child: _wrapSwipeGesture(
                leftward: false,
                onSwipe: _closeDrawer,
                child: sidebar,
              ),
            ),
          ),
        ),
        if (!_drawerOpen)
          Positioned(
            right: 16,
            bottom: _kFabBottom,
            child: FloatingActionButton.small(
              heroTag: 'sidebar_fab',
              onPressed: _openDrawer,
              tooltip: '打开状态侧边栏',
              child: const Icon(Icons.view_sidebar_outlined),
            ),
          ),
      ],
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
    // 失败条目：空闲且存在未完成的生成尝试时展示（发送新消息时会先清空）。
    final failureAttempt = roundProvider.failedAttempt;
    final showFailure = !showPending && !failureAttempt.isEmpty;

    // 流式输出时若用户位于底部附近（未主动上翻阅读历史），自动跟随新内容，
    // 避免内容不断增长造成视口漂移、滚动条位置飘忽的“不稳定滚动”观感。
    // 仅在帧末执行 jumpTo（非动画），不会与用户手动滚动/动画滚动冲突；
    // _autoFollowPending 保证同一帧内多次 rebuild 只注册一次回调。
    if (showPending && !_autoFollowPending && _scrollController.hasClients) {
      final pos = _scrollController.position;
      // 用户正在主动拖拽/惯性滚动，或已手动上翻阅读历史时，不强制拉回底部
      // （避免流式输出期间触屏滑动被 jumpTo 一直拽回底部）。
      final userScrolling = pos.isScrollingNotifier.value;
      if (!userScrolling &&
          !_userScrolledAway &&
          pos.pixels >= pos.maxScrollExtent - _kAutoScrollThreshold) {
        _autoFollowPending = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _autoFollowPending = false;
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
    // 外层监听用户主动滚动：上翻/滑动时暂停自动跟随，避免触屏滑动被拉回底部。
    final messagesList = NotificationListener<ScrollNotification>(
      onNotification: _onChatScrollNotification,
      child: ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
        itemCount:
            chatRounds.length * 2 +
            (showFailure ? 1 : 0) +
            (showPending ? 1 : 0) +
            (showPendingUser ? 1 : 0),
        itemBuilder: (context, index) {
          Widget item;
          // 虚拟条目起点：历史轮次之后（失败条目 → 待定用户气泡 → 流式气泡）。
          final virtualBase = chatRounds.length * 2 + (showFailure ? 1 : 0);
          // 失败条目：未完成的生成尝试（用户输入 + 红色提示框）。
          if (showFailure && index == chatRounds.length * 2) {
            item = Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: FailedAttemptBubble(
                attempt: failureAttempt,
                onRetry: _retryFailure,
                onEditAndRetry: _editAndRetryFailure,
                onClear: _clearFailure,
                onViewRaw: roundProvider.failedRawExchanges != null
                    ? _showFailedRawDialog
                    : null,
              ),
            );
          } else if (showPendingUser && index == virtualBase) {
            // 生成中的用户气泡（未落库，紧跟历史消息之后）。
            item = Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: ChatBubble(isUser: true, text: pendingInput),
            );
          } else if (showPending &&
              index == virtualBase + (showPendingUser ? 1 : 0)) {
            item = isStreaming
                ? _StreamingBubble(
                    content: roundProvider.streamingContent,
                    agentEvents: roundProvider.agentEvents,
                    retryStatus: roundProvider.retryStatus,
                  )
                : _TypingBubble(retryStatus: roundProvider.retryStatus);
          } else {
            final round = chatRounds[index ~/ 2];
            final isAi = index.isOdd;
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
                    onViewRaw: roundProvider.rawExchangesFor(round.id!) != null
                        ? () => _showRawDialog(round)
                        : null,
                  ),
                ),
              );
            }
          }
          // 每条消息居中限宽（视觉约束），滚动区域仍为全屏。
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _kContentMaxWidth),
              child: item,
            ),
          );
        },
      ),
    );

    return Column(
      children: [
        Expanded(
          child: Container(
            // 与各边栏一致的内容表面背景。
            color: context.narrColors.surface,
            child: chatRounds.isEmpty && !showPending && !showFailure
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
  /// ChatScreen 直接使用时（如测试）首帧可能尚无当前书籍，故 [book] 可空。
  Widget _buildEmptyState(BuildContext context, Book? book) {
    final suggestions = [
      ('✍️ 写出开篇 - 状态提示词', '''请写一个开篇。
由于此轮为初始轮次，## 角色状态 区块应遵守系统提示词中的 `角色类别描述格式` （如有）而非原样继承第0轮次的格式
开始剧情：
'''),
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
              const BrandLogo(size: 34, title: 'NarrChat', titleSize: 20),
              const SizedBox(height: 20),
              Text(
                book == null
                    ? '你好，我是 NarrChat，你的专属剧情创作引擎'
                    : '《${book.title}》的创作，从这里开始',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: context.narrColors.textPrimary,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '先在右侧「第 0 轮」侧边栏设定世界状态与角色状态，\n再输入行动或对话指令，开始推进剧情。',
                style: TextStyle(
                  fontSize: 13,
                  color: context.narrColors.textSecondary,
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
                      color: context.narrColors.surface,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(color: context.narrColors.divider),
                      ),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => _inputController.text = s.$2,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          child: Text(
                            s.$1,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: context.narrColors.textPrimary,
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
      constraints: const BoxConstraints(maxWidth: _kContentMaxWidth),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildComposerToolbar(),
          _buildInputRow(context, roundProvider, isSending),
          const SizedBox(height: 6),
          Text(
            '内容由 AI 生成，仅供创作参考，请仔细甄别',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11,
              color: context.narrColors.textSecondary,
            ),
          ),
        ],
      ),
    );

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
      decoration: BoxDecoration(
        color: context.narrColors.surface,
        border: Border(top: BorderSide(color: context.narrColors.divider)),
      ),
      child: Center(child: composerColumn),
    );
  }

  /// 输入区工具栏：每轮选项（思考 / 流式，临时控件，后续并入悬浮面板选项下拉）
  /// + 滚动到底部。
  Widget _buildComposerToolbar() {
    final aiSettings = context.watch<AiSettingsProvider>();
    final preset = aiSettings.selectedPreset;
    return Row(
      children: [
        if (preset.supportsThinking) ...[
          _ModeToggleChip(
            label: '思考',
            active: aiSettings.thinking,
            onTap: () =>
                _setPerRoundOptions(thinking: !aiSettings.thinking),
          ),
          const SizedBox(width: 6),
        ],
        if (preset.supportsStreaming) ...[
          _ModeToggleChip(
            label: '流式',
            active: aiSettings.streaming,
            onTap: () =>
                _setPerRoundOptions(streaming: !aiSettings.streaming),
          ),
          const SizedBox(width: 6),
        ],
        if (preset.supportsSearch) ...[
          _ModeToggleChip(
            label: '联网搜索',
            active: aiSettings.lastSearch,
            onTap: () => _setPerRoundOptions(search: !aiSettings.lastSearch),
          ),
          const SizedBox(width: 6),
        ],
        // 滚动到底部
        TextButton.icon(
          onPressed: _scrollToBottom,
          icon: const Icon(Icons.vertical_align_bottom, size: 16),
          label: const Text('滚动到底部'),
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            textStyle: const TextStyle(fontSize: 12),
          ),
        ),
      ],
    );
  }

  /// 保存每轮选项（思考 / 流式 / 联网搜索）记忆。
  Future<void> _setPerRoundOptions({
    bool? thinking,
    bool? streaming,
    bool? search,
  }) async {
    final aiSettings = context.read<AiSettingsProvider>();
    await aiSettings.setPerRoundOptions(
      thinking: thinking ?? aiSettings.thinking,
      streaming: streaming ?? aiSettings.streaming,
      search: search ?? aiSettings.lastSearch,
    );
  }

  /// 主输入行：圆角输入容器 + 圆形发送/停止按钮。
  Widget _buildInputRow(
    BuildContext context,
    RoundProvider roundProvider,
    bool isSending,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.narrColors.divider),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: _inputController,
              onTapOutside: unfocusOnTapOutside,
              minLines: 1,
              maxLines: 5,
              style: TextStyle(
                fontSize: 15,
                height: 1.5,
                color: context.narrColors.textPrimary,
              ),
              decoration: InputDecoration(
                hintText: '输入你的行动或对话…',
                hintStyle: TextStyle(color: context.narrColors.placeholder),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
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
                onPressed: isSending ? roundProvider.cancelGeneration : _send,
                tooltip: isSending ? '停止生成' : '发送',
                style: IconButton.styleFrom(
                  backgroundColor: NarrChatTheme.primary,
                  disabledBackgroundColor: Theme.of(
                    context,
                  ).colorScheme.outline,
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
                    : const Icon(
                        Icons.arrow_upward,
                        size: 18,
                        color: Colors.white,
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 侧边栏
  // ---------------------------------------------------------------------------
  Widget _buildSidebar(BuildContext context, {VoidCallback? onClose}) {
    // 仅订阅轮次列表：流式输出时轮次未变化，侧栏不会随每个 chunk 重建。
    final rounds = context.select<RoundProvider, List<Round>>((p) => p.rounds);
    final sidebarProvider = context.watch<SidebarProvider>();
    final latest = rounds.isEmpty ? null : rounds.last;

    final viewedRound = sidebarProvider.isHistoryView
        ? (rounds
                  .where((r) => r.id == sidebarProvider.historyRoundId)
                  .isNotEmpty
              ? rounds.firstWhere((r) => r.id == sidebarProvider.historyRoundId)
              : latest)
        : latest;

    return SidebarPanel(
      key: ValueKey(viewedRound?.id),
      round: viewedRound,
      isHistoryView: sidebarProvider.isHistoryView && viewedRound != null,
      onBackToCurrent: () => context.read<SidebarProvider>().showCurrent(),
      onClose: onClose,
      onAutoSaveField: (round, field, value) => context
          .read<RoundProvider>()
          .updateRoundField(round.id!, field, value),
    );
  }
}

/// 临时每轮选项开关（思考 / 流式），后续并入悬浮面板的选项下拉菜单。
class _ModeToggleChip extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback? onTap;

  const _ModeToggleChip({
    required this.label,
    required this.active,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: active ? scheme.primary : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              active ? Icons.check_circle : Icons.circle_outlined,
              size: 13,
              color: active ? scheme.onPrimary : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: active ? scheme.onPrimary : scheme.onSurfaceVariant,
                fontWeight: active ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// AI 正在创作中的指示（极简，无气泡）。
///
/// [retryStatus] 非空时，在其下方显示灰字重试提示（错误重连……x/3），
/// 与流式气泡共享 [_RetryStatusText]。
class _TypingBubble extends StatelessWidget {
  /// 当前自动重试进度：(已重试次数, 总次数)；null = 无重试。
  final (int, int)? retryStatus;

  const _TypingBubble({this.retryStatus});

  @override
  Widget build(BuildContext context) {
    final retry = retryStatus;
    return Align(
      alignment: Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const BrandLogo(size: 30),
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
              Text(
                'AI 正在创作…',
                style: TextStyle(
                  color: context.narrColors.textSecondary,
                  fontSize: 13,
                ),
              ),
            ],
          ),
          if (retry != null) ...[const SizedBox(height: 8), _RetryStatusText(attempt: retry.$1, total: retry.$2)],
        ],
      ),
    );
  }
}

/// 自动重试灰字提示：「错误重连……（x/3）」。
class _RetryStatusText extends StatelessWidget {
  /// 当前已重试次数。
  final int attempt;

  /// 重试总次数。
  final int total;

  const _RetryStatusText({required this.attempt, required this.total});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.refresh, size: 12, color: context.narrColors.textSecondary),
        const SizedBox(width: 5),
        Text(
          '错误重连……（$attempt/$total）',
          style: TextStyle(
            fontSize: 12,
            color: context.narrColors.textSecondary,
          ),
        ),
      ],
    );
  }
}

/// 搜索细节框：每个框独立展开/折叠状态（多搜索框互不影响）。
/// 进行中显示转圈；成功显示 ✓；失败显示小 ✕（不报错截断）。
class _SearchBox extends StatefulWidget {
  final String query;
  final bool searching;
  final bool failed;
  final List<SearchResult> results;

  const _SearchBox({
    super.key,
    required this.query,
    required this.searching,
    required this.failed,
    required this.results,
  });

  @override
  State<_SearchBox> createState() => _SearchBoxState();
}

class _SearchBoxState extends State<_SearchBox> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final searching = widget.searching;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 头部：图标 + 状态文本 + 转圈/✓ + chevron。
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              child: Row(
                children: [
                  const Icon(
                    Icons.travel_explore_outlined,
                    size: 15,
                    color: NarrChatTheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    searching ? '正在搜索' : '联网搜索',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: NarrChatTheme.primary,
                    ),
                  ),
                  if (widget.query.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        searching
                            ? '「${widget.query}」搜索中'
                            : '「${widget.query}」· '
                                  '${widget.results.length} 条结果',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: context.narrColors.textSecondary,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(width: 4),
                  if (searching)
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else if (widget.failed)
                    const Icon(
                      Icons.close,
                      size: 14,
                      color: Color(0xFFE5484D),
                    )
                  else
                    const Icon(
                      Icons.check_circle,
                      size: 14,
                      color: NarrChatTheme.primary,
                    ),
                  const SizedBox(width: 4),
                  Icon(
                    _expanded ? Icons.expand_more : Icons.chevron_right,
                    size: 16,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          // 展开：固定高度展示结果明细。
          if (_expanded) ...[
            Divider(height: 1, color: scheme.outlineVariant),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 150),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(10),
                child: _buildResults(context),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildResults(BuildContext context) {
    final results = widget.results;
    if (widget.failed) {
      return Text(
        '搜索失败，未获取到结果',
        style: TextStyle(
          fontSize: 12,
          color: context.narrColors.textSecondary,
        ),
      );
    }
    if (results.isEmpty) {
      return Text(
        widget.searching ? '正在搜索…' : '未获取到结果',
        style: TextStyle(
          fontSize: 12,
          color: context.narrColors.textSecondary,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < results.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          Text(
            '${i + 1}. ${results[i].title}',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: context.narrColors.textPrimary,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            results[i].url,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              color: context.narrColors.textSecondary,
            ),
          ),
          if (results[i].snippet.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              results[i].snippet,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: context.narrColors.textSecondary,
              ),
            ),
          ],
        ],
      ],
    );
  }
}

/// 思考框：每个框独立展开/折叠状态（多思考框互不影响）。
///
/// - 折叠：4~5 行固定高度、内容增长时自动向下滚动；
/// - 展开：全部内容内联展示（自动跟随交由聊天区全局滚动）；
/// - 思考进行中显示转圈，完成后显示 ✓。
class _ThinkingBox extends StatefulWidget {
  final String content;
  final bool done;

  const _ThinkingBox({super.key, required this.content, required this.done});

  @override
  State<_ThinkingBox> createState() => _ThinkingBoxState();
}

class _ThinkingBoxState extends State<_ThinkingBox> {
  final ScrollController _collapsedController = ScrollController();
  String? _lastContent;
  bool _expanded = false;

  @override
  void didUpdateWidget(covariant _ThinkingBox oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 折叠态：思考内容增长时自动滚动到底部。
    if (widget.content != _lastContent && !_expanded) {
      _lastContent = widget.content;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_collapsedController.hasClients) return;
        final pos = _collapsedController.position;
        if (pos.maxScrollExtent > 0) {
          _collapsedController.jumpTo(pos.maxScrollExtent);
        }
      });
    }
  }

  @override
  void dispose() {
    _collapsedController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 头部：思考中 + 状态（转圈 / ✓）+ chevron。
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              child: Row(
                children: [
                  const Icon(
                    Icons.psychology_outlined,
                    size: 15,
                    color: NarrChatTheme.primary,
                  ),
                  const SizedBox(width: 6),
                  const Text(
                    '思考中',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: NarrChatTheme.primary,
                    ),
                  ),
                  const Spacer(),
                  if (widget.done)
                    const Icon(
                      Icons.check_circle,
                      size: 14,
                      color: NarrChatTheme.primary,
                    )
                  else
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  const SizedBox(width: 4),
                  Icon(
                    _expanded ? Icons.expand_more : Icons.chevron_right,
                    size: 16,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          // 折叠：4~5 行固定高度、内部自动滚动；展开：全部内容内联。
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
              child: SelectableText(
                widget.content,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: context.narrColors.textSecondary,
                ),
              ),
            )
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 96),
              child: SingleChildScrollView(
                controller: _collapsedController,
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                child: SelectableText(
                  widget.content,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.5,
                    color: context.narrColors.textSecondary,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// AI 流式输出气泡：实时显示剧情正文。
///
/// - 思考：每轮一个独立思考框（折叠 4~5 行自动滚动 / 展开全量内联）；
/// - 联网搜索：Copilot 风格固定高度可展开细节框；
/// - 生成期间气泡最底部持续显示转圈图标。
class _StreamingBubble extends StatefulWidget {
  final String content;
  final List<AgentEvent> agentEvents;

  /// 当前自动重试进度：(已重试次数, 总次数)；null = 无重试。
  final (int, int)? retryStatus;

  const _StreamingBubble({
    required this.content,
    required this.agentEvents,
    this.retryStatus,
  });

  @override
  State<_StreamingBubble> createState() => _StreamingBubbleState();
}

class _StreamingBubbleState extends State<_StreamingBubble> {
  @override
  Widget build(BuildContext context) {
    final maxWidth = MediaQuery.sizeOf(context).width * 0.8;
    final content = widget.content;
    final events = widget.agentEvents;
    final retry = widget.retryStatus;
    final hasContent = content.isNotEmpty;
    final hasEvents = events.isNotEmpty;

    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth.clamp(240, 680)),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const BrandLogo(size: 30),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Agent 过程时间线：思考 / 搜索按真实顺序交错，
                  // 每个框独立展开/折叠状态（按 index 作为 key 保持状态）。
                  for (var i = 0; i < events.length; i++) ...[
                    if (i > 0) const SizedBox(height: 8),
                    if (events[i].type == AgentEventType.thinking)
                      _ThinkingBox(
                        key: ValueKey('think_$i'),
                        content: events[i].content,
                        done: events[i].done,
                      )
                    else
                      _SearchBox(
                        key: ValueKey('search_$i'),
                        query: events[i].content,
                        searching: events[i].searching,
                        failed: events[i].failed,
                        results: events[i].results,
                      ),
                  ],
                  // 自动重试提示（灰字）：思考/搜索块之后、正文之前。
                  if (retry != null) ...[const SizedBox(height: 8), _RetryStatusText(attempt: retry.$1, total: retry.$2)],
                  // 剧情正文。
                  if (hasContent) ...[
                    if (hasEvents) const Divider(height: 14),
                    SelectableText(
                      '$content▍',
                      style: TextStyle(
                        fontSize: 15,
                        height: 1.65,
                        color: context.narrColors.textPrimary,
                      ),
                    ),
                  ],
                  // 生成中：气泡最底部持续显示转圈图标。
                  const SizedBox(height: 8),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        hasContent ? '正在生成…' : 'AI 正在创作…',
                        style: TextStyle(
                          fontSize: 12,
                          color: context.narrColors.textSecondary,
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
