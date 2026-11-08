import '../../models/book.dart';
import '../../models/book_creation_draft.dart';
import '../../models/mod.dart';
import '../../models/preset_mods.dart';
import '../../repositories/book_repository.dart';
import '../../repositories/mod_repository.dart';
import '../../repositories/world_book_repository.dart';
import '../../utils/uuid_utils.dart';
import '../app_repositories.dart';
import 'book_creation_verifier.dart';

/// 一次落库尝试的结果。
class BookCreationWriteResult {
  const BookCreationWriteResult.success(Book this.book)
      : ok = true,
        error = null;

  const BookCreationWriteResult.failure(String this.error)
      : ok = false,
        book = null;

  /// 是否成功写入并通过回读 / 生效校验。
  final bool ok;

  /// 成功时回读出的书籍实例。
  final Book? book;

  /// 失败原因（已包含「书库已清理」的说明，可直接展示给用户）。
  final String? error;
}

/// 把创建草稿写成一本**正常的书**：书库 + 世界书 + 启用 Mod。
///
/// 与 `BookSettingsScreen` 的保存路径不同，这里刻意直接走仓储而不是 Provider：
/// - 需要「AI 完整但数据库出错 → 物理删除书与书库」的精确回滚（不写墓碑）；
/// - 需要写完后**重新读库**做回读校验（Provider 里是内存态，不能当事实）。
///
/// 页面在成功后自己 `BookProvider.loadBooks()` 刷新首页 / 设置页数据。
class BookCreationWriter {
  BookCreationWriter({
    required this.books,
    required this.worldBooks,
    required this.mods,
  });

  /// 生产环境入口：从全局仓储集合组装。
  factory BookCreationWriter.fromAppRepositories() {
    final repos = AppRepositories.instance;
    return BookCreationWriter(
      books: repos.books,
      worldBooks: repos.worldBook,
      mods: repos.mod,
    );
  }

  final BookRepository books;
  final WorldBookRepository worldBooks;
  final ModRepository mods;

  /// 写入并校验；失败时（除建库本身失败外）一定尽力清掉刚建的书与书库。
  ///
  /// - [fallbackTitle]：「保留此书」时标题为空的兜底（如「未命名书籍」）；
  /// - 成功前不触发任何云同步（由调用方在成功后统一触发一次）。
  Future<BookCreationWriteResult> writeAndVerify({
    required BookCreationDraft draft,
    String fallbackTitle = '',
  }) async {
    final expectedBook = draft.toBook(fallbackTitle: fallbackTitle);
    final expectedEntries = draft.effectiveWorldBook;

    // 先自己生成 uuid 再建库：万一 createBook 在建库中途失败，也能按这个 uuid
    // 把可能留下的半成品清掉（不留幻影书）。
    final uuid = UuidUtils.generateUuidV4();
    try {
      await books.createBook(expectedBook.copyWith(uuid: uuid));
    } catch (error) {
      final purgeNote = await _purge(uuid);
      return BookCreationWriteResult.failure(
        '创建书库失败：$error$purgeNote',
      );
    }

    try {
      final userMods = await mods.listMods();
      final storageRefs = <String>[];
      final persistedMods = <Mod>[];
      for (final uiRef in draft.modRefs) {
        final storageRef = Mod.storageRefOfUiRef(uiRef);
        if (storageRef == null || storageRefs.contains(storageRef)) continue;
        final resolved = _resolveStorageRef(storageRef, userMods);
        if (resolved == null) continue;
        storageRefs.add(storageRef);
        persistedMods.add(resolved);
      }

      await worldBooks.replaceAll(uuid, expectedEntries);
      await mods.setUseModUuids(uuid, storageRefs);

      // 回读：校验的事实来源必须是库，不是刚写进去的内存草稿。
      final savedBook = await books.loadBook(uuid);
      if (savedBook == null) {
        throw StateError('书库写入后读不回来');
      }
      final savedEntries = await worldBooks.list(uuid);
      final savedRefs = await mods.useModUuids(uuid);

      final problems = const BookCreationVerifier().verifyPersisted(
        expectedBook: expectedBook,
        savedBook: savedBook,
        expectedEntries: expectedEntries,
        savedEntries: savedEntries,
        expectedStorageModRefs: storageRefs,
        savedStorageModRefs: savedRefs,
        persistedMods: persistedMods,
      );
      if (problems.isNotEmpty) {
        final purgeNote = await _purge(uuid);
        return BookCreationWriteResult.failure(
          '数据校验未通过：${problems.join('；')}$purgeNote',
        );
      }
      return BookCreationWriteResult.success(savedBook);
    } catch (error) {
      final purgeNote = await _purge(uuid);
      return BookCreationWriteResult.failure('数据库写入失败：$error$purgeNote');
    }
  }

  /// 物理删除刚建的书（书库文件 + 目录行 + 缓存），不写墓碑。
  ///
  /// 这本书从未成功同步过，物理删除比「墓碑 + 云端整理」更干净；清理本身
  /// 失败时返回一句提示，附加到错误文案里。
  Future<String> _purge(String uuid) async {
    try {
      await books.purgeBook(uuid);
      return '（已清理未完整的书）';
    } catch (error) {
      return '（清理未完整的书失败：$error）';
    }
  }

  /// 书库存储引用 → Mod；预置用 `PresetMods`，用户 Mod 按 uuid 匹配。
  static Mod? _resolveStorageRef(String storageRef, List<Mod> userMods) {
    if (storageRef.startsWith(Mod.presetRefPrefix)) {
      return PresetMods.byKey(
        storageRef.substring(Mod.presetRefPrefix.length),
      );
    }
    for (final mod in userMods) {
      if (mod.uuid == storageRef) return mod;
    }
    return null;
  }
}
