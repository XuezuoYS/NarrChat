import 'package:flutter/foundation.dart';

import '../database/book_dao.dart';
import '../models/book.dart';

/// 书籍状态管理：书籍列表、当前选中书籍、增删改。
class BookProvider extends ChangeNotifier {
  BookProvider({BookDao? dao}) : _dao = dao ?? BookDao();

  final BookDao _dao;

  List<Book> _books = [];
  Book? _currentBook;
  bool _isLoading = false;
  String? _error;

  List<Book> get books => List.unmodifiable(_books);
  Book? get currentBook => _currentBook;
  bool get isLoading => _isLoading;
  String? get error => _error;

  /// 加载书籍列表；若当前书籍已被删除则自动重置，无选中时默认选第一本。
  Future<void> loadBooks() async {
    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
      _books = await _dao.getAllBooks();
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
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  /// 删除书籍（连同其全部轮次）。
  Future<bool> deleteBook(Book book) async {
    try {
      await _dao.deleteBook(book.id!);
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
