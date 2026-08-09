import '../models/mod.dart';
import 'database_helper.dart';

/// `mods` 与 `book_mods` 表的数据访问对象。
///
/// - `mods`：用户自定义 Mod（预置 Mod 不落库，见 PresetMods）；
/// - `book_mods`：书籍启用的 Mod 及置入顺序。
///
/// 所有方法均包含 try-catch，异常向上抛出，由 Provider 层捕获并暴露给 UI。
class ModDao {
  final DatabaseHelper _helper = DatabaseHelper.instance;

  // ---------- 用户自定义 Mod ----------

  Future<List<Mod>> getAllMods() async {
    try {
      final db = await _helper.database;
      final rows = await db.query('mods', orderBy: 'id ASC');
      return rows.map(Mod.fromMap).toList();
    } catch (e) {
      rethrow;
    }
  }

  Future<int> insertMod(Mod mod) async {
    try {
      final db = await _helper.database;
      final map = mod.toMap()..remove('id');
      map['created_at'] = DateTime.now().toIso8601String();
      map['updated_at'] = map['created_at'];
      return db.insert('mods', map);
    } catch (e) {
      rethrow;
    }
  }

  Future<int> updateMod(Mod mod) async {
    try {
      final db = await _helper.database;
      final map = mod.toMap()..remove('id');
      map['updated_at'] = DateTime.now().toIso8601String();
      return db.update('mods', map, where: 'id = ?', whereArgs: [mod.id]);
    } catch (e) {
      rethrow;
    }
  }

  /// 删除用户自定义 Mod；引用了它的 `book_mods` 行由外键级联删除。
  Future<void> deleteMod(int id) async {
    try {
      final db = await _helper.database;
      await db.delete('mods', where: 'id = ?', whereArgs: [id]);
    } catch (e) {
      rethrow;
    }
  }

  // ---------- 书籍 Mod 关联 ----------

  /// 获取某本书的 Mod 配置（按置入顺序升序）。
  Future<List<BookModConfig>> getBookMods(int bookId) async {
    try {
      final db = await _helper.database;
      final rows = await db.query(
        'book_mods',
        where: 'book_id = ?',
        whereArgs: [bookId],
        orderBy: 'sort_order ASC, id ASC',
      );
      return rows.map(BookModConfig.fromMap).toList();
    } catch (e) {
      rethrow;
    }
  }

  /// 整体替换某本书的 Mod 配置（删除后按新顺序重新插入，事务保证原子性）。
  Future<void> replaceBookMods(int bookId, List<BookModConfig> configs) async {
    try {
      final db = await _helper.database;
      await db.transaction((txn) async {
        await txn.delete('book_mods', where: 'book_id = ?', whereArgs: [bookId]);
        final batch = txn.batch();
        for (final config in configs) {
          batch.insert('book_mods', config.toMap()..remove('id'));
        }
        await batch.commit(noResult: true);
      });
    } catch (e) {
      rethrow;
    }
  }
}
