import 'package:flutter/material.dart';

/// GitHub 徽章：深色胶囊 + 官方 Octocat 标记 +「GitHub」字标。
///
/// 用于设置页「关于」的 GitHub 入口（行左侧），纯展示：点击由外层整行
/// 处理，避免徽章自己成为第二个点击热区。
class GitHubBadge extends StatelessWidget {
  /// 官方 GitHub 标志（primer/octicons `mark-github` 白色版）。
  static const String markAsset = 'assets/github_mark.png';

  /// 胶囊底色：GitHub 品牌深色，浅色 / 深色主题下都保持白标对比度。
  static const Color background = Color(0xFF24292F);

  /// 胶囊高度（默认 26）。
  final double height;

  const GitHubBadge({super.key, this.height = 26});

  @override
  Widget build(BuildContext context) {
    final markSize = height * 0.56;
    return Container(
      height: height,
      padding: EdgeInsets.only(
        left: height * 0.36,
        right: height * 0.46,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(height / 2),
        // 深色主题下与卡片背景过于接近，加一层极淡描边勾出胶囊轮廓。
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Image.asset(
            markAsset,
            width: markSize,
            height: markSize,
            filterQuality: FilterQuality.medium,
            // 徽章属于装饰，读屏时读外层行的标题即可。
            excludeFromSemantics: true,
          ),
          SizedBox(width: height * 0.2),
          Text(
            'GitHub',
            style: TextStyle(
              fontSize: height * 0.46,
              height: 1,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}
