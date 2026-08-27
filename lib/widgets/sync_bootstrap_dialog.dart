import 'package:flutter/material.dart';

import '../services/sync/sync_bootstrapper.dart';
import '../theme/app_theme.dart';

/// 首次连接云同步的本地 / 云端数据摘要（供决策页展示差异）。
class SyncBootstrapSummary {
  final int localBooks;
  final int localMods;
  final int cloudBooks;
  final int cloudMods;

  const SyncBootstrapSummary({
    this.localBooks = 0,
    this.localMods = 0,
    this.cloudBooks = 0,
    this.cloudMods = 0,
  });

  String get localText => '$localBooks 本 · $localMods 个 Mod';
  String get cloudText => '$cloudBooks 本 · $cloudMods 个 Mod';
}

/// 打开首次连接分支对话框。
///
/// 仅在"首次连接（本设备从未同步）且本地与云端**都**有数据"时调用
/// （由 [SyncBootstrapper.decide] 判定为 `mergeBoth`）。对话框默认选中「导入云端
/// 并合并本地」；另两个「用云端覆盖本地 / 用本地覆盖云端」为覆盖类，选中后需二次确认。
/// 返回用户选择的 [SyncBootstrapDecision]；取消返回 null。
Future<SyncBootstrapDecision?> showSyncBootstrapDialog(
  BuildContext context, {
  required SyncBootstrapSummary summary,
}) {
  return showDialog<SyncBootstrapDecision>(
    context: context,
    builder: (ctx) => _SyncBootstrapDialog(summary: summary),
  );
}

class _SyncBootstrapDialog extends StatefulWidget {
  final SyncBootstrapSummary summary;

  const _SyncBootstrapDialog({required this.summary});

  @override
  State<_SyncBootstrapDialog> createState() => _SyncBootstrapDialogState();
}

class _SyncBootstrapDialogState extends State<_SyncBootstrapDialog> {
  SyncBootstrapDecision _selected = SyncBootstrapDecision.mergeBoth;

  void _confirm() async {
    if (_selected == SyncBootstrapDecision.mergeBoth) {
      Navigator.of(context).pop(_selected);
      return;
    }
    // 覆盖类：二次确认（提示覆盖一侧会丢失未同步修改）。
    final ok = await _confirmOverride(_selected);
    if (ok && mounted) Navigator.of(context).pop(_selected);
  }

  Future<bool> _confirmOverride(SyncBootstrapDecision decision) async {
    final isLocalOverride = decision == SyncBootstrapDecision.initCloud;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isLocalOverride ? '用本地覆盖云端' : '用云端覆盖本地'),
        content: Text(
          isLocalOverride
              ? '将用本地数据覆盖当前云端备份（云端 ${widget.summary.cloudText}）。'
                  '云端未同步的改动将丢失，确定继续吗？'
              : '将用云端数据覆盖本地（本地 ${widget.summary.localText}）。'
                  '本地未同步的修改将丢失，确定继续吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: const Text('继续'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('首次连接云同步'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '本地与云端都检测到数据，请选择如何处理。',
                style: TextStyle(fontSize: 13, color: context.narrColors.textSecondary),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(child: _sideChip('本地', widget.summary.localText, scheme)),
                  const SizedBox(width: 8),
                  Expanded(child: _sideChip('云端', widget.summary.cloudText, scheme)),
                ],
              ),
              const SizedBox(height: 8),
              _option(SyncBootstrapDecision.mergeBoth, scheme,
                  leading: '导入云端并合并本地',
                  subtitle: '逐书/逐 Mod 合并，仅真冲突需人工确认'),
              _option(SyncBootstrapDecision.pullCloud, scheme,
                  leading: '用云端覆盖本地',
                  subtitle: '本地 ${widget.summary.localText} 将被替换'),
              _option(SyncBootstrapDecision.initCloud, scheme,
                  leading: '用本地覆盖云端',
                  subtitle: '云端 ${widget.summary.cloudText} 将被替换'),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _confirm,
          child: const Text('确定'),
        ),
      ],
    );
  }

  Widget _sideChip(String label, String value, ColorScheme scheme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
          const SizedBox(height: 2),
          Text(value, style: TextStyle(fontSize: 12.5, color: context.narrColors.textPrimary)),
        ],
      ),
    );
  }

  Widget _option(
    SyncBootstrapDecision decision,
    ColorScheme scheme, {
    required String leading,
    required String subtitle,
  }) {
    final selected = _selected == decision;
    final color = selected ? scheme.primary : scheme.onSurfaceVariant;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => setState(() => _selected = decision),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              size: 20,
              color: color,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(leading,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  Text(subtitle,
                      style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
