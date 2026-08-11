import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import '../widgets/brand_logo.dart';
import 'book_list_screen.dart';
import 'settings_screen.dart';

/// 主界面（根路由）：书籍列表首页。
///
/// - 始终显示书籍列表（搜索 / 排序 / 新建 / 进入对话）；
/// - 点击书籍由 [BookListScreen] 推入对话页；
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
    return PopScope(
      // 根路由统一拦截系统返回键：二次确认退出。
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _handleSystemBack();
      },
      child: Scaffold(
        // 极简白色顶部：细底边 + 品牌 Logo（模仿 DeepSeek 顶部）。
        appBar: PreferredSize(
          preferredSize: const Size.fromHeight(kToolbarHeight),
          child: Container(
            decoration: BoxDecoration(
              color: context.narrColors.surface,
              border: Border(
                bottom: BorderSide(color: context.narrColors.divider),
              ),
            ),
            child: AppBar(
              title: const BrandLogo(title: 'NarrChat'),
              actions: [
                IconButton(
                  icon: const Icon(Icons.settings_outlined),
                  tooltip: '设置',
                  onPressed: () => SettingsScreen.open(context),
                ),
              ],
            ),
          ),
        ),
        body: const BookListScreen(),
      ),
    );
  }
}
