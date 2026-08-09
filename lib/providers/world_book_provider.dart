import 'package:flutter/foundation.dart';

import '../database/world_book_dao.dart';
import '../models/world_book_entry.dart';

/// 世界书状态管理：加载/新增/更新/删除当前书籍的世界书条目。
class WorldBookProvider extends ChangeNotifier {
  WorldBookProvider({WorldBookDao? dao}) : _dao = dao ?? WorldBookDao();

  final WorldBookDao _dao;

  List<WorldBookEntry> _entries = [];
  int? _bookId;
  String? _error;

  List<WorldBookEntry> get entries => List.unmodifiable(_entries);

  /// 当前启用中的条目（供扫描器使用）。
  List<WorldBookEntry> get activeEntries =>
      _entries.where((e) => e.isActive).toList();

  String? get error => _error;

  Future<void> loadEntries(int bookId) async {
    _bookId = bookId;
    try {
      _entries = await _dao.getEntriesByBook(bookId);
    } catch (e) {
      _error = e.toString();
    }
    notifyListeners();
  }

  /// 重新加载当前书籍的世界书条目（云同步恢复数据后调用）。
  Future<void> reloadCurrent() async {
    final id = _bookId;
    if (id == null) return;
    await loadEntries(id);
  }

  Future<bool> addEntry({
    required String keyword,
    required String content,
    bool isActive = true,
  }) async {
    final bookId = _bookId;
    if (bookId == null) return false;
    try {
      await _dao.insertEntry(
        WorldBookEntry(
          bookId: bookId,
          keyword: keyword.trim(),
          content: content,
          isActive: isActive,
          createdAt: DateTime.now(),
        ),
      );
      await loadEntries(bookId);
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  Future<bool> updateEntry(WorldBookEntry entry) async {
    try {
      await _dao.updateEntry(entry);
      if (_bookId != null) {
        await loadEntries(_bookId!);
      }
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  Future<bool> removeEntry(int id) async {
    try {
      await _dao.deleteEntry(id);
      if (_bookId != null) {
        await loadEntries(_bookId!);
      }
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }
}
