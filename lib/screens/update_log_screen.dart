import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import '../widgets/app_empty_hint.dart';
import '../widgets/markdown_preview.dart';

/// 「更新日志」页：解析根目录 `update_log.md`（已通过 `pubspec.yaml` 声明为
/// asset）并渲染，开发者维护该文件即可更新页面内容。
class UpdateLogScreen extends StatefulWidget {
  const UpdateLogScreen({super.key});

  /// 打开更新日志页（全窗口）。
  static Future<void> open(BuildContext context) {
    return Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const UpdateLogScreen()));
  }

  @override
  State<UpdateLogScreen> createState() => _UpdateLogScreenState();
}

class _UpdateLogScreenState extends State<UpdateLogScreen> {
  late final Future<String> _contentFuture;

  @override
  void initState() {
    super.initState();
    _contentFuture = rootBundle.loadString('update_log.md');
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    return Scaffold(
      backgroundColor: colors.background,
      appBar: AppBar(title: const Text('更新日志')),
      body: FutureBuilder<String>(
        future: _contentFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: AppEmptyHint(
                  icon: Icons.error_outline,
                  text: '更新日志加载失败：${snapshot.error}',
                ),
              ),
            );
          }
          final content = snapshot.data ?? '';
          if (content.trim().isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: AppEmptyHint(
                  icon: Icons.article_outlined,
                  text: '暂无更新日志',
                ),
              ),
            );
          }
          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 860),
                child: MarkdownPreview(
                  data: content,
                  base: const TextStyle(fontSize: 13, height: 1.6),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
