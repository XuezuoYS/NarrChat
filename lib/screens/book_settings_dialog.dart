import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/book.dart';
import '../models/role_category.dart';
import '../providers/book_provider.dart';
import '../utils/constants.dart';
import '../widgets/draggable_role_list.dart';
import '../widgets/history_round_stepper.dart';

/// 书籍设置对话框（新建 / 编辑书籍）。
///
/// 包含：标题、类别、基础设定、文笔参考、全局前置/后置词、历史轮次数（步进器）、
/// 角色类别列表（可拖拽排序、可增删、可为每类设定详细描述格式）。
class BookSettingsDialog extends StatefulWidget {
  final Book? book;

  const BookSettingsDialog({super.key, this.book});

  static Future<bool?> show(BuildContext context, {Book? book}) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => BookSettingsDialog(book: book),
    );
  }

  @override
  State<BookSettingsDialog> createState() => _BookSettingsDialogState();
}

class _BookSettingsDialogState extends State<BookSettingsDialog> {
  late final TextEditingController _title;
  late final TextEditingController _category;
  late final TextEditingController _baseSetting;
  late final TextEditingController _writingStyle;
  late final TextEditingController _globalPrePrompt;
  late final TextEditingController _globalPostPrompt;
  late int _historyRounds;
  late List<RoleCategory> _roleCategories;

  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    final b = widget.book;
    _title = TextEditingController(text: b?.title ?? '');
    _category = TextEditingController(text: b?.category ?? '');
    _baseSetting = TextEditingController(text: b?.baseSetting ?? '');
    _writingStyle = TextEditingController(text: b?.writingStyle ?? '');
    _globalPrePrompt = TextEditingController(text: b?.globalPrePrompt ?? '');
    _globalPostPrompt = TextEditingController(text: b?.globalPostPrompt ?? '');
    _historyRounds = (b?.historyRounds ?? 1) < 1 ? 1 : (b?.historyRounds ?? 1);
    _roleCategories = List.of(
      b?.roleCategories ?? Constants.defaultRoleCategories,
    );
  }

  @override
  void dispose() {
    _title.dispose();
    _category.dispose();
    _baseSetting.dispose();
    _writingStyle.dispose();
    _globalPrePrompt.dispose();
    _globalPostPrompt.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('书籍标题不能为空')),
      );
      return;
    }
    setState(() => _isSaving = true);
    final book = Book(
      id: widget.book?.id,
      title: title,
      category: _category.text.trim(),
      baseSetting: _baseSetting.text,
      writingStyle: _writingStyle.text,
      globalPrePrompt: _globalPrePrompt.text,
      globalPostPrompt: _globalPostPrompt.text,
      historyRounds: _historyRounds,
      roleHierarchy:
          Constants.joinRoleHierarchy(_roleCategories.map((c) => c.name).toList()),
      roleCategories: List.of(_roleCategories),
    );

    final provider = context.read<BookProvider>();
    final ok = widget.book == null
        ? await provider.createBook(book)
        : await provider.updateBook(book);

    if (!mounted) return;
    setState(() => _isSaving = false);
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败：${provider.error ?? '未知错误'}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.book != null;
    return AlertDialog(
      title: Text(isEdit ? '编辑书籍' : '新建书籍'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _title,
                decoration: const InputDecoration(
                  labelText: '书籍标题 *',
                  hintText: '如：玄幻后宫',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _category,
                decoration: const InputDecoration(
                  labelText: '书籍总类别',
                  hintText: '如：玄幻后宫',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              _multiline(_baseSetting, '基础设定（不会变更）'),
              const SizedBox(height: 12),
              _multiline(_writingStyle, '文笔参考段落'),
              const SizedBox(height: 12),
              _multiline(_globalPrePrompt, '全局前置词'),
              const SizedBox(height: 12),
              _multiline(_globalPostPrompt, '全局后置词'),
              const SizedBox(height: 12),
              HistoryRoundStepper(
                value: _historyRounds,
                onChanged: (v) => setState(() => _historyRounds = v < 1 ? 1 : v),
              ),
              const SizedBox(height: 12),
              const Divider(),
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  '角色类别与描述格式',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                ),
              ),
              DraggableRoleList(
                initialCategories: _roleCategories,
                onChanged: (categories) => _roleCategories = List.of(categories),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _isSaving ? null : _save,
          child: Text(_isSaving ? '保存中…' : '保存'),
        ),
      ],
    );
  }

  Widget _multiline(TextEditingController controller, String label) {
    return TextField(
      controller: controller,
      maxLines: null,
      minLines: 3,
      keyboardType: TextInputType.multiline,
      style: const TextStyle(fontSize: 13, height: 1.4),
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );
  }
}

