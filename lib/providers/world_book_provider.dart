import 'package:flutter/foundation.dart';

import '../models/world_book_entry.dart';
import '../repositories/world_book_repository.dart';
import '../services/app_repositories.dart';
import 'cloud_sync_provider.dart';

/// 世界书状态管理：加载当前书籍的世界书条目。
///
/// 世界书属「书籍设置部件」：设置页里的增删改都先留在页面草稿，
/// 点「保存」时由 [saveEntries] 一次整体提交（一个事务、一次同步触发），
/// 组件本身不再逐条写库。
class WorldBookProvider extends ChangeNotifier {
  WorldBookProvider({
    WorldBookRepository? repository,
    CloudSyncProvider? cloudSyncProvider,
  })  : _repo = repository ?? AppRepositories.instance.worldBook,
        // ignore: prefer_initializing_formals
        _cloudSyncProvider = cloudSyncProvider;

  final WorldBookRepository _repo;

  /// 云同步 Provider：世界书保存后触发全自动同步（null = 未接入，如测试）。
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
    // 只有本次读取失败才算失败：调用方（书籍设置页）靠它区分“空书”与“读不出来”。
    _error = null;
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

  /// 用 [entries] 整体替换某本书的世界书（保存书籍设置时调用）。
  ///
  /// - 新条目（uuid 为空）由仓储补 uuid；
  /// - 只做一次事务写入，`book_meta.updated_at` 只刷新一次；
  /// - [triggerSync] 为 false 时由调用方在全部设置写完后统一触发一次同步。
  Future<bool> saveEntries(
    String bookUuid,
    List<WorldBookEntry> entries, {
    bool triggerSync = true,
  }) async {
    if (bookUuid.isEmpty) return false;
    _error = null;
    try {
      await _repo.replaceAll(bookUuid, entries);
      await loadEntries(bookUuid);
      if (triggerSync) _cloudSyncProvider?.triggerSync();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }
}
