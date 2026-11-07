import '../database/book_db_pool.dart';
import '../repositories/book_repository.dart';
import '../repositories/mod_repository.dart';
import '../repositories/round_repository.dart';
import '../repositories/world_book_repository.dart';
import 'app_stores.dart';

/// 应用级仓库集合：provider 从这里拿数据入口。
///
/// 为什么要一个全局单例：provider 由 `ChangeNotifierProvider` 在 widget 树里创建，
/// 没有地方逐层传参。约定：
/// - **生产**：`main()` 里调一次 [initialize] 后 `runApp`；
/// - **测试**：一律给 provider 注入替身，**永远不要**初始化这里
///   （它一初始化就会去打开真实用户目录）。
class AppRepositories {
  AppRepositories({
    required this.stores,
    required this.books,
    required this.rounds,
    required this.worldBook,
    required this.mod,
  });

  final AppStores stores;
  final BookRepository books;
  final RoundRepository rounds;
  final WorldBookRepository worldBook;
  final ModRepository mod;

  static AppRepositories? _instance;

  /// 未初始化时为 null（测试 / 工具想探测时用）。
  static AppRepositories? get instanceOrNull => _instance;

  /// 已初始化的实例；未初始化直接抛错，避免"悄悄用了空数据"。
  static AppRepositories get instance {
    final value = _instance;
    if (value == null) {
      throw StateError('AppRepositories 尚未初始化：请在 main() 里先 await initialize()');
    }
    return value;
  }

  static bool get isInitialized => _instance != null;

  /// 打开存储并组装仓库（生产入口，只调一次）。
  static Future<AppRepositories> initialize({AppStores? stores}) async {
    final resolved = stores ?? await AppStores.open();
    final repository = AppRepositories(
      stores: resolved,
      books: BookRepositorySqlite(
        library: resolved.library,
        cache: resolved.cache,
        books: resolved.books,
      ),
      rounds: RoundRepository(books: resolved.books),
      worldBook: WorldBookRepository(books: resolved.books),
      mod: ModRepository(mods: resolved.mods, books: resolved.books),
    );
    // 旧版本删除书只打墓碑、不删文件：启动时清一次本机残留（墓碑保留）。
    // 云端旧代由下一次数据面同步整理（只留最新一代）；这里失败不阻塞启动。
    try {
      await repository.books.purgeTombstonedBooks();
    } catch (_) {
      // 启动清理是"锦上添花"，失败留给同步时的兜底。
    }
    _instance = repository;
    return repository;
  }

  /// 测试 / 退出时清掉（下次 [initialize] 重新装配）。
  static Future<void> reset() async {
    final current = _instance;
    _instance = null;
    await current?.stores.dispose();
  }

  BookDbPool get bookPool => stores.books;

  /// 迁移里失败的书（启动提示"可重试"）。
  Future<Map<String, String>> failedBooks() => stores.failedBooks();
}
