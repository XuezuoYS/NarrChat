import 'package:flutter/foundation.dart';

import '../database/book_dao.dart';
import '../models/book.dart';
import 'cloud_sync_provider.dart';

/// 书籍状态管理：书籍列表、当前选中书籍、增删改。
class BookProvider extends ChangeNotifier {
  BookProvider({BookDao? dao, CloudSyncProvider? cloudSyncProvider})
      : _dao = dao ?? BookDao(),
        // ignore: prefer_initializing_formals
        _cloudSyncProvider = cloudSyncProvider;

  final BookDao _dao;

  /// 云同步 Provider：书籍创建 / 设置保存后触发全自动同步（null = 未接入，如测试）。
  final CloudSyncProvider? _cloudSyncProvider;

  List<Book> _books = [];
  Book? _currentBook;
  bool _isLoading = false;
  String? _error;

  /// 每本书最近一轮对话的创建时间（首页「时间排序」用，无轮次的书不包含在内）。
  Map<int, DateTime> _lastRoundTimes = {};

  List<Book> get books => List.unmodifiable(_books);
  Book? get currentBook => _currentBook;
  bool get isLoading => _isLoading;
  String? get error => _error;
  Map<int, DateTime> get lastRoundTimes => Map.unmodifiable(_lastRoundTimes);

  /// 加载书籍列表；若当前书籍已被删除则自动重置，无选中时默认选第一本。
  Future<void> loadBooks() async {
    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
      _books = await _dao.getAllBooks();
      _lastRoundTimes = await _dao.getLastRoundTimes();
      if (_currentBook != null && !_books.any((b) => b.id == _currentBook!.id)) {
        _currentBook = null;
      }
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

  /// 刷新「最近对话时间」映射（从对话页返回首页时调用）。
  Future<void> refreshLastRoundTimes() async {
    try {
      _lastRoundTimes = await _dao.getLastRoundTimes();
      notifyListeners();
    } catch (e) {
      // 失败时保留旧数据，不影响列表展示。
    }
  }

  /// 新建书籍，成功后自动选中。
  Future<bool> createBook(Book book) async {
    try {
      final id = await _dao.insertBook(book);
      await loadBooks();
      _currentBook = _books.firstWhere(
        (b) => b.id == id,
        orElse: () => _books.isNotEmpty ? _books.first : book,
      );
      notifyListeners();
      _cloudSyncProvider?.triggerAutoSync();
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
      await _dao.updateBook(book);
      await loadBooks();
      // 保持选中同一本书。
      _currentBook = _books.firstWhere(
        (b) => b.id == book.id,
        orElse: () => book,
      );
      notifyListeners();
      _cloudSyncProvider?.triggerAutoSync();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  /// 删除书籍（软删：打下跌碑并隐藏，行暂留用于云同步删除传播）。
  Future<bool> deleteBook(Book book) async {
    try {
      await _dao.softDeleteBook(book.id!);
      if (_currentBook?.id == book.id) {
        _currentBook = null;
      }
      await loadBooks();
      notifyListeners();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  void selectBook(Book book) {
    if (_currentBook?.id == book.id) return;
    _currentBook = book;
    notifyListeners();
  }
}
