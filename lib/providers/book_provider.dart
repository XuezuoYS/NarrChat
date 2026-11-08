import 'package:flutter/foundation.dart';

import '../models/book.dart';
import '../repositories/book_repository.dart';
import '../services/app_repositories.dart';
import 'cloud_sync_provider.dart';

/// 书籍状态管理：书籍列表、当前选中书籍、增删改。
class BookProvider extends ChangeNotifier {
  BookProvider({
    BookRepository? repository,
    CloudSyncProvider? cloudSyncProvider,
  }) : _repo = repository ?? AppRepositories.instance.books,
       // ignore: prefer_initializing_formals
       _cloudSyncProvider = cloudSyncProvider;

  final BookRepository _repo;

  /// 云同步 Provider：书籍创建 / 设置保存后触发全自动同步（null = 未接入，如测试）。
  final CloudSyncProvider? _cloudSyncProvider;

  List<Book> _books = [];
  Book? _currentBook;
  bool _isLoading = false;
  String? _error;

  /// 每本书最近一次内容变更时间（首页「更新时间」排序 / 列表时间展示用）。
  ///
  /// 键为书籍 uuid；值来自 `book_meta.updated_at` 的缓存副本，读取时会按书库
  /// 文件 mtime 自动校正（见 `BookRepository.updatedTimes`）。
  Map<String, DateTime> _updatedTimes = {};

  List<Book> get books => List.unmodifiable(_books);
  Book? get currentBook => _currentBook;
  bool get isLoading => _isLoading;
  String? get error => _error;
  Map<String, DateTime> get updatedTimes => Map.unmodifiable(_updatedTimes);

  /// 加载书籍列表；若当前书籍已被删除则自动重置，无选中时默认选第一本。
  ///
  /// 重新加载后会用**最新实例**替换当前选中项（同一 uuid）——云同步拉取落地后
  /// 调用本方法即让 currentBook 携带最新设置字段；否则保留旧实例会让
  /// 对话页 / 书籍设置页持续展示陈旧数据。
  Future<void> loadBooks() async {
    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
      _books = await _repo.listBooks();
      _updatedTimes = await _repo.updatedTimes();
      _currentBook = _refreshCurrent(_currentBook);
      if (_currentBook == null && _books.isNotEmpty) {
        _currentBook = _books.first;
      }
    } catch (e) {
      _error = e.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 返回与 [book] 同 uuid 的最新实例；[book] 已不在最新列表中（如被删除）返回 null。
  Book? _refreshCurrent(Book? book) {
    final uuid = book?.uuid ?? '';
    if (uuid.isEmpty) return null;
    for (final b in _books) {
      if (b.uuid == uuid) return b;
    }
    return null;
  }

  /// 刷新「更新时间」映射（从对话页返回首页时调用）。
  ///
  /// 仓库读取会顺带校正书库 mtime 变过的缓存行，因此排序能读到最新
  /// `book_meta.updated_at`；失败时保留旧数据，不影响列表展示。
  Future<void> refreshTimes() async {
    try {
      _updatedTimes = await _repo.updatedTimes();
      notifyListeners();
    } catch (e) {
      // 失败时保留旧数据，不影响列表展示。
    }
  }

  /// 新建书籍，成功后自动选中。
  Future<bool> createBook(Book book) async {
    try {
      final uuid = await _repo.createBook(book);
      await loadBooks();
      _currentBook = _books.firstWhere(
        (b) => b.uuid == uuid,
        orElse: () => _books.isNotEmpty ? _books.first : book,
      );
      notifyListeners();
      _cloudSyncProvider?.triggerSync();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  /// 更新书籍。
  Future<bool> updateBook(Book book) async {
    try {
      await _repo.saveBook(book);
      await loadBooks();
      // 保持选中同一本书（以最新列表中的实例为准）。
      _currentBook = _refreshCurrent(book) ?? book;
      notifyListeners();
      _cloudSyncProvider?.triggerSync();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  /// 删除书籍：写墓碑（带删除时轮号）并清掉本机数据；云端只保留最新一代，
  /// 由同步层整理，之后可在云同步的「书籍回收站」还原或彻底删除。
  ///
  /// 「仅保留 library 墓碑」：书库文件 / 缓存行 / 图片引用都会删掉；
  /// 云端书单元由 [CloudSyncProvider.handleBookDeleted] 立即或随后整理。
  Future<bool> deleteBook(Book book) async {
    try {
      await _repo.deleteBook(book.uuid);
      if (_currentBook?.uuid == book.uuid) {
        _currentBook = null;
      }
      await loadBooks();
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
    // 云端清理是后续动作：本地已经删成功，云端失败不能反过来算删除失败。
    try {
      _cloudSyncProvider?.handleBookDeleted(book.uuid);
    } catch (_) {
      // 墓碑还在，下次同步兜底。
    }
    return true;
  }

  /// 切换当前书籍。
  ///
  /// 统一以 [books] 中的**最新实例**为准（同 uuid 重复选中同样生效）：
  /// 云同步落地后即使传入的是旧快照，选中后 currentBook 也立即携带最新字段。
  void selectBook(Book book) {
    final fresh = _refreshCurrent(book) ?? book;
    if (identical(_currentBook, fresh)) return;
    _currentBook = fresh;
    notifyListeners();
  }

  /// 图片是否仍被某本书引用（封面 / 轮次附图）。
  ///
  /// 封面被清掉或换掉后，用它决定能否回收旧图；查询失败会抛出，
  /// 调用方按「不删」处理（宁可留一张孤儿图，也不误删别处在用的图）。
  Future<bool> isImageReferenced(String relPath) =>
      _repo.isImageReferenced(relPath);
}
