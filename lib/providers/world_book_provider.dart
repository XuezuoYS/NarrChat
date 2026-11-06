import 'package:flutter/foundation.dart';

import '../models/world_book_entry.dart';
import '../repositories/world_book_repository.dart';
import '../services/app_repositories.dart';
import 'cloud_sync_provider.dart';

/// 世界书状态管理：加载/新增/更新/删除当前书籍的世界书条目。
///
/// 世界书属「书籍设置部件」，修改后同样触发全自动同步。
class WorldBookProvider extends ChangeNotifier {
  WorldBookProvider({
    WorldBookRepository? repository,
    CloudSyncProvider? cloudSyncProvider,
  })  : _repo = repository ?? AppRepositories.instance.worldBook,
        // ignore: prefer_initializing_formals
        _cloudSyncProvider = cloudSyncProvider;

  final WorldBookRepository _repo;

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
      _entries = await _repo.list(bookUuid);
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
      await _repo.upsert(
        bookUuid,
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
    final bookUuid = entry.bookUuid.isEmpty ? _bookUuid : entry.bookUuid;
    if (bookUuid.isEmpty) return false;
    try {
      await _repo.upsert(bookUuid, entry);
      await loadEntries(_bookUuid);
      _cloudSyncProvider?.triggerSync();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  /// 删除一条：身份是 uuid（不再是 R2 的本地自增 id）。
  Future<bool> removeEntry(String uuid) async {
    if (uuid.isEmpty) return false;
    try {
      await _repo.delete(_bookUuid, uuid);
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
