import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../providers/cloud_sync_provider.dart';
import '../services/sync/sync_models.dart';
import '../utils/focus_utils.dart';

/// 「保留历史版本」设置弹窗：打开时拉取云端真值 → 编辑 → 保存到云端。
///
/// 校验错误（非整数 / 越界）内联红字、**不打网络**；网络失败弹窗保持打开
/// 并**原样输出异常文本**（可直接重试）。返回保存成功的份数；null = 取消 /
/// 未保存（含保存失败）。
Future<int?> showKeepVersionsDialog(
  BuildContext context, {
  required CloudSyncProvider provider,
}) {
  return showDialog<int>(
    context: context,
    builder: (_) => _KeepVersionsDialog(provider: provider),
  );
}

class _KeepVersionsDialog extends StatefulWidget {
  final CloudSyncProvider provider;

  const _KeepVersionsDialog({required this.provider});

  @override
  State<_KeepVersionsDialog> createState() => _KeepVersionsDialogState();
}

class _KeepVersionsDialogState extends State<_KeepVersionsDialog> {
  late final TextEditingController _controller;

  /// 打开时正在拉取云端真值。
  bool _loading = true;

  /// 保存请求进行中（按钮禁用 + 转圈）。
  bool _saving = false;

  /// 输入校验错误（内联红字，不关窗）。
  String? _validateError;

  /// 云端读取 / 保存失败的原生异常文本（内联可选中，弹窗保持打开）。
  String? _remoteError;

  CloudSyncProvider get _provider => widget.provider;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: '${_provider.keepVersions}');
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 打开即强制 GET 云端真值（覆盖缓存与预填，避免其它设备改过导致旧值）。
  Future<void> _load() async {
    final error = await _provider.refreshKeepVersions();
    if (!mounted) return;
    if (error == null) {
      _controller.text = '${_provider.keepVersions}';
      _controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _controller.text.length,
      );
    } else {
      // 读取失败（如断网）：保留缓存值预填，仍可编辑后尝试保存。
      _remoteError = '读取云端配置失败：$error';
    }
    setState(() => _loading = false);
  }

  Future<void> _save() async {
    final parsed = int.tryParse(_controller.text.trim());
    final validateError = SyncConfig.validateKeepVersions(parsed);
    if (validateError != null) {
      setState(() {
        _validateError = validateError;
        _remoteError = null;
      });
      return;
    }
    setState(() {
      _saving = true;
      _validateError = null;
      _remoteError = null;
    });
    final saveError = await _provider.saveKeepVersions(parsed!);
    if (!mounted) return;
    if (saveError == null) {
      Navigator.of(context).pop(parsed);
      return;
    }
    // 保存失败：弹窗保持打开，原样展示异常文本供重试。
    setState(() {
      _saving = false;
      _remoteError = saveError;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('保留历史版本'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _controller,
              enabled: !_saving && !_loading,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              maxLength: 3,
              autofocus: true,
              onTapOutside: unfocusOnTapOutside,
              onChanged: (_) => setState(() => _validateError = null),
              onSubmitted: (_) => _save(),
              decoration: InputDecoration(
                labelText: '份数',
                counterText: '',
                helperText:
                    '范围 ${SyncConfig.minKeepVersions} ~ '
                    '${SyncConfig.maxKeepVersions}，保存在云端（sync_config.json），'
                    '下次同步推送时按此值修剪。',
                errorText: _validateError,
              ),
            ),
            if (_loading) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '正在读取云端配置…',
                    style: TextStyle(
                      fontSize: 12,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ],
            if (_remoteError != null) ...[
              const SizedBox(height: 12),
              SelectableText(
                _remoteError!,
                style: TextStyle(fontSize: 12, color: colors.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: (_loading || _saving) ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('保存'),
        ),
      ],
    );
  }
}
