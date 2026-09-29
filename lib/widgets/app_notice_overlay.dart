import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_notice_center.dart';
import 'floating_notice_host.dart';
import 'pinned_notice_island.dart';

/// 应用内通知宿主：挂载两个渠道，并提供 [AppNoticeCenter] 作用域。
///
/// 挂在 `MaterialApp.builder`（位于 Navigator 之上）：
/// - 通知恒显示在页面与对话框之上（不再受 `ScaffoldMessenger` 的 Scaffold 约束）；
/// - `child`（Navigator 子树）位于本作用域之内，页面任意位置可用 `context.notices`；
/// - 通知宿主自带一层 [Overlay]：位于 Navigator 之上时没有现成 Overlay，
///   而提示里的 Tooltip（如「取消数据同步」）必须有 Overlay 祖先。
///
/// [pinnedIsland] 为 false 时只挂悬浮渠道（图片查看器独立窗口没有云同步 / 生成
/// 相关的 Provider，故不需要驻场岛）。
class AppNoticeOverlay extends StatelessWidget {
  const AppNoticeOverlay({
    super.key,
    required this.child,
    this.onOpenBook,
    this.pinnedIsland = true,
    this.center,
  });

  /// 应用内容（通常是 `MaterialApp.builder` 的 child）。
  final Widget child;

  /// 驻场岛展开区里点击「正在生成的书」时的跳转回调。
  final void Function(String bookUuid)? onOpenBook;

  /// 是否挂驻场岛（独立窗口 / 无需云同步与生成状态的场景传 false）。
  final bool pinnedIsland;

  /// 注入既有通知中心（测试用）；为 null 时由本组件创建并持有。
  final AppNoticeCenter? center;

  @override
  Widget build(BuildContext context) {
    final openBook = onOpenBook;
    final injected = center;
    // 通知宿主放进独立 Overlay：Overlay 自身不参与命中测试，空白区域
    // 的指针事件照常落到 child（页面）上。
    final stack = Stack(
      fit: StackFit.expand,
      children: [
        child,
        Overlay(
          initialEntries: [
            OverlayEntry(builder: (_) => const FloatingNoticeHost()),
            if (pinnedIsland && openBook != null)
              OverlayEntry(
                builder: (_) => PinnedNoticeIsland(onOpenBook: openBook),
              ),
          ],
        ),
      ],
    );
    if (injected != null) {
      return ChangeNotifierProvider<AppNoticeCenter>.value(
        value: injected,
        child: stack,
      );
    }
    return ChangeNotifierProvider<AppNoticeCenter>(
      create: (_) => AppNoticeCenter(),
      child: stack,
    );
  }
}

/// 应用内通知的统一调用入口（取代 `ScaffoldMessenger.of(context)`）。
///
/// 用法：`context.notices.info('已复制')` / `context.notices.error('保存失败：$e')`。
/// 跨 `await` 时请先取出：`final notices = context.notices;`，随后无需再查
/// Scaffold/Context 生命周期（中心挂着应用作用域）。
extension AppNoticeContext on BuildContext {
  AppNoticeCenter get notices => read<AppNoticeCenter>();
}
