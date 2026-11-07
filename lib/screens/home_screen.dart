import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import '../widgets/brand_logo.dart';
import '../widgets/island_bar.dart';
import '../widgets/narr_chat_app_bar.dart';
import 'book_list_screen.dart';
import 'home_navigation.dart';
import 'settings_screen.dart';

/// 宽屏断点：与 Chat 页主布局一致，可用宽度 ≥ 此值时显示左侧品牌栏。
const double kHomeWideBreakpoint = 900;

/// 左侧品牌栏宽度（与设置页左侧导航栏同宽）。
const double kHomeRailWidth = 220;

/// 左侧品牌栏的 Key（宽窄屏测试用）。
const Key kHomeRailKey = Key('home_rail');

/// 主界面（根路由）：书籍列表首页。
///
/// - 宽屏：左侧品牌栏 + 右侧列表内容；
/// - 窄屏：品牌进入顶栏，内容占满；
/// - 顶栏右侧统一「新建书籍（加号）+ 设置」，顶栏无底边、与内容同色；
/// - 系统返回键统一拦截：二次确认后退出应用。
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  /// 系统返回键统一处理（安卓端）：弹二次确认，确认后退出应用。
  Future<void> _handleSystemBack() async {
    final exit = await _confirmExit();
    if (exit && mounted) {
      // 根路由被 PopScope 拦截（canPop=false），需绕过 Navigator 直接退出。
      SystemNavigator.pop();
    }
  }

  /// 退出应用二次确认对话框。
  Future<bool> _confirmExit() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出 NarrChat'),
        content: const Text('确定要退出 NarrChat 吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= kHomeWideBreakpoint;
        return PopScope(
          // 根路由统一拦截系统返回键：二次确认退出。
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            _handleSystemBack();
          },
          // 统一顶栏：宽屏只留右侧加号 + 设置（品牌在左侧栏）；
          // 窄屏品牌进顶栏。顶栏无边框，和内容同色，视觉上一体。
          child: IslandAwareScaffold(
            backgroundColor: colors.surface,
            appBarBuilder: (context, extraRow) => NarrChatAppBar(
              extraRowHeight: extraRow,
              showBorder: false,
              titleWidget: wide
                  ? const SizedBox.shrink()
                  : const BrandLogo(size: 28, title: 'NarrChat'),
              actions: [
                IconButton.filled(
                  icon: const Icon(Icons.add_rounded, size: 20),
                  tooltip: '新建书籍',
                  onPressed: () => createHomeBook(context),
                ),
                IconButton(
                  icon: const Icon(Icons.settings_outlined),
                  tooltip: '设置',
                  onPressed: () => SettingsScreen.open(context),
                ),
                const SizedBox(width: 8),
              ],
            ),
            body: wide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const _HomeBrandRail(),
                      Expanded(child: BookListScreen(wide: true)),
                    ],
                  )
                : const BookListScreen(),
          ),
        );
      },
    );
  }
}

/// 宽屏左侧品牌栏：垂直排列 Logo 与品牌名。
///
/// 顶栏仍保持全宽（通知岛需要顶栏槽位），左栏因此从顶栏下方开始；
/// 顶栏与内容同色、无边框，视觉上仍是一体。
class _HomeBrandRail extends StatelessWidget {
  const _HomeBrandRail();

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    return Container(
      key: kHomeRailKey,
      width: kHomeRailWidth,
      color: colors.background,
      padding: const EdgeInsets.fromLTRB(22, 24, 22, 20),
      child: const Align(
        alignment: Alignment.topLeft,
        child: BrandLogo(
          size: 44,
          title: 'NarrChat',
          titleSize: 20,
          axis: BrandLogoAxis.vertical,
        ),
      ),
    );
  }
}
