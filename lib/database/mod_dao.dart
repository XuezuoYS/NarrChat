import '../models/mod.dart';
import '../utils/uuid_utils.dart';
import 'database_helper.dart';

/// `mods` 与 `book_mods` 表的数据访问对象（主键即 uuid，无第二个 id）。
///
/// - `mods`：用户自定义 Mod（预置 Mod 不落库，见 PresetMods）；
/// - `book_mods`：书籍启用的 Mod 及置入顺序（两端引用均为 uuid）。
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

  /// 按 uuid（主键）取未删除的用户 Mod。
  Future<Mod?> getModByUuid(String uuid) async {
    if (uuid.isEmpty) return null;
    final db = await _helper.database;
    final rows = await db.query(
      'mods',
      where: 'uuid = ? AND deleted_at IS NULL',
      whereArgs: [uuid],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Mod.fromMap(rows.first);
  }

  /// 插入新 Mod 并返回其 uuid（= 主键）；[Mod.uuid] 为空时生成 v4。
  Future<String> insertMod(Mod mod) async {
    final db = await _helper.database;
    final map = mod.toMap();
    var uuid = map['uuid'] as String? ?? '';
    if (uuid.isEmpty) {
      uuid = UuidUtils.generateUuidV4();
      map['uuid'] = uuid;
    }
    map['created_at'] = DateTime.now().toIso8601String();
    map['updated_at'] = map['created_at'];
    await db.insert('mods', map);
    return uuid;
  }

  /// 按 uuid 更新 Mod 内容列（uuid 自身不参与写集合）。
  Future<int> updateMod(Mod mod) async {
    if (mod.uuid.isEmpty) {
      throw StateError('updateMod 需要非空 uuid（未落库草稿请先 insertMod）');
    }
    final db = await _helper.database;
    final map = mod.toMap()..remove('uuid');
    map['updated_at'] = DateTime.now().toIso8601String();
    return db.update('mods', map, where: 'uuid = ?', whereArgs: [mod.uuid]);
  }

  /// 软删除用户自定义 Mod：打墓碑并显式清理引用它的 `book_mods` 行
  ///（原外键级联删除对硬删生效；软删需手动清理，保证书-Mod 配置稳定）。
  Future<void> deleteMod(String uuid) async {
    if (uuid.isEmpty) return;
    final db = await _helper.database;
    await db.transaction((txn) async {
      final refs = await txn.query(
        'book_mods',
        columns: ['book_uuid'],
        where: 'mod_uuid = ?',
        whereArgs: [uuid],
      );
      await txn.delete('book_mods', where: 'mod_uuid = ?', whereArgs: [uuid]);
      await txn.update(
        'mods',
        {'deleted_at': DateTime.now().millisecondsSinceEpoch},
        where: 'uuid = ?',
        whereArgs: [uuid],
      );
      final touched = <String>{};
      for (final r in refs) {
        final bookUuid = r['book_uuid'] as String?;
        if (bookUuid != null && bookUuid.isNotEmpty && touched.add(bookUuid)) {
          await DatabaseHelper.touchBook(txn, bookUuid, settings: true);
        }
      }
    });
  }

  // ---------- 书籍 Mod 关联 ----------

  /// 获取某本书的 Mod 配置（按置入顺序升序）。
  Future<List<BookModConfig>> getBookMods(String bookUuid) async {
    final db = await _helper.database;
    final rows = await db.query(
      'book_mods',
      where: 'book_uuid = ?',
      whereArgs: [bookUuid],
      orderBy: 'sort_order ASC, id ASC',
    );
    return rows.map(BookModConfig.fromMap).toList();
  }

  /// 整体替换某本书的 Mod 配置（删除后按新顺序重新插入，事务保证原子性）。
  ///
  /// 与库中现有配置**逐项一致时跳过**（内容指纹要求幂等：未变更的保存
  /// 不得产生假的"修改"从而触发无意义的同步）。
  Future<void> replaceBookMods(
    String bookUuid,
    List<BookModConfig> configs,
  ) async {
    final db = await _helper.database;
    final existing = await getBookMods(bookUuid);
    if (_configsEqual(existing, configs)) return;
    await db.transaction((txn) async {
      await txn.delete(
        'book_mods',
        where: 'book_uuid = ?',
        whereArgs: [bookUuid],
      );
      final batch = txn.batch();
      for (final config in configs) {
        // 归属以参数 [bookUuid] 为准（行内 book_uuid 只是冗余副本）：整本替换
        // 只可能写入这本书，杜绝空 / 陈旧 uuid 造成孤儿行或外键失败。
        batch.insert(
          'book_mods',
          config.toMap()
            ..remove('id')
            ..['book_uuid'] = bookUuid,
        );
      }
      await batch.commit(noResult: true);
      await DatabaseHelper.touchBook(txn, bookUuid, settings: true);
    });
  }

  /// 两个配置列表是否语义一致（引用、启用、顺序均相同；行 id 不参与比较）。
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