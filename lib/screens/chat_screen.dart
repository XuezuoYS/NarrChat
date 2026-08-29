import 'dart:io' show File, Platform;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport, ScrollDirection;
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../config/chat_route.dart';
import '../models/agent_event.dart';
import '../models/ai_platform.dart';
import '../models/book.dart';
import '../models/round.dart';
import '../providers/ai_settings_provider.dart';
import '../providers/book_provider.dart';
import '../providers/cloud_sync_provider.dart';
import '../providers/round_provider.dart';
import '../providers/sidebar_provider.dart';
import '../providers/world_book_provider.dart';
import '../services/clipboard_paste_service.dart';
import '../services/html_search_service.dart';
import '../services/image_import_service.dart';
import '../services/image_store.dart';
import '../services/sync/image_revival.dart';
import '../theme/app_theme.dart';
import '../utils/focus_utils.dart';
import '../widgets/ai_bubble_actions.dart';
import '../widgets/app_menu.dart';
import '../widgets/brand_logo.dart';
import '../widgets/chat_bubble.dart';
import '../widgets/edit_text_images_dialog.dart';
import '../widgets/failed_attempt_bubble.dart';
import '../widgets/floor_jump_bar.dart';
import '../widgets/generation_banner.dart';
import '../widgets/image_preview.dart';
import '../widgets/markdown_editing_controller.dart';
import '../widgets/markdown_preview.dart';
import '../widgets/raw_dialog.dart';
import '../widgets/round_action_dialogs.dart';
import '../widgets/sidebar_panel.dart';
import '../widgets/text_field_context_menu.dart';
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

/// 滚到底部收敛循环上限（懒加载列表 maxScrollExtent 逐帧收敛，帧级、开销极小）。
const int _kScrollToBottomMaxRefine = 10;

/// 判定「已到底部」的残余误差（px），收敛停止条件。
const double _kScrollToBottomEpsilon = 1.0;

/// 楼层跳转：轮起点与视口顶对齐的判定误差（px）。
/// 小于该值视为「正处于该轮起点」→ 左箭头跳到上一轮，否则跳到当前轮起点。
const double _kFloorJumpAtStartEpsilon = 4;

/// 楼层跳转：未实测项高度的默认估算（偶数项=用户气泡，奇数项=AI 气泡）。
/// 仅用于首次跳转的粗定位，随后由实测高度与校准迭代修正。
const double _kFloorJumpDefaultUserHeight = 48;
const double _kFloorJumpDefaultAiHeight = 280;

/// 楼层跳转：校准迭代上限（超出即停在估算位置）。
const int _kFloorJumpMaxRefine = 10;

/// 右侧栏开合动画时长。
const Duration _kSidebarAnimDuration = Duration(milliseconds: 300);

/// 移动端抽屉动画时长。
const Duration _kDrawerAnimDuration = Duration(milliseconds: 260);

/// 侧栏开合进度阈值（进度大于该值视为展开）。
const double _kSidebarOpenThreshold = 0.5;

/// 滑动手势触发速度阈值（px/s）：横向快速甩动超过该值视为一次有效滑动。
const double _kSwipeVelocityThreshold = 200;

/// 滑动手势触发距离阈值（px）：慢速长距离横向拖动超过该值同样视为有效滑动。
const double _kSwipeMinDistance = 80;

/// 对话界面（独立页面，由书籍列表点击进入）。
///
/// - 自带顶栏：返回按钮 + 书名 + 书籍设置 / 全局设置入口；
/// - 桌面端（宽屏）：左右两栏布局，左侧主对话区，右侧侧边栏；
/// - 移动端（窄屏）：主对话区全屏，侧边栏为从右向左滑出的抽屉，
///   通过输入面板右上方形按钮或「聊天区左滑」呼出，抽屉内右滑或点遮罩关闭；
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

  /// 当前待发送的用户消息附件（图片，相对路径 `img/<hash>.<ext>`）。
  final List<String> _pendingImages = [];

  /// 已发送、正在生成中的用户消息附件（图片相对路径）。
  ///
  /// 发送瞬间把 [_pendingImages] 转入本列表：输入框待发送条立即清空，
  /// 而生成中的用户气泡仍能带上这些图片（与文字同帧上屏）。
  List<String> _sendingImages = [];

  /// 是否正在导入图片（展示进度条 UI）。
  bool _isImportingImages = false;

  /// 导入进度（已处理 / 总数），用于进度条。
  int _importDone = 0;
  int _importTotal = 0;

  /// 是否正拖拽图片到输入区（Windows 桌面拖拽提示浮层）。
  bool _dragTargeted = false;

  bool _drawerOpen = false;

  /// 当前横向拖动累计位移（用于慢速长距离滑动也能触发抽屉开合）。
  double _swipeDistance = 0;

  /// 当前指针是否为触屏（滑动开合抽屉仅对触屏生效，避免干扰桌面鼠标操作）。
  bool _swipePointerIsTouch = false;

  /// 自动跟随滚动是否已在本帧注册 postFrame 回调（防止同帧多次 rebuild 重复 jumpTo）。
  bool _autoFollowPending = false;

  /// 用户是否已手动上翻离开底部（期间暂停自动跟随，回到底部附近后自动恢复）。
  bool _userScrolledAway = false;

  /// 打开书籍后「加载轮次 → 跳转到底部」的初始化标记（同一本书只执行一次）。
  /// 防止首帧建造时当前书尚未就绪（异步加载 / 冷启动）而错过跳底。
  String? _initialScrollBookUuid;

  /// 「本轮生成结束」红点：生成结束后若用户未停留在底部则提示
  /// 「有新内容可滚动查看」，滚动回底部后消失。
  ///
  /// 独立于 [_userScrolledAway]（自动跟随暂停标志）：生成中/调整窗口/修改选项
  /// 触发的滚动通知不会误置该红点。
  bool _newContentDot = false;

  /// 是否已安排帧末重建（滚动通知可能在布局/手势分发期间触发，不宜直接 setState）。
  bool _dotRebuildScheduled = false;

  /// 悬浮输入面板测量 key / 高度：消息列表底部留白据此动态适配，
  /// 避免固定大留白在默认输入框大小下造成大面积空白。
  final GlobalKey _composerKey = GlobalKey();
  double _composerHeight = 0;

  /// 楼层跳转：悬浮条是否展开（按钮正上方弹出的横向长条浮层）。
  bool _floorJumpOpen = false;

  /// 楼层跳转：悬浮条在对话区 Stack 中的定位（相对按钮右缘/上方）。
  /// 用 GlobalKey 帧末实测按钮与对话区的全局位置计算，按钮移动时随重建跟随。
  final GlobalKey _floorJumpButtonKey = GlobalKey();
  final GlobalKey _floorJumpStackKey = GlobalKey();
  double? _floorJumpBarTop;
  double? _floorJumpBarRight;
  bool _floorJumpPosPending = false;

  /// 楼层跳转：当前屏幕中的轮次（roundIndex）及是否正处于该轮起点。
  /// 仅在悬浮条打开期间维护，由帧末检测更新。
  ({int roundIndex, bool atStart})? _floorJumpCurrent;

  /// 帧末检测守卫：同一帧多次 rebuild 只注册一次回调。
  bool _floorJumpDetectPending = false;

  /// 楼层跳转：列表项定位缓存，由列表项在帧末「自上报」维护
  /// （见 [_FloorMeasuredItem]，不使用逐项 GlobalKey）：
  /// - [_itemOffsets]：item index → 该项起点在滚动坐标系中的偏移（滚动不变，
  ///   项离开视口后仍有效）；
  /// - [_itemHeights]：item index → 该项实测高度（未测项用分类型均值估算）。
  final Map<int, double> _itemOffsets = {};
  final Map<int, double> _itemHeights = {};

  /// 楼层跳转：当前跳转目标项的**唯一** GlobalKey（仅跳转期间挂载到目标项，
  /// 供 [RenderAbstractViewport.getOffsetToReveal] 精确对齐；避免逐项建 key）。
  final GlobalKey _floorJumpTargetKey = GlobalKey();
  int? _floorJumpTargetIndex;

  /// 缓存失效依据：轮次来源（引用+长度）或窗口宽度变化时清空实测数据。
  List<Round> _lastRoundsSource = const [];
  int _lastRoundsCount = 0;
  double _lastLayoutWidth = 0;

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
    // 首帧后测量悬浮输入面板高度，驱动消息列表底部留白。
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _measureComposerHeight());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 打开书籍后跳转到底部，直接查看最新剧情 / 状态：
      // 书已就绪（列表点击进入）时立即执行；书晚于首帧就绪（冷启动 /
      // 异步加载）时由 build 兜底补执行（见 _ensureInitialScroll）。
      _ensureInitialScroll();
      // 加载当前书籍的世界书条目（供关键词扫描注入 System Prompt）。
      final book = context.read<BookProvider>().currentBook;
      if (book == null) return;
      context.read<WorldBookProvider>().loadEntries(book.uuid);
      // 全自动同步节点之一：进入书籍时拉取/推送变更（非自动模式内部忽略）。
      context.read<CloudSyncProvider>().triggerSync();
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

  /// 打开书籍的「加载轮次 → 跳转到底部」初始化（同一本书幂等）。
  ///
  /// initState 帧末与 build 兜底两处调用：列表点击进入时 currentBook 已就绪，
  /// 首帧即执行；书籍异步加载晚于首帧就绪时，由 build 在 currentBook 变化后
  /// 补执行。跳底用瞬时模式（[_scrollToBottom] 的 animated = false），
  /// 并依赖帧末收敛循环保证懒加载列表真正到达底部。
  void _ensureInitialScroll() {
    final book = context.read<BookProvider>().currentBook;
    if (book == null || _initialScrollBookUuid == book.uuid) return;
    _initialScrollBookUuid = book.uuid;
    Future<void>.microtask(() async {
      if (!mounted) return;
      await context.read<RoundProvider>().loadRounds(book.uuid);
      if (!mounted) return;
      _scrollToBottom(animated: false);
    });
  }

  /// 滚动到底部（默认带动画；打开书籍等场景用 [animated] = false 瞬时跳转）。
  ///
  /// 消息列表是懒加载 ListView.builder：maxScrollExtent 在尾部项尚未构建时是
  /// 估算值，动画/跳转只到达当时的估算极限，随后尾部项被构建、真实极限可能
  /// 更大——旧实现动画停在旧目标，多轮/内容不均时「滚到一半停住」。
  /// 两种模式完成后都追帧末收敛循环（[_settleScrollToBottom]），
  /// 直至位置 ≥ 真实 maxScrollExtent - ε 或达到收敛上限。
  void _scrollToBottom({bool animated = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final pos = _scrollController.position;
      if (animated && pos.pixels < pos.maxScrollExtent - _kScrollToBottomEpsilon) {
        pos
            .animateTo(
              pos.maxScrollExtent,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
            )
            .then((_) {
          if (mounted) _settleScrollToBottom(0);
        });
      } else {
        pos.jumpTo(pos.maxScrollExtent);
        _settleScrollToBottom(0);
      }
    });
  }

  /// 帧末复查 + 补滚：jump/动画后视口底部项才被构建，maxScrollExtent 可能
  /// 继续增长，逐帧校准直至稳定（最多 [_kScrollToBottomMaxRefine] 次）。
  ///
  /// 用户已主动上翻（[_userScrolledAway]）时不再强制拉回（动画被用户滚动
  /// 打断的场景，交由用户接管）；每次补滚后显式 scheduleFrame，保证
  /// 帧末回调链在真实与测试环境都能持续到收敛。
  void _settleScrollToBottom(int attempt) {
    if (!mounted || attempt > _kScrollToBottomMaxRefine) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final pos = _scrollController.position;
      if (_userScrolledAway) return;
      if (pos.pixels >= pos.maxScrollExtent - _kScrollToBottomEpsilon) {
        // 跳底完成：收敛经由多帧 jump 定位，期间构建的子项可能以「跳变后
        // 的滚动位置」上报过期偏移（项序号与偏移错位，楼层检测会误判当前
        // 轮）。清空楼层测量缓存，后续以纯估算兜底，待用户滚动 / 打开悬浮
        // 条重建时重新实测上报。
        _itemHeights.clear();
        _itemOffsets.clear();
        return;
      }
      pos.jumpTo(pos.maxScrollExtent);
      WidgetsBinding.instance.scheduleFrame();
      _settleScrollToBottom(attempt + 1);
    });
  }

  /// 监听用户主动滚动：上翻阅读历史时暂停自动跟随，回到底部附近后恢复；
  /// 同时维护「生成结束」红点——滚动回底部即清除。
  /// 悬浮条打开期间任何滚动（含流式自动跟随）都会刷新中间数字。
  bool _onChatScrollNotification(ScrollNotification notification) {
    if (_floorJumpOpen) {
      _scheduleFloorJumpDetect();
    }
    if (notification is UserScrollNotification) {
      if (notification.direction != ScrollDirection.idle) {
        // 用户滚动开始（上翻阅读历史 / 向下回滚，方向随 offset 变化）：
        // 已离开底部，暂停自动跟随与补滚；回到底部附近后由 idle 分支恢复。
        // （仅靠 reverse 判断会漏掉「offset 减小时方向为 forward」的真实语义。）
        _userScrolledAway = true;
      } else if (_scrollController.hasClients) {
        // 滚动停止（松手/惯性结束）后若已回到底部附近 → 恢复自动跟随、清除红点。
        final pos = _scrollController.position;
        if (pos.pixels >= pos.maxScrollExtent - _kAutoScrollThreshold) {
          _userScrolledAway = false;
          if (_newContentDot) {
            _newContentDot = false;
            _scheduleDotRebuild();
          }
        }
      }
    }
    return false;
  }

  /// 帧末触发重建（滚动通知可能在布局/手势分发期间触发，不宜直接 setState）。
  void _scheduleDotRebuild() {
    if (_dotRebuildScheduled) return;
    _dotRebuildScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _dotRebuildScheduled = false;
      if (mounted) setState(() {});
    });
  }

  /// 本轮生成结束（无论成败）的收尾：
  /// - 用户停留在底部 → 自动跟随新内容滚到底（直接查看最新结果）；
  /// - 用户离开底部 → 显示「有新内容可滚动查看」红点，不强制滚动。
  ///
  /// 与 [CompletionNotifier]（未来系统级推送的接口）共用「本轮生成结束」这一事件：
  /// 红点即复用该事件的本地提示，未来后台推送也在此一并接入。
  void _onGenerationFinished() {
    // 帧末再判断，确保最后一块内容已完成布局、滚动范围已更新。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_isNearBottom()) {
        _scrollToBottom();
      } else if (!_newContentDot) {
        setState(() => _newContentDot = true);
      }
    });
  }

  /// 是否已滚动到（或接近）底部（误差 [_kAutoScrollThreshold] 内视为底部）。
  bool _isNearBottom() {
    if (!_scrollController.hasClients) return true;
    final pos = _scrollController.position;
    return pos.pixels >= pos.maxScrollExtent - _kAutoScrollThreshold;
  }

  // ---------------------------------------------------------------------------
  // 楼层跳转：悬浮条开关 / 当前轮次检测 / 列表项定位与跳转
  // ---------------------------------------------------------------------------

  /// 当前书籍参与气泡展示的轮次（排除第零轮；DAO 已按 round_index 升序）。
  List<Round> _chatRoundsNow() =>
      context.read<RoundProvider>().rounds.where((r) => r.roundIndex > 0).toList();

  void _toggleFloorJump() {
    if (_floorJumpOpen) {
      _closeFloorJump();
    } else {
      _openFloorJump();
    }
  }

  void _openFloorJump() {
    if (_floorJumpOpen) return;
    setState(() {
      _floorJumpOpen = true;
      // 重新定位：避免沿用上次展开时的旧坐标。
      _floorJumpBarTop = null;
      _floorJumpBarRight = null;
    });
    // 打开后立即调度帧末检测与定位（需布局完成后读取位置）。
    _scheduleFloorJumpDetect();
    _scheduleFloorJumpPosition();
  }

  /// 帧末调度一次悬浮条定位（同一帧多次触发只注册一次）。
  void _scheduleFloorJumpPosition() {
    if (_floorJumpPosPending) return;
    _floorJumpPosPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _floorJumpPosPending = false;
      if (!mounted) return;
      _updateFloorJumpPosition();
    });
  }

  /// 实测按钮与对话区的全局位置，计算悬浮条在对话区 Stack 中的
  /// （top/right）偏移：右缘对齐按钮右缘、悬浮条底边位于按钮顶上方 8px。
  /// 不使用 CompositedTransformFollower（该组件在 Overlay 布局中会触发
  /// 「paint transform cannot be reliably computed」断言，见 Flutter 提示）。
  void _updateFloorJumpPosition() {
    if (!_floorJumpOpen) return;
    final btnCtx = _floorJumpButtonKey.currentContext;
    final stackCtx = _floorJumpStackKey.currentContext;
    if (btnCtx == null || stackCtx == null) return;
    final btnBox = btnCtx.findRenderObject() as RenderBox?;
    final stackBox = stackCtx.findRenderObject() as RenderBox?;
    if (btnBox == null || stackBox == null) return;
    if (!btnBox.attached || !stackBox.attached) return;
    final btnTopLeft = btnBox.localToGlobal(Offset.zero);
    final stackTopLeft = stackBox.localToGlobal(Offset.zero);
    // 36(bar高) + 8(间距)。
    final top = btnTopLeft.dy - stackTopLeft.dy - 44;
    final right =
        (stackTopLeft.dx + stackBox.size.width) -
        (btnTopLeft.dx + btnBox.size.width);
    if (top != _floorJumpBarTop || right != _floorJumpBarRight) {
      setState(() {
        _floorJumpBarTop = top;
        _floorJumpBarRight = right;
      });
    }
  }

  void _closeFloorJump() {
    if (!_floorJumpOpen) return;
    setState(() => _floorJumpOpen = false);
  }

  /// 帧末调度一次「当前轮次」检测（同一帧多次触发只注册一次）。
  void _scheduleFloorJumpDetect() {
    if (_floorJumpDetectPending) return;
    _floorJumpDetectPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _floorJumpDetectPending = false;
      if (!mounted) return;
      _detectFloorJumpCurrent();
    });
  }

  /// 列表项自上报回调（[_FloorMeasuredItem] 帧末调用）：
  /// 记录该项起点在滚动坐标系中的偏移与高度，供检测/跳转使用。
  /// 偏移由「上报时的视口局部 y + 当时滚动偏移」得到，滚动不变、离开视口后仍有效。
  void _onItemMeasured(int itemIndex, double viewportTop, double height) {
    _itemHeights[itemIndex] = height;
    if (_scrollController.hasClients) {
      _itemOffsets[itemIndex] = _scrollController.position.pixels + viewportTop;
    }
  }

  /// 检测当前屏幕中的轮次。
  ///
  /// 当前轮 = 可视内容起始项所属的轮次（首个「底边仍在视口顶以下」的项，
  /// 其顶部可能已在视口上方）——即用户正在阅读的轮次；atStart 表示该轮
  /// 起点已与视口顶对齐。
  ///
  /// 使用「完整偏移模型」：已上报项用实测偏移，未上报项从最近已上报锚点
  /// 推算（见 [_modeledItemOffset]）——即使当前轮起点项从未被构建/上报
  /// （如直接跳转后阅读），也能正确识别当前轮（修复「第 5 轮底部点左箭头
  /// 跳到第 4 轮」）。
  void _detectFloorJumpCurrent() {
    if (!_floorJumpOpen || !_scrollController.hasClients) return;
    final chatRounds = _chatRoundsNow();
    if (chatRounds.isEmpty) {
      _setFloorJumpCurrent(null);
      return;
    }
    final pos = _scrollController.position;
    final itemCount = chatRounds.length * 2;
    double heightOf(int idx) => _itemHeights[idx] ?? _avgItemHeightFor(idx);
    double offsetOf(int idx) => _modeledItemOffset(idx);

    // 可视内容起始项：首个「底边 > 视口顶」的项。
    int? firstIndex;
    for (var idx = 0; idx < itemCount; idx++) {
      if (offsetOf(idx) + heightOf(idx) > pos.pixels) {
        firstIndex = idx;
        break;
      }
    }
    // 视口已越过最后一项（末尾虚拟项区域）→ 最后一轮。
    if (firstIndex == null || firstIndex >= itemCount) {
      _setFloorJumpCurrent((
        roundIndex: chatRounds.last.roundIndex,
        atStart: false,
      ));
      return;
    }
    final round = chatRounds[firstIndex ~/ 2];
    final offset = offsetOf(firstIndex);
    final atStart = firstIndex.isEven &&
        (offset - pos.pixels).abs() <= _kFloorJumpAtStartEpsilon;
    _setFloorJumpCurrent((roundIndex: round.roundIndex, atStart: atStart));
  }

  /// 计算指定列表项起点的滚动偏移（完整偏移模型）：
  /// - 已上报项：直接返回实测偏移；
  /// - 未上报项：从最近已上报锚点推算（优先向前找下方锚点，其次上方），
  ///   间距用已测高度/分类型均值补齐——锚点近、链条短，误差小。
  double _modeledItemOffset(int itemIndex) {
    final reported = _itemOffsets[itemIndex];
    if (reported != null) return reported;
    int? below; // 最近的已上报且 index < itemIndex
    int? above; // 最近的已上报且 index > itemIndex
    for (final e in _itemOffsets.entries) {
      if (e.key < itemIndex) {
        if (below == null || e.key > below) below = e.key;
      } else if (e.key > itemIndex) {
        if (above == null || e.key < above) above = e.key;
      }
    }
    if (below != null) {
      return _itemOffsets[below]! + _estimateGap(below, itemIndex);
    }
    if (above != null) {
      return _itemOffsets[above]! - _estimateGap(itemIndex, above);
    }
    return _estimateItemOffset(itemIndex);
  }

  void _setFloorJumpCurrent(({int roundIndex, bool atStart})? value) {
    final same = value == null
        ? _floorJumpCurrent == null
        : _floorJumpCurrent != null &&
            _floorJumpCurrent!.roundIndex == value.roundIndex &&
            _floorJumpCurrent!.atStart == value.atStart;
    if (same) return;
    setState(() => _floorJumpCurrent = value);
  }

  /// 把用户输入的轮次解析为实际存在的目标轮（roundIndex 有缺口时向下就近取整）。
  Round? _resolveFloorTarget(int roundIndex) {
    final chatRounds = _chatRoundsNow();
    if (chatRounds.isEmpty) return null;
    final clamped = roundIndex.clamp(1, chatRounds.last.roundIndex);
    return chatRounds.lastWhere(
      (r) => r.roundIndex <= clamped,
      orElse: () => chatRounds.first,
    );
  }

  /// 跳转到指定轮次（用户输入/数字语义：目标轮起点）。
  void _jumpToFloorRound(int roundIndex) {
    final target = _resolveFloorTarget(roundIndex);
    if (target == null) return;
    final chatRounds = _chatRoundsNow();
    final position = chatRounds.indexOf(target);
    if (position < 0) return;
    _userScrolledAway = true;
    _jumpToItem(2 * position);
  }

  /// 左箭头：处于当前轮起点 → 上一轮起点；否则 → 当前轮起点。
  void _jumpToPrevFloor() {
    final chatRounds = _chatRoundsNow();
    if (chatRounds.isEmpty) return;
    final current = _floorJumpCurrent;
    if (current == null) return;
    final position = _chatPositionOfRoundIndex(chatRounds, current.roundIndex);
    if (position < 0) return;
    final targetPosition = (current.atStart && position > 0) ? position - 1 : position;
    _userScrolledAway = true;
    _jumpToItem(2 * targetPosition);
  }

  /// 右箭头：下一轮起点；已是最后一轮 → 列表末尾（最后一轮末尾）。
  void _jumpToNextFloor() {
    final chatRounds = _chatRoundsNow();
    if (chatRounds.isEmpty) return;
    final current = _floorJumpCurrent;
    if (current == null) return;
    final position = _chatPositionOfRoundIndex(chatRounds, current.roundIndex);
    if (position < 0) return;
    _userScrolledAway = true;
    if (position < chatRounds.length - 1) {
      _jumpToItem(2 * (position + 1));
    } else {
      _scrollToBottom();
    }
  }

  /// 在 chatRounds 中按 roundIndex 查找位置；不存在返回 -1。
  int _chatPositionOfRoundIndex(List<Round> chatRounds, int roundIndex) {
    for (var i = 0; i < chatRounds.length; i++) {
      if (chatRounds[i].roundIndex == roundIndex) return i;
    }
    return -1;
  }

  /// 跳转到指定列表项：标记目标（唯一 GlobalKey 挂载到该项供精确对齐），
  /// 先按估算偏移粗定位，再帧末校准到精确偏移。
  void _jumpToItem(int itemIndex) {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    if (_floorJumpTargetIndex != itemIndex) {
      setState(() => _floorJumpTargetIndex = itemIndex);
    }
    final estimate = _modeledItemOffset(itemIndex).clamp(0.0, pos.maxScrollExtent);
    pos.jumpTo(estimate);
    _scheduleRefineJump(itemIndex, 0);
  }

  void _scheduleRefineJump(int itemIndex, int attempt) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _refineJump(itemIndex, attempt);
    });
  }

  /// 校准跳转：目标项已构建（唯一 GlobalKey 已挂载）→ 用
  /// [RenderAbstractViewport.getOffsetToReveal] 精确对齐视口顶；
  /// 未构建 → 用完整偏移模型估算目标偏移并跳转。每次跳转都会构建目标
  /// 附近的项，实测高度随之补充、估算误差随迭代收缩（最多
  /// [_kFloorJumpMaxRefine] 次）。
  void _refineJump(int itemIndex, int attempt) {
    if (!_scrollController.hasClients) return;
    if (attempt > _kFloorJumpMaxRefine) return;
    final pos = _scrollController.position;
    final ro = _floorJumpTargetIndex == itemIndex
        ? _floorJumpTargetKey.currentContext?.findRenderObject() as RenderBox?
        : null;
    if (ro != null && ro.attached) {
      final vp = RenderAbstractViewport.of(ro);
      final reveal = vp.getOffsetToReveal(ro, 0.0).offset;
      final target = reveal.clamp(0.0, pos.maxScrollExtent);
      pos
          .animateTo(
            target,
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOut,
          )
          .then((_) {
        // 动画结束后再检测当前轮次：动画中途检测会读到中间位置导致
        // 「当前轮/是否在起点」短暂失真（驱动悬浮条数字与箭头状态）。
        if (!mounted) return;
        try {
          _detectFloorJumpCurrent();
        } catch (_) {
          // 检测仅为状态刷新，任何异常都不应影响跳转结果。
        }
      });
      // 跳转完成：释放目标标记（下次跳转再挂载）。
      if (_floorJumpTargetIndex == itemIndex) {
        _floorJumpTargetIndex = null;
      }
      return;
    }
    // 目标未构建：用完整偏移模型校正方向与距离。
    pos.jumpTo(_modeledItemOffset(itemIndex).clamp(0.0, pos.maxScrollExtent));
    _scheduleRefineJump(itemIndex, attempt + 1);
  }

  /// 估算 [fromIndex, toIndex) 各项高度之和（已测用实测，未测用分类型均值）。
  double _estimateGap(int fromIndex, int toIndex) {
    var sum = 0.0;
    for (var i = fromIndex; i < toIndex; i++) {
      sum += _itemHeights[i] ?? _avgItemHeightFor(i);
    }
    return sum;
  }

  /// 估算指定列表项在滚动坐标系中的起点偏移：
  /// 顶部 padding + 前序各项高度（已测用实测，未测用分类型均值）。
  double _estimateItemOffset(int itemIndex) {
    var sum = 24.0; // ListView 顶部 padding。
    for (var i = 0; i < itemIndex; i++) {
      sum += _itemHeights[i] ?? _avgItemHeightFor(i);
    }
    return sum;
  }

  /// 分类型平均高度：偶数项（用户气泡）小、奇数项（AI 气泡）大，分开估算更准。
  double _avgItemHeightFor(int itemIndex) {
    final isUser = itemIndex.isEven;
    var total = 0.0;
    var count = 0;
    for (final e in _itemHeights.entries) {
      if (e.key.isEven != isUser) continue;
      total += e.value;
      count++;
    }
    if (count > 0) return total / count;
    return isUser ? _kFloorJumpDefaultUserHeight : _kFloorJumpDefaultAiHeight;
  }

  /// 开始一次生成：把本次应携带的图片设为「生成中」用户气泡的内容，
  /// 并复位自动跟随 / 新内容状态、滚动到底部。
  ///
  /// 供 发送 / 修改并重新提问 / 重新提问 / 失败重试 等所有生成入口复用，
  /// 确保「生成一开始气泡就带图片」。不触碰待发送附件 [_pendingImages]
  /// （发送方由调用处自行清空，其它场景保留未发送的图片）。
  void _startGeneration({required List<String> images}) {
    setState(() => _sendingImages = List.of(images));
    _userScrolledAway = false;
    _newContentDot = false;
    _scrollToBottom();
  }

  /// 结束一次生成：清空「生成中」气泡图片占位，并对底部滚动 / 红点统一收尾。
  void _endGeneration() {
    if (mounted) setState(() => _sendingImages.clear());
    _onGenerationFinished();
  }

  Future<void> _send() async {
    final input = _inputController.text.trim();
    if (input.isEmpty) return;
    final book = context.read<BookProvider>().currentBook;
    if (book == null) return;
    final roundProvider = context.read<RoundProvider>();
    // 生成期间防重复提交（输入框 onSubmitted 回车也可能触发 _send）。
    if (roundProvider.isSending) return;

    // 发送：先把待发送图片上屏到「生成中」用户气泡，同时立即清空输入框附件。
    final images = List<String>.from(_pendingImages);
    _startGeneration(images: images);
    setState(() => _pendingImages.clear());
    _inputController.clear();

    final ok = await roundProvider.sendRound(
      userInput: input,
      book: book,
      userImages: images,
    );

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
    _endGeneration();
  }

  /// 打开平台文件选择器导入图片（仅识图模型可用）。
  ///
  /// 校验大小上限并去重落盘，成功后加入当前待发送附件；失败/超限给出提示。
  Future<void> _importImages() async {
    final ai = context.read<AiSettingsProvider>();
    if (!ai.supportsVision) return;
    final service = context.read<ImageImportService>();
    setState(() {
      _isImportingImages = true;
      _importDone = 0;
      _importTotal = 0;
    });
    try {
      final result = await service.importImages(
        sizeLimitMb: ai.maxImageSizeMB,
        convertJpgToJpeg: ai.convertJpgToJpeg,
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() {
            _importDone = done;
            _importTotal = total;
          });
        },
      );
      if (!mounted) return;
      if (result.paths.isNotEmpty) {
        setState(() => _pendingImages.addAll(result.paths));
        _reviveImages(result.paths);
      }
      if (result.warnings.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result.warnings.join('\n'))),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isImportingImages = false;
          _importDone = 0;
          _importTotal = 0;
        });
      }
    }
  }

  /// 从待发送附件中移除一张图片。
  void _removePendingImage(String relPath) {
    setState(() => _pendingImages.remove(relPath));
  }

  /// 图片"再添加复活"：若 [paths] 命中待推送删除墓碑，取消删除意图。
  ///
  /// 供导入 / 拖拽 / 粘贴保存后调用；复用 [ImageRevivalService] 便于测试注入。
  void _reviveImages(Iterable<String> paths) {
    final revival = context.read<ImageRevivalService>();
    for (final rel in paths) {
      revival.revive(rel);
    }
  }

  /// 从剪贴板粘贴到输入框：文本插入光标处；图片按识图门控加入待发送附件。
  ///
  /// 供 Ctrl+V 与右键菜单「粘贴」复用（见 [textFieldContextMenuBuilder]），
  /// 统一走 [pasteIntoTextInput] 处理文本 / 图片与超限 / 非识图提示。
  Future<void> _pasteFromClipboard() async {
    final service = context.read<ClipboardPasteService>();
    final ai = context.read<AiSettingsProvider>();
    // 先取 messenger，避免异步后使用失效的 context。
    final messenger = ScaffoldMessenger.of(context);
    await pasteIntoTextInput(
      service: service,
      controller: _inputController,
      acceptImages: ai.supportsVision,
      imageSizeLimitMb: ai.maxImageSizeMB,
      convertJpgToJpeg: ai.convertJpgToJpeg,
      onImageAdded: (rel) {
        if (mounted) setState(() => _pendingImages.add(rel));
        _reviveImages([rel]);
      },
      onNotice: (msg) => messenger.showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Windows 拖拽导入
  // ---------------------------------------------------------------------------
  void _onDragEntered() => setState(() => _dragTargeted = true);

  void _onDragExited() => setState(() => _dragTargeted = false);

  /// 拖拽文件到输入区：按大小上限校验并以哈希去重保存（仅识图模型）。
  Future<void> _onDragDone(DropDoneDetails details) async {
    _onDragExited();
    final ai = context.read<AiSettingsProvider>();
    if (!ai.supportsVision) return;
    final files = details.files;
    if (files.isEmpty) return;
    final maxBytes = ai.maxImageSizeMB * 1024 * 1024;
    setState(() {
      _isImportingImages = true;
      _importDone = 0;
      _importTotal = files.length;
    });
    final saved = <String>[];
    final warnings = <String>[];
    for (var i = 0; i < files.length; i++) {
      final f = files[i];
      try {
        final file = File(f.path);
        final size = await file.length();
        if (size > maxBytes) {
          warnings.add(
            '「${f.name}」超过 ${ai.maxImageSizeMB}MB，请压缩后重试。',
          );
        } else {
          final bytes = await file.readAsBytes();
          saved.add(
            await ImageStore.saveBytes(
              bytes,
              filename: f.path,
              convertJpgToJpeg: ai.convertJpgToJpeg,
            ),
          );
        }
      } catch (e) {
        warnings.add('「${f.name}」导入失败：$e');
      }
      if (mounted) {
        setState(() {
          _importDone = i + 1;
          _importTotal = files.length;
        });
      }
    }
    if (!mounted) return;
    _reviveImages(saved);
    setState(() {
      _pendingImages.addAll(saved);
      _isImportingImages = false;
    });
    if (warnings.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(warnings.join('\n'))),
      );
    }
  }

  /// 桌面端（Windows）把输入卡包进拖拽目标；其它平台原样返回。
  Widget _dropTargetWrap(Widget child) {
    if (!Platform.isWindows) return child;
    return Stack(
      children: [
        DropTarget(
          onDragEntered: (_) => _onDragEntered(),
          onDragExited: (_) => _onDragExited(),
          onDragDone: _onDragDone,
          child: child,
        ),
        if (_dragTargeted)
          Positioned.fill(child: _DragToImportHint()),
      ],
    );
  }

  /// 重新提问失败条目：以失败时的输入与图片重新生成（sendRound 会先清空失败条目）。
  ///
  /// 失败条目携带图片（识图模型）时，「生成中」气泡随之带图；不触碰待发送附件。
  Future<void> _retryFailure() async {
    final rp = context.read<RoundProvider>();
    final input = rp.failedUserInput;
    final images = rp.failedUserImages;
    if (input.isEmpty || rp.isSending) return;
    final book = context.read<BookProvider>().currentBook;
    if (book == null) return;
    _startGeneration(images: images);
    await rp.sendRound(userInput: input, book: book, userImages: images);
    _endGeneration();
  }

  /// 修改并重新提问失败条目：编辑失败时的输入后重新生成（识图模型可增删图片）。
  Future<void> _editAndRetryFailure() async {
    final rp = context.read<RoundProvider>();
    final input = rp.failedUserInput;
    if (input.isEmpty || rp.isSending) return;
    final book = context.read<BookProvider>().currentBook;
    if (book == null) return;
    final ai = context.read<AiSettingsProvider>();
    EditTextImagesResult? result;
    if (ai.supportsVision) {
      result = await showEditTextImagesDialog(
        context,
        title: '修改并重新提问',
        initial: input,
        initialImages: rp.failedUserImages,
        allowImages: true,
        imageImport: context.read<ImageImportService>(),
        maxImageSizeMB: ai.maxImageSizeMB,
        convertJpgToJpeg: ai.convertJpgToJpeg,
      );
    } else {
      String? edited;
      await _showEditTextDialog(
        title: '修改并重新提问',
        initial: input,
        onSave: (text) async => edited = text,
      );
      if (edited != null) result = EditTextImagesResult(edited!, const []);
    }
    if (result == null || !mounted) return;
    _startGeneration(images: result.images);
    await rp.sendRound(
      userInput: result.text,
      book: book,
      userImages: result.images,
    );
    _endGeneration();
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

  /// 修改用户输入并重新提问：先编辑该轮输入（识图模型可增删图片），保存后
  /// 删除本轮及后续所有轮次，再以修改后的输入重新生成（替换而非追加）。
  Future<void> _handleEditAndReAsk(Round round) async {
    final book = context.read<BookProvider>().currentBook;
    if (book == null) return;
    final ai = context.read<AiSettingsProvider>();
    EditTextImagesResult? result;
    if (ai.supportsVision) {
      result = await showEditTextImagesDialog(
        context,
        title: '修改并重新提问（第 ${round.roundIndex} 轮）',
        initial: round.userInput,
        initialImages: round.userImages,
        allowImages: true,
        imageImport: context.read<ImageImportService>(),
        maxImageSizeMB: ai.maxImageSizeMB,
        convertJpgToJpeg: ai.convertJpgToJpeg,
      );
    } else {
      String? edited;
      await _showEditTextDialog(
        title: '修改并重新提问（第 ${round.roundIndex} 轮）',
        initial: round.userInput,
        // 仅记录修改后的文本；落库由 editAndReAsk 统一处理，避免重复写库。
        onSave: (text) async => edited = text,
      );
      if (edited != null) result = EditTextImagesResult(edited!, const []);
    }
    if (result == null || !mounted) return;
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
    // 重新生成开始即把图片送入「生成中」用户气泡（替换修改后的图片）。
    _startGeneration(images: result.images);
    await context.read<RoundProvider>().editAndReAsk(
      round,
      result.text,
      book: book,
      images: result.images,
    );
    _endGeneration();
  }

  /// 重新提问（与「刷新本轮」合并）：删除本轮及后续所有轮次，
  /// 再以该轮的用户输入重新请求 AI（替换而非追加）。
  Future<void> _handleReAsk(Round round) async {
    final ok = await showReAskConfirmDialog(context, round);
    if (!ok || !mounted) return;
    final book = context.read<BookProvider>().currentBook;
    if (book == null) return;
    // 重新生成开始即把该轮图片送入「生成中」用户气泡。
    _startGeneration(images: round.userImages);
    await context.read<RoundProvider>().refreshRound(round, book: book);
    _endGeneration();
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
            // 悬浮进程提示：盖在对话区上方（不占位、不遮挡右侧栏），宽窄屏一致。
            final chatWithBanner = Stack(
              children: [
                Positioned.fill(child: chat),
                Positioned(
                  top: 8,
                  left: 0,
                  right: 0,
                  child: GenerationBanner(
                    excludeBookUuid:
                        context.watch<BookProvider>().currentBook?.uuid,
                    onOpenBook: _jumpToBook,
                  ),
                ),
              ],
            );
            return wide
                ? _buildWideLayout(context, chatWithBanner, sidebar)
                : _buildMobileLayout(context, chatWithBanner, sidebar);
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

  /// 跳转到指定书对话页（替换当前对话页，展示该书的生成状态）。
  void _jumpToBook(Book book) {
    context.read<BookProvider>().selectBook(book);
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => const ChatScreen(),
        settings: RouteSettings(name: chatRouteName, arguments: book.uuid),
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
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // 对话区
  // ---------------------------------------------------------------------------
  Widget _buildChatArea(BuildContext context) {
    final roundProvider = context.watch<RoundProvider>();
    final bookProvider = context.watch<BookProvider>();
    // 首帧建造时当前书可能尚未就绪（异步加载）：书就绪并触发重建后，
    // 补执行「打开书籍 → 跳转到底部」初始化（幂等，见 _ensureInitialScroll）。
    _ensureInitialScroll();
    final rounds = roundProvider.rounds;
    // 第零轮（初始状态）不参与气泡展示。
    final chatRounds = rounds.where((r) => r.roundIndex > 0).toList();
    // 楼层跳转：轮次来源（引用+长度）或窗口宽度变化时清空实测数据缓存。
    if (!identical(rounds, _lastRoundsSource) ||
        rounds.length != _lastRoundsCount ||
        (MediaQuery.sizeOf(context).width - _lastLayoutWidth).abs() > 0.5) {
      _itemHeights.clear();
      _itemOffsets.clear();
      _lastRoundsSource = rounds;
      _lastRoundsCount = rounds.length;
      _lastLayoutWidth = MediaQuery.sizeOf(context).width;
    }
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
        padding: EdgeInsets.fromLTRB(20, 24, 20, _composerHeight + 8),
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
              child: ChatBubble(
                isUser: true,
                text: pendingInput,
                images: List.of(_sendingImages),
              ),
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
                  images: round.userImages,
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
                  images: round.aiImages,
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
          // 楼层跳转：包一层自上报部件（帧末回报该项位置/高度，不使用逐项
          // GlobalKey）；跳转目标项额外挂载唯一的 [_floorJumpTargetKey]。
          return _FloorMeasuredItem(
            itemIndex: index,
            onReport: _onItemMeasured,
            child: Center(
              key: index == _floorJumpTargetIndex
                  ? _floorJumpTargetKey
                  : null,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: _kContentMaxWidth),
                child: item,
              ),
            ),
          );
        },
      ),
    );

    // 楼层跳转：悬浮条打开时帧末检测当前轮次（驱动中间数字刷新）
    // 并重新定位（跟随按钮位置变化）。
    if (_floorJumpOpen) {
      _scheduleFloorJumpDetect();
      _scheduleFloorJumpPosition();
    }

    // 悬浮条数据（楼层跳转）。
    final chatRoundsNow = chatRounds;
    final maxFloorRound = chatRoundsNow.isEmpty
        ? 0
        : chatRoundsNow.last.roundIndex;
    final floorCurrent = _floorJumpCurrent;
    final floorPosition = floorCurrent == null
        ? -1
        : _chatPositionOfRoundIndex(chatRoundsNow, floorCurrent.roundIndex);
    final floorCanPrev = floorCurrent != null &&
        !(floorCurrent.atStart && floorPosition == 0);

    return Stack(
      key: _floorJumpStackKey,
      children: [
        // 消息区铺满（底部留白避免被悬浮输入面板遮挡）。
        // 固定 key：浮层开合不重建消息区元素。
        // Listener 监听消息区的指针/滚轮：悬浮条打开时，用户点击/滑动/滚轮
        // 消息区即收起悬浮条（自动向下滚动无指针事件，不会误收起）。
        Positioned.fill(
          key: const Key('chat_messages_area'),
          child: Listener(
            onPointerDown: (_) {
              if (_floorJumpOpen) _closeFloorJump();
            },
            onPointerSignal: (event) {
              if (_floorJumpOpen && event is PointerScrollEvent) {
                _closeFloorJump();
              }
            },
            child: Container(
              // 与各边栏一致的内容表面背景。
              color: context.narrColors.surface,
              child: chatRounds.isEmpty && !showPending && !showFailure
                  ? _buildEmptyState(context, bookProvider.currentBook)
                  // 原生滚动条（主题已统一为常显细圆角拇指），流式/滚动自动跟随。
                  : messagesList,
            ),
          ),
        ),
        // 伪悬浮输入面板：底部覆盖，同色背景遮挡其后的文本（仅留小空隙）。
        // 固定 key：浮层开合不重建输入面板元素（避免丢失焦点/状态）。
        Positioned(
          key: const Key('chat_composer_area'),
          left: 0,
          right: 0,
          bottom: 0,
          child: NotificationListener<SizeChangedLayoutNotification>(
            onNotification: (_) {
              _measureComposerHeight();
              return false;
            },
            child: SizeChangedLayoutNotifier(
              child: _buildComposer(context),
            ),
          ),
        ),
        // 楼层跳转悬浮条：作为对话区 Stack 的悬浮子项（不参与按钮行布局，
        // 三个按钮的结构与位置不受影响），按按钮实测位置定位在按钮正上方。
        if (_floorJumpOpen && _floorJumpBarTop != null)
          Positioned(
            top: _floorJumpBarTop!,
            right: _floorJumpBarRight ?? 20,
            child: _FloorJumpBarAppearance(
              child: FloorJumpBar(
                currentRound: floorCurrent?.roundIndex ?? 0,
                maxRound: maxFloorRound,
                canPrev: floorCanPrev,
                onPrev: _jumpToPrevFloor,
                onNext: _jumpToNextFloor,
                onJumpTo: (roundIndex) {
                  _jumpToFloorRound(roundIndex);
                  // 回车定点跳转后关闭悬浮条（一次性跳转）；
                  // 左右箭头步进则保持打开便于连续翻阅。
                  _closeFloorJump();
                },
              ),
            ),
          ),
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

  /// 帧末测量悬浮输入面板高度，驱动消息列表底部留白。
  ///
  /// 输入框增行/减行、方形按钮显隐等导致面板高度变化时，
  /// [SizeChangedLayoutNotification] 会触发本方法重新测量。
  void _measureComposerHeight() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final box =
          _composerKey.currentContext?.findRenderObject() as RenderBox?;
      final height = box?.size.height ?? 0;
      if (height != _composerHeight && mounted) {
        setState(() => _composerHeight = height);
      }
    });
  }

  /// 伪悬浮输入面板：底部通栏使用与消息区同色的背景，遮挡其后方滚动的文本；
  /// 距底仅留一小点空隙。
  ///
  /// 输入卡上方的方形按钮行**不落入底色面板**——视觉上真悬浮于消息区之上；
  /// 宽屏右侧栏常驻（展开）时隐藏「打开右侧栏」按钮，仅保留滚动到底部按钮；
  /// 按钮行始终右对齐（自动贴右，避免观感奇怪）。
  Widget _buildComposer(BuildContext context) {
    final roundProvider = context.watch<RoundProvider>();
    final isSending = roundProvider.isSending;
    // 宽屏侧栏常驻时无需「打开右侧栏」；窄屏/侧栏收起时保留。
    final showSidebarButton = !(_isWide && _sidebarOpen);
    // 楼层跳转：无聊天轮次（仅第零轮）时隐藏入口。
    final chatRoundsNow = roundProvider.rounds
        .where((r) => r.roundIndex > 0)
        .toList();

    return Container(
      key: _composerKey,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _kContentMaxWidth),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // 输入框外部上方右侧：1:1 方形按钮（从右往左 = 打开侧栏、滚动到底部、楼层跳转）。
              // 真悬浮：直接浮于消息区之上，不被底色面板框住。
              // 楼层跳转悬浮条渲染在对话区 Stack 中（见 _buildChatArea），
              // 不参与本行布局——三个按钮的结构与位置始终不受影响。
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (chatRoundsNow.isNotEmpty) ...[
                    _ComposerSquareButton(
                      key: _floorJumpButtonKey,
                      icon: Icons.layers_outlined,
                      tooltip: '楼层跳转',
                      onPressed: _toggleFloorJump,
                    ),
                    const SizedBox(width: 8),
                  ],
                  _ComposerSquareButton(
                    icon: Icons.vertical_align_bottom,
                    tooltip: '滚动到底部',
                    dotVisible: _newContentDot,
                    onPressed: _scrollToBottom,
                  ),
                  if (showSidebarButton) ...[
                    const SizedBox(width: 8),
                    _ComposerSquareButton(
                      icon: Icons.view_sidebar_outlined,
                      tooltip: '打开右侧边栏',
                      onPressed: _onToggleSidebar,
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              // 底色面板：仅遮挡输入卡的下方与左右两侧（不含按钮行）。
              Container(
                width: double.infinity,
                color: context.narrColors.surface,
                padding: const EdgeInsets.only(bottom: 12),
                child: _dropTargetWrap(
                  _buildComposerCard(context, roundProvider, isSending),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 打开 / 收起右侧状态栏（宽屏切换固定侧栏，窄屏切换抽屉）。
  void _onToggleSidebar() {
    if (_isWide) {
      _setSidebarOpen(!_sidebarOpen);
    } else {
      if (_drawerOpen) {
        _closeDrawer();
      } else {
        _openDrawer();
      }
    }
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

  /// 输入卡：多行输入框（3 行起步、最高 8 行，超出内滚，Markdown 高亮自动）
  /// + 左下角选项下拉 + 右下角发送/停止按钮。
  Widget _buildComposerCard(
    BuildContext context,
    RoundProvider roundProvider,
    bool isSending,
  ) {
    final aiSettings = context.watch<AiSettingsProvider>();
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.narrColors.divider),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 待发送图片缩略条 + 导入进度：置于输入框上方、靠左，
          // 避免图片卡片在输入框下方居中而显得突兀。
          if (_isImportingImages)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    _importTotal > 0
                        ? '正在导入图片 $_importDone/$_importTotal…'
                        : '正在导入图片…',
                    style: TextStyle(
                      fontSize: 12,
                      color: context.narrColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  // 用户可感知进度条（总数为 0 时为静态 0，避免不确定动画悬挂）。
                  LinearProgressIndicator(
                    value: _importTotal > 0 ? _importDone / _importTotal : 0,
                  ),
                ],
              ),
            )
          else if (_pendingImages.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: ImagePreviewStrip(
                  key: const Key('composer_image_strip'),
                  images: List.of(_pendingImages),
                  size: 72,
                  onTapImage: (_, i) => showImageViewer(
                    context,
                    List.of(_pendingImages),
                    i,
                    // 查看器删除后同步移除待发送列表项，避免发出时已缺失。
                    onDeleted: (rel) {
                      if (mounted) setState(() => _pendingImages.remove(rel));
                    },
                  ),
                  onRemove: _removePendingImage,
                ),
              ),
            ),
          // 快捷键：Ctrl+V 粘贴（含图片）；Ctrl+Enter 发送。
          CallbackShortcuts(
            bindings: {
              ...textFieldPasteBindings(onPaste: _pasteFromClipboard),
              // Ctrl+Enter：直接发送（多行输入框的回车默认是换行，不触发发送）。
              const SingleActivator(LogicalKeyboardKey.enter, control: true):
                  _send,
            },
            child: TextField(
              controller: _inputController,
              onTapOutside: unfocusOnTapOutside,
              minLines: 3,
              maxLines: 8,
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
                contentPadding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
              ),
              contextMenuBuilder: textFieldContextMenuBuilder(
                onPaste: _pasteFromClipboard,
              ),
              onSubmitted: (_) => _send(),
            ),
          ),
          // 底部行：左下角功能选择栏 + 中间空隙 + 右下角模型选择 + 发送/停止。
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: LayoutBuilder(
              builder: (context, constraints) {
                const sendWidth = 36.0;
                const endGap = 8.0;
                // 留给「左/右两个区域」的可用宽度（去掉发送按钮与其左侧固定间距）。
                final available = (constraints.maxWidth - sendWidth - endGap)
                    .clamp(0.0, double.infinity);
                return Row(
                  children: [
                    // 左侧功能选择栏：最长 2/3，单行溢出省略，左对齐。
                    ConstrainedBox(
                      constraints:
                          BoxConstraints(maxWidth: available * (2 / 3)),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        widthFactor: 1,
                        heightFactor: 1,
                        child: _ChatModeDropdown(
                          supportsThinking: aiSettings.supportsThinking,
                          supportsStreaming: aiSettings.supportsStreaming,
                          supportsSearch: aiSettings.supportsSearch,
                          supportsVision: aiSettings.supportsVision,
                          thinking: aiSettings.thinking,
                          streaming: aiSettings.streaming,
                          search: aiSettings.lastSearch,
                          onThinkingChanged: (v) =>
                              _setPerRoundOptions(thinking: v),
                          onStreamingChanged: (v) =>
                              _setPerRoundOptions(streaming: v),
                          onSearchChanged: (v) =>
                              _setPerRoundOptions(search: v),
                          onImportImages: _importImages,
                        ),
                      ),
                    ),
                    // 中间空隙：左右都未达到上限时的弹性空间。
                    const Spacer(),
                    // 右侧模型选择器：最长 1/3，右对齐，灰色，单行溢出省略。
                    ConstrainedBox(
                      constraints:
                          BoxConstraints(maxWidth: available * (1 / 3)),
                      child: Align(
                        alignment: Alignment.centerRight,
                        widthFactor: 1,
                        heightFactor: 1,
                        child: _ModelSelector(
                          label: aiSettings.selectedModel.displayLabel,
                          platforms: aiSettings.platforms,
                          selectedPlatformId: aiSettings.selectedPlatformId,
                          selectedModelId: aiSettings.selectedModelId,
                          onSelect: (platformId, modelId) =>
                              aiSettings.setSelectedModel(platformId, modelId),
                        ),
                      ),
                    ),
                    const SizedBox(width: endGap),
                    SizedBox(
                      width: sendWidth,
                      height: 36,
                      child: IconButton.filled(
                        // 生成中：点击中断生成（仍显示加载图标）；空闲：发送。
                        onPressed: isSending
                            ? roundProvider.cancelGeneration
                            : _send,
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
                  ],
                );
              },
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

/// 拖拽图片进入输入区时显示的「松开以导入」提示浮层。
class _DragToImportHint extends StatelessWidget {
  const _DragToImportHint();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(14),
      ),
      alignment: Alignment.center,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.image_outlined, color: scheme.onPrimaryContainer),
          const SizedBox(width: 8),
          Text(
            '松开以导入图片',
            style: TextStyle(
              color: scheme.onPrimaryContainer,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// 聊天模式选项下拉（复用原每轮选项开关的视觉）。
///
/// - 收起时显示当前启用选项摘要（如「无」「流式 | 思考 | 搜索(BETA)」，
///   搜索段用警告色，不加粗）；流式/思考启用时触发按钮为主题蓝边框+文字；
/// - 展开为复选菜单，切换后保持展开可连续操作；
/// - 联网搜索行始终显示 BETA 试验版二级提示（启用=警告色，未启用=灰）；
/// - 模型支持识图时，菜单底部提供「导入图片」入口。
class _ChatModeDropdown extends StatelessWidget {
  final bool supportsThinking;
  final bool supportsStreaming;
  final bool supportsSearch;
  final bool supportsVision;
  final bool thinking;
  final bool streaming;
  final bool search;
  final ValueChanged<bool> onThinkingChanged;
  final ValueChanged<bool> onStreamingChanged;
  final ValueChanged<bool> onSearchChanged;
  final VoidCallback onImportImages;

  const _ChatModeDropdown({
    required this.supportsThinking,
    required this.supportsStreaming,
    required this.supportsSearch,
    required this.supportsVision,
    required this.thinking,
    required this.streaming,
    required this.search,
    required this.onThinkingChanged,
    required this.onStreamingChanged,
    required this.onSearchChanged,
    required this.onImportImages,
  });

  /// 摘要各段（顺序：流式 | 思考 | 搜索(BETA)）。
  List<String> get _activeParts => [
        if (supportsStreaming && streaming) '流式',
        if (supportsThinking && thinking) '思考',
        if (supportsSearch && search) '搜索(BETA)',
      ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 警告色取自主题（浅色=黄棕色、深色=明亮琥珀黄），随深浅模式自动适配。
    final warningColor = context.narrColors.warning;
    final parts = _activeParts;
    // 触发按钮态：流式/思考任一启用 → 主题蓝；仅搜索启用 → 警告黄；全关 → 灰。
    final blueActive =
        (supportsStreaming && streaming) ||
        (supportsThinking && thinking);
    final searchOnlyActive = !blueActive && supportsSearch && search;
    final triggerActive = blueActive || searchOnlyActive;
    final Color triggerColor = blueActive
        ? scheme.primary
        : searchOnlyActive
            ? warningColor
            : scheme.onSurfaceVariant;

    return MenuAnchor(
      // 开启 Material 菜单开合动画（打开 500ms / 关闭 150ms，含高度/透明度/
      // 菜单项错落淡入淡出），与右键/长按菜单、下拉字段的动画观感一致。
      animated: true,
      style: MenuStyle(
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      menuChildren: [
        if (supportsThinking)
          _ModeMenuRow(
            label: '思考',
            active: thinking,
            onChanged: onThinkingChanged,
          ),
        if (supportsStreaming)
          _ModeMenuRow(
            label: '流式',
            active: streaming,
            onChanged: onStreamingChanged,
          ),
        if (supportsSearch)
          _ModeMenuRow(
            label: '搜索',
            active: search,
            onChanged: onSearchChanged,
            activeLabelColor: warningColor,
            // 二级提示始终显示（启用/禁用一致），且在按钮内可整体点击切换；
            // 未启用时为灰色，启用后为警告色。
            subtitle: '此功能为试验版，存在大量问题，启动会数倍增加 token 消耗',
            subtitleColor: search ? warningColor : scheme.onSurfaceVariant,
          ),
        if (supportsVision) ...[
          const Divider(height: 8),
          MenuItemButton(
            closeOnActivate: false,
            leadingIcon: Icon(Icons.image_outlined, size: 18),
            onPressed: onImportImages,
            child: const Text('导入图片'),
          ),
        ],
      ],
      builder: (context, controller, _) {
        return InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () {
            if (controller.isOpen) {
              controller.close();
            } else {
              controller.open();
            }
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              // 启用：主题色淡底 + 主题色边框；全关：浅灰底无边框。
              color: triggerActive
                  ? triggerColor.withValues(alpha: 0.08)
                  : scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
              border: triggerActive
                  ? Border.all(color: triggerColor, width: 1.2)
                  : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.tune, size: 14, color: triggerColor),
                const SizedBox(width: 6),
                // 摘要：分段渲染，搜索(BETA) 用警告色（不加粗）；无启用项时显示「无」；
                // 单行溢出省略（受外层 2/3 宽度上限约束）。
                Flexible(
                  child: Text.rich(
                    TextSpan(
                      children: parts.isEmpty
                          ? const [TextSpan(text: '无')]
                          : [
                              for (var i = 0; i < parts.length; i++) ...[
                                if (i > 0) const TextSpan(text: ' | '),
                                TextSpan(
                                  text: parts[i],
                                  style: TextStyle(
                                    color: parts[i] == '搜索(BETA)'
                                        ? warningColor
                                        : triggerColor,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: triggerColor),
                  ),
                ),
                const SizedBox(width: 6),
                Icon(
                  controller.isOpen
                      ? Icons.arrow_drop_up
                      : Icons.arrow_drop_down,
                  size: 18,
                  color: triggerColor,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 右下角模型选择器：显示当前模型名（灰色、单行省略），点击弹出菜单切换对话模型。
class _ModelSelector extends StatelessWidget {
  final String label;
  final List<AiPlatform> platforms;
  final String selectedPlatformId;
  final String selectedModelId;
  final void Function(String platformId, String modelId) onSelect;

  const _ModelSelector({
    required this.label,
    required this.platforms,
    required this.selectedPlatformId,
    required this.selectedModelId,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final gray = Theme.of(context).colorScheme.onSurfaceVariant;
    return MenuAnchor(
      animated: true,
      style: MenuStyle(
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      menuChildren: [
        for (final platform in platforms) ..._platformMenuItems(platform, gray),
      ],
      builder: (context, controller, _) {
        return InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () {
            if (controller.isOpen) {
              controller.close();
            } else {
              controller.open();
            }
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: gray),
                  ),
                ),
                const SizedBox(width: 4),
                Icon(Icons.arrow_drop_down, size: 18, color: gray),
              ],
            ),
          ),
        );
      },
    );
  }

  List<Widget> _platformMenuItems(AiPlatform platform, Color gray) {
    final isSelectedPlatform = platform.id == selectedPlatformId;
    return [
      // 平台分组标题（非交互项）。
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Text(
          platform.displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: gray,
          ),
        ),
      ),
      for (final model in platform.models)
        MenuItemButton(
          onPressed: () => onSelect(platform.id, model.id),
          child: Row(
            children: [
              Icon(
                isSelectedPlatform && model.id == selectedModelId
                    ? Icons.check
                    : Icons.label_outline,
                size: 16,
                color: gray,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  model.displayLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
        ),
    ];
  }
}

/// 下拉菜单复选行（复用原 `_ModeToggleChip` 视觉）。
///
/// 激活态文本/图标用主题色（避免白字在浅色菜单上不可见）；
/// 可带始终显示的二级提示（[subtitle]），整行（含二级文本）均可点击切换。
class _ModeMenuRow extends StatelessWidget {
  final String label;
  final bool active;
  final ValueChanged<bool> onChanged;

  /// 激活时的文字/图标颜色（默认主题色；搜索行传黄色）。
  final Color? activeLabelColor;

  /// 二级提示文本（如搜索的 BETA 试验版警告），始终显示且可点击。
  final String? subtitle;
  final Color? subtitleColor;

  const _ModeMenuRow({
    required this.label,
    required this.active,
    required this.onChanged,
    this.activeLabelColor,
    this.subtitle,
    this.subtitleColor,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = active
        ? (activeLabelColor ?? scheme.primary)
        : scheme.onSurfaceVariant;
    final sub = subtitle;
    return MenuItemButton(
      // 保持菜单展开，便于连续切换多个选项。
      closeOnActivate: false,
      onPressed: () => onChanged(!active),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                active ? Icons.check_circle : Icons.circle_outlined,
                size: 13,
                color: color,
              ),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color: color,
                  fontWeight: active ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ],
          ),
          if (sub != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                sub,
                style: TextStyle(
                  fontSize: 11,
                  color: subtitleColor ?? scheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 楼层跳转：悬浮条浮层的「打开动画」外壳。
///
/// 浮层插入 Overlay 时播放淡入 + 自下而上滑入（约 200ms），
/// 使悬浮条打开不再生硬。关闭时浮层直接移除（无需反向动画）。
class _FloorJumpBarAppearance extends StatefulWidget {
  final Widget child;

  const _FloorJumpBarAppearance({required this.child});

  @override
  State<_FloorJumpBarAppearance> createState() => _FloorJumpBarAppearanceState();
}

class _FloorJumpBarAppearanceState extends State<_FloorJumpBarAppearance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );
  late final Animation<double> _fade = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOut,
  );
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, 0.2),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));

  @override
  void initState() {
    super.initState();
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(
        position: _slide,
        child: widget.child,
      ),
    );
  }
}

/// 楼层跳转：列表项自上报部件。
///
/// 构建/内容变化后在帧末回报该项「相对视口的顶部偏移」与「高度」
/// （通过 [onReport]），供楼层跳转检测与定位使用。刻意**不使用逐项
/// GlobalKey**（避免虚拟化列表中大量 GlobalKey 带来的元素/键冲突风险）：
/// 部件通过自身 context 找到 RenderBox 计算位置，且仅在帧末、mounted 时
/// 读取，无需父级持有任何键。
class _FloorMeasuredItem extends StatefulWidget {
  final int itemIndex;
  final void Function(int itemIndex, double viewportTop, double height) onReport;
  final Widget child;

  const _FloorMeasuredItem({
    required this.itemIndex,
    required this.onReport,
    required this.child,
  });

  @override
  State<_FloorMeasuredItem> createState() => _FloorMeasuredItemState();
}

class _FloorMeasuredItemState extends State<_FloorMeasuredItem> {
  @override
  void initState() {
    super.initState();
    _scheduleReport();
  }

  @override
  void didUpdateWidget(covariant _FloorMeasuredItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 内容/宽度变化导致高度变化时重新上报。
    _scheduleReport();
  }

  void _scheduleReport() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ro = context.findRenderObject();
      if (ro is! RenderBox) return;
      final vp = RenderAbstractViewport.of(ro);
      final y = ro.localToGlobal(Offset.zero, ancestor: vp).dy;
      widget.onReport(widget.itemIndex, y, ro.size.height);
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 输入面板上方的 1:1 方形按钮（40×40）。
///
/// [dotVisible] 为 true 时在右上角显示红点（如滚动到底部按钮在
/// 用户上翻离开底部时）。
class _ComposerSquareButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool dotVisible;

  const _ComposerSquareButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.dotVisible = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 40,
        height: 40,
        child: Stack(
          children: [
            Positioned.fill(
              child: Material(
                color: scheme.surfaceContainerLow,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: BorderSide(color: scheme.outlineVariant),
                ),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: onPressed,
                  child: Icon(icon, size: 18, color: scheme.onSurfaceVariant),
                ),
              ),
            ),
            // 红点：右上角。
            if (dotVisible)
              Positioned(
                top: 6,
                right: 6,
                child: Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: Colors.red,
                    shape: BoxShape.circle,
                  ),
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
  final bool refused;
  final List<SearchResult> results;

  const _SearchBox({
    super.key,
    required this.query,
    required this.searching,
    required this.failed,
    this.refused = false,
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
                    Icon(
                      Icons.close,
                      size: 14,
                      color: widget.refused
                          ? context.narrColors.warning
                          : const Color(0xFFE5484D),
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
        widget.refused
            ? '页面拒绝访问（HTTP 4xx/5xx），未能获取内容'
            : '搜索失败，未获取到结果',
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

/// 打开页面细节框：显示被打开的网页链接、状态（转圈 / ✓ / ✕）与跳转链。
class _FetchBox extends StatelessWidget {
  final String url;
  final bool searching;
  final bool failed;
  final bool refused;
  final List<FetchHop> hops;

  const _FetchBox({
    super.key,
    required this.url,
    required this.searching,
    required this.failed,
    this.refused = false,
    this.hops = const [],
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(
                Icons.open_in_new,
                size: 15,
                color: NarrChatTheme.primary,
              ),
              const SizedBox(width: 6),
              const Text(
                '打开页面',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: NarrChatTheme.primary,
                ),
              ),
              if (url.isNotEmpty) ...[
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    url,
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
              else if (failed)
                Icon(
                  Icons.close,
                  size: 14,
                  color: refused
                      ? context.narrColors.warning
                      : const Color(0xFFE5484D),
                )
              else
                const Icon(
                  Icons.check_circle,
                  size: 14,
                  color: NarrChatTheme.primary,
                ),
            ],
          ),
          // 跳转链：HTTP 重定向 / 应用级回退，流式列出。
          if (hops.isNotEmpty) ...[
            const SizedBox(height: 6),
            for (var i = 0; i < hops.length; i++) ...[if (i > 0) const SizedBox(height: 3), _HopLine(hop: hops[i])],
          ],
        ],
      ),
    );
  }
}

/// 抓取跳转链的一行：URL + 状态码 / 应用重定向。
class _HopLine extends StatelessWidget {
  final FetchHop hop;
  const _HopLine({required this.hop});

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    final isAppRedirect = hop.statusCode == null;
    return Row(
      children: [
        Icon(
          isAppRedirect ? Icons.swap_horiz : Icons.arrow_forward,
          size: 12,
          color: NarrChatTheme.primary,
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            hop.url,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: colors.textSecondary),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          isAppRedirect ? '应用重定向' : '${hop.statusCode}',
          style: TextStyle(
            fontSize: 11,
            color: isAppRedirect ? colors.warning : colors.textSecondary,
          ),
        ),
        const SizedBox(width: 3),
        const Icon(Icons.check, size: 12, color: NarrChatTheme.primary),
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
          // 思考内容同样调用统一 Markdown 渲染模块实时渲染。
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
              child: MarkdownPreview(
                data: widget.content,
                base: TextStyle(
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
                child: MarkdownPreview(
                  data: widget.content,
                  base: TextStyle(
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
                  // Agent 过程时间线：思考 / 搜索 / 打开页面按真实顺序交错，
                  // 每个框独立展开/折叠状态（按 index 作为 key 保持状态）。
                  for (var i = 0; i < events.length; i++) ...[
                    if (i > 0) const SizedBox(height: 8),
                    if (events[i].type == AgentEventType.thinking)
                      _ThinkingBox(
                        key: ValueKey('think_$i'),
                        content: events[i].content,
                        done: events[i].done,
                      )
                    else if (events[i].type == AgentEventType.search)
                      _SearchBox(
                        key: ValueKey('search_$i'),
                        query: events[i].content,
                        searching: events[i].searching,
                        failed: events[i].failed,
                        refused: events[i].refused,
                        results: events[i].results,
                      )
                    else
                      _FetchBox(
                        key: ValueKey('fetch_$i'),
                        url: events[i].content,
                        searching: events[i].searching,
                        failed: events[i].failed,
                        refused: events[i].refused,
                        hops: events[i].hops,
                      ),
                  ],
                  // 自动重试提示（灰字）：思考/搜索块之后、正文之前。
                  if (retry != null) ...[const SizedBox(height: 8), _RetryStatusText(attempt: retry.$1, total: retry.$2)],
                  // 剧情正文：调用统一 Markdown 渲染模块实时渲染（含末尾光标）。
                  if (hasContent) ...[
                    if (hasEvents) const Divider(height: 14),
                    MarkdownPreview(
                      data: '$content▍',
                      base: TextStyle(
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
