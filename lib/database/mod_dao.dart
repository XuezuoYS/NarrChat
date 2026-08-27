import '../models/mod.dart';
import '../utils/uuid_utils.dart';
import 'database_helper.dart';

/// `mods` 与 `book_mods` 表的数据访问对象。
///
/// - `mods`：用户自定义 Mod（预置 Mod 不落库，见 PresetMods）；
/// - `book_mods`：书籍启用的 Mod 及置入顺序。
///
/// Mod 删除采用**软删**（`deleted_at` 墓碑）：同步层需要靠墓碑跨设备传播删除，
/// 且书籍引用（book_mods）随删除显式清理，保证书-Mod 指纹稳定。
class ModDao {
  final DatabaseHelper _helper = DatabaseHelper.instance;

  // ---------- 用户自定义 Mod ----------

  /// 全部未删除的用户自定义 Mod（软删行不再返回）。
  Future<List<Mod>> getAllMods() async {
    final db = await _helper.database;
    final rows = await db.query('mods', where: 'deleted_at IS NULL');
    return rows.map(Mod.fromMap).toList();
  }

  Future<int> insertMod(Mod mod) async {
    final db = await _helper.database;
    final map = mod.toMap()..remove('id');
    if ((map['uuid'] as String? ?? '').isEmpty) {
      map['uuid'] = UuidUtils.generateUuidV4();
    }
    map['created_at'] = DateTime.now().toIso8601String();
    map['updated_at'] = map['created_at'];
    return db.insert('mods', map);
  }

  Future<int> updateMod(Mod mod) async {
    final db = await _helper.database;
    final map = mod.toMap()..remove('id');
    // 同步身份（uuid）不可被更新覆盖：入参为空时沿用库中现有值。
    if ((map['uuid'] as String? ?? '').isEmpty) {
      final rows = await db.query(
        'mods',
        columns: ['uuid'],
        where: 'id = ?',
        whereArgs: [mod.id],
        limit: 1,
      );
      if (rows.isNotEmpty) {
        map['uuid'] = rows.first['uuid'] as String? ?? '';
      }
    }
    map['updated_at'] = DateTime.now().toIso8601String();
    return db.update('mods', map, where: 'id = ?', whereArgs: [mod.id]);
  }

  /// 软删除用户自定义 Mod：打墓碑并显式清理引用它的 `book_mods` 行
  ///（原外键级联删除对硬删生效；软删需手动清理，保证书-Mod 配置稳定）。
  Future<void> deleteMod(int id) async {
    final db = await _helper.database;
    await db.transaction((txn) async {
      final refs = await txn.query(
        'book_mods',
        columns: ['book_id'],
        where: 'mod_id = ?',
        whereArgs: [id],
      );
      await txn.delete('book_mods', where: 'mod_id = ?', whereArgs: [id]);
      await txn.update(
        'mods',
        {'deleted_at': DateTime.now().millisecondsSinceEpoch},
        where: 'id = ?',
        whereArgs: [id],
      );
      final touched = <int>{};
      for (final r in refs) {
        final bookId = r['book_id'] as int?;
        if (bookId != null && touched.add(bookId)) {
          await DatabaseHelper.touchBook(txn, bookId, settings: true);
        }
      }
    });
  }

  // ---------- 书籍 Mod 关联 ----------

  /// 获取某本书的 Mod 配置（按置入顺序升序）。
  Future<List<BookModConfig>> getBookMods(int bookId) async {
    final db = await _helper.database;
    final rows = await db.query(
      'book_mods',
      where: 'book_id = ?',
      whereArgs: [bookId],
      orderBy: 'sort_order ASC, id ASC',
    );
    return rows.map(BookModConfig.fromMap).toList();
  }

  /// 整体替换某本书的 Mod 配置（删除后按新顺序重新插入，事务保证原子性）。
  ///
  /// 与库中现有配置**逐项一致时跳过**（内容指纹要求幂等：未变更的保存
  /// 不得产生假的"修改"从而触发无意义的同步）。
  Future<void> replaceBookMods(int bookId, List<BookModConfig> configs) async {
    final db = await _helper.database;
    final existing = await getBookMods(bookId);
    if (_configsEqual(existing, configs)) return;
    await db.transaction((txn) async {
      await txn.delete('book_mods', where: 'book_id = ?', whereArgs: [bookId]);
      final batch = txn.batch();
      for (final config in configs) {
        batch.insert('book_mods', config.toMap()..remove('id'));
      }
      await batch.commit(noResult: true);
      await DatabaseHelper.touchBook(txn, bookId, settings: true);
    });
  }

  /// 两个配置列表是否语义一致（引用、启用、顺序均相同；id 不参与比较）。
  static bool _configsEqual(
    List<BookModConfig> a,
    List<BookModConfig> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final x = a[i];
      final y = b[i];
      if (x.ref != y.ref ||
          x.isEnabled != y.isEnabled ||
          x.sortOrder != y.sortOrder) {
        return false;
      }
    }
    return true;
  }
}
