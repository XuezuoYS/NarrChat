import 'package:flutter/foundation.dart';

import '../database/world_book_dao.dart';
import '../models/world_book_entry.dart';
import 'cloud_sync_provider.dart';

/// 世界书状态管理：加载/新增/更新/删除当前书籍的世界书条目。
///
/// 世界书属「书籍设置部件」，修改后同样触发全自动同步。
class WorldBookProvider extends ChangeNotifier {
  WorldBookProvider({WorldBookDao? dao, CloudSyncProvider? cloudSyncProvider})
      : _dao = dao ?? WorldBookDao(),
        // ignore: prefer_initializing_formals
        _cloudSyncProvider = cloudSyncProvider;

  final WorldBookDao _dao;

  /// 云同步 Provider：世界书修改后触发全自动同步（null = 未接入，如测试）。
  final CloudSyncProvider? _cloudSyncProvider;

  List<WorldBookEntry> _entries = [];
  String _bookUuid = '';
  String? _error;

  List<WorldBookEntry> get entries => List.unmodifiable(_entries);

  /// 当前启用中的条目（供扫描器使用）。
  List<WorldBookEntry> get activeEntries =>
      _entries.where((e) => e.isActive).toList();

  String? get error => _error;

  Future<void> loadEntries(String bookUuid) async {
    _bookUuid = bookUuid;
    try {
      _entries = await _dao.getEntriesByBook(bookUuid);
    } catch (e) {
      _error = e.toString();
    }
    notifyListeners();
  }

  /// 重新加载当前书籍的世界书条目（云同步恢复数据后调用）。
  Future<void> reloadCurrent() async {
    if (_bookUuid.isEmpty) return;
    await loadEntries(_bookUuid);
  }

  Future<bool> addEntry({
    required String keyword,
    required String content,
    bool isActive = true,
  }) async {
    final bookUuid = _bookUuid;
    if (bookUuid.isEmpty) return false;
    try {
      await _dao.insertEntry(
        WorldBookEntry(
          bookUuid: bookUuid,
          keyword: keyword.trim(),
          content: content,
          isActive: isActive,
          createdAt: DateTime.now(),
        ),
      );
      await loadEntries(bookUuid);
      _cloudSyncProvider?.triggerSync();
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
      await loadEntries(_bookUuid);
      _cloudSyncProvider?.triggerSync();
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
      await loadEntries(_bookUuid);
      _cloudSyncProvider?.triggerSync();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }
}
