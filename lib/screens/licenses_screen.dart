import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import '../utils/license_meta.dart';
import '../widgets/app_empty_hint.dart';

/// 单个包的可展示许可证数据。
class _PackageLicense {
  final String package;
  final String text;

  /// 次级标题：许可证名称 · 作者（提取失败时为空字符串）。
  final String subtitle;

  const _PackageLicense({
    required this.package,
    required this.text,
    this.subtitle = '',
  });
}

/// 「开放源代码许可」页：展示本项目使用的全部开放源代码库许可证。
///
/// - 自动收集：Flutter 构建时把各依赖（含传递依赖）的 LICENSE 合并进 NOTICES，
///   运行时经 [LicenseRegistry] 读取，随依赖增减自动更新；
/// - 手动补充：`assets/manual_licenses.json` 中的条目由 `ManualLicensesService`
///   注册进同一 [LicenseRegistry]，与本页自动条目合并展示。
class LicensesScreen extends StatefulWidget {
  const LicensesScreen({super.key});

  /// 打开许可证页（全窗口）。
  static Future<void> open(BuildContext context) {
    return Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const LicensesScreen()));
  }

  @override
  State<LicensesScreen> createState() => _LicensesScreenState();
}

class _LicensesScreenState extends State<LicensesScreen> {
  late final Future<List<_PackageLicense>> _licensesFuture;

  @override
  void initState() {
    super.initState();
    _licensesFuture = _collectLicenses();
  }

  /// 收集并聚合 [LicenseRegistry] 中的全部许可证：按包名分组合并段落、
  /// 忽略大小写排序。
  static Future<List<_PackageLicense>> _collectLicenses() async {
    final entries = await LicenseRegistry.licenses.fold<List<LicenseEntry>>(
      <LicenseEntry>[],
      (acc, entry) => acc..add(entry),
    );
    final byPackage = <String, List<String>>{};
    for (final entry in entries) {
      final text = entry.paragraphs.map((p) => p.text).join('\n\n');
      for (final package in entry.packages) {
        byPackage.putIfAbsent(package, () => <String>[]).add(text);
      }
    }
    final list = byPackage.entries
        .map((e) {
          final text = e.value.join('\n\n');
          return _PackageLicense(
            package: e.key,
            text: text,
            subtitle: licenseSubtitle(text),
          );
        })
        .toList()
      ..sort(
        (a, b) => a.package.toLowerCase().compareTo(b.package.toLowerCase()),
      );
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    return Scaffold(
      backgroundColor: colors.background,
      appBar: AppBar(title: const Text('开放源代码许可')),
      body: FutureBuilder<List<_PackageLicense>>(
        future: _licensesFuture,
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
                  text: '许可证加载失败：${snapshot.error}',
                ),
              ),
            );
          }
          final licenses = snapshot.data ?? const <_PackageLicense>[];
          if (licenses.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: AppEmptyHint(
                  icon: Icons.description_outlined,
                  text: '暂未发现开放源代码许可证',
                ),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: licenses.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) =>
                _LicenseCard(license: licenses[index]),
          );
        },
      ),
    );
  }
}

/// 单个包的许可证卡片：显示包名 + 次级标题（最长两行，超出省略），
/// 点击打开许可证详情对话框。
class _LicenseCard extends StatelessWidget {
  final _PackageLicense license;

  const _LicenseCard({required this.license});

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.divider),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _showLicenseDialog(context, license),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        license.package,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: colors.textPrimary,
                        ),
                      ),
                      if (license.subtitle.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          license.subtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.textSecondary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right,
                  size: 20,
                  color: colors.textSecondary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 打开单个许可证详情对话框（标题 + 完整可复制的许可证全文）。
Future<void> _showLicenseDialog(
  BuildContext context,
  _PackageLicense license,
) {
  return showDialog<void>(
    context: context,
    builder: (_) => _LicenseDialog(license: license),
  );
}

/// 单个许可证详情对话框。
class _LicenseDialog extends StatelessWidget {
  final _PackageLicense license;

  const _LicenseDialog({required this.license});

  @override
  Widget build(BuildContext context) {
    final colors = context.narrColors;
    return Dialog(
      insetPadding: const EdgeInsets.all(20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 600),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 标题：包名 + 次级标题。
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          license.package,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: colors.textPrimary,
                          ),
                        ),
                        if (license.subtitle.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            license.subtitle,
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.textSecondary,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            // 正文：完整可复制的许可证全文（可滚动）。
            Flexible(
              child: Container(
                margin: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: colors.background,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: colors.divider),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    license.text,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.6,
                      color: colors.textPrimary,
                    ),
                  ),
                ),
              ),
            ),
            // 底部操作：复制全文 / 关闭。
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () async {
                      await Clipboard.setData(
                        ClipboardData(text: license.text),
                      );
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('已复制许可证全文')),
                      );
                    },
                    child: const Text('复制全文'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('关闭'),
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
