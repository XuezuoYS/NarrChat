import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/cloud_backup/backup_catalog.dart';
import 'package:narrchat/services/cloud_backup/backup_unit.dart';
import 'package:narrchat/services/webdav_service.dart';

/// 云备份目录：按库分组、固定顺序、书籍按最后备份时间排序（纯逻辑）。
void main() {
  WebDavFile file(String name, {DateTime? at, int size = 0}) =>
      WebDavFile(name: name, lastModified: at, size: size);

  test('只列有快照的库：Library → Mod → 书籍，与输入顺序无关', () {
    final entries = BackupCatalog.build(
      files: [
        file('narrbook_b1_shot-g1.db'),
        file('narrchat_library_shot-g2.db'),
        file('narrbook_b2_shot-g1.db'),
        file('narrchat_mods_shot-g1.db'),
      ],
      bookTitles: {'b1': '甲书', 'b2': '乙书'},
    );

    expect(
      entries.map((entry) => entry.displayName).toList(),
      ['Library 库', 'Mod 库', '书籍《甲书》库', '书籍《乙书》库'],
    );
    expect(entries.map((entry) => entry.unit.kind).toList(), [
      BackupUnitKind.library,
      BackupUnitKind.mods,
      BackupUnitKind.book,
      BackupUnitKind.book,
    ]);
  });

  test('书籍按最后备份时间新 → 旧', () {
    final entries = BackupCatalog.build(
      files: [
        file('narrbook_old_shot-g1.db', at: DateTime.utc(2026, 11, 1, 10)),
        file('narrbook_new_shot-g1.db', at: DateTime.utc(2026, 11, 5, 10)),
      ],
      bookTitles: {'old': '旧书', 'new': '新书'},
    );

    expect(
      entries.map((entry) => entry.unit.refUuid).toList(),
      ['new', 'old'],
      reason: '最新备份在前',
    );
  });

  test('时间缺失的垫底；同时间按 uuid 升序（跨设备稳定）', () {
    final same = DateTime.utc(2026, 11, 5, 10);
    final entries = BackupCatalog.build(
      files: [
        file('narrbook_c_shot-g1.db', at: same),
        file('narrbook_a_shot-g1.db'),
        file('narrbook_b_shot-g1.db', at: same),
      ],
    );

    expect(entries.map((entry) => entry.unit.refUuid).toList(), ['b', 'c', 'a']);
  });

  test('同一库的代次新 → 旧，最新一代与总代数正确', () {
    final entries = BackupCatalog.build(
      files: [
        file('narrchat_library_shot-g2.db'),
        file('narrchat_library_shot-g7.db'),
        file('narrchat_library_shot-g5.db'),
      ],
    );

    final entry = entries.single;
    expect(
      entry.snapshots.map((snapshot) => snapshot.name).toList(),
      [
        'narrchat_library_shot-g7.db',
        'narrchat_library_shot-g5.db',
        'narrchat_library_shot-g2.db',
      ],
    );
    expect(entry.latestGeneration, 7);
    expect(entry.totalCount, 3);
  });

  test('清单 / 图片 / 旧命名 / 无名快照一律忽略', () {
    final entries = BackupCatalog.build(
      files: [
        file('manifest_narrchat_library.json'),
        file('narrchat_snapshot_g3_x.db'),
        file('narrchat_snapshot_g3.db'),
        file('unrelated.db'),
        file('a.png'),
        file('narrbook__shot-g3.db'),
      ],
    );

    expect(entries, isEmpty);
  });

  test('书名缺失时用 uuid 前 8 位兜底', () {
    final entries = BackupCatalog.build(
      files: [
        file('narrbook_abcdef12-3456-7890_shot-g1.db'),
      ],
    );

    expect(entries.single.displayName, '书籍《abcdef12》库');
  });

  test('displayName 支持书名，且 library / mods 不拼书名', () {
    final entries = BackupCatalog.build(
      files: [
        file('narrchat_library_shot-g1.db'),
        file('narrchat_mods_shot-g1.db'),
        file('narrbook_b1_shot-g1.db'),
      ],
      bookTitles: {'b1': '深海余烬'},
    );

    expect(entries.map((entry) => entry.displayName).toList(), [
      'Library 库',
      'Mod 库',
      '书籍《深海余烬》库',
    ]);
  });

  test('formatTime：本地时间展示，缺失给「时间未知」', () {
    expect(
      BackupCatalog.formatTime(DateTime(2026, 11, 6, 22, 8)),
      '2026-11-06 22:08',
    );
    expect(BackupCatalog.formatTime(null), '时间未知');
  });

  test('formatSize：KB / MB 一位小数，0 字节不占位', () {
    expect(BackupCatalog.formatSize(446464), '436.0 KB');
    expect(BackupCatalog.formatSize(2048), '2.0 KB');
    expect(BackupCatalog.formatSize(3 * 1024 * 1024), '3.0 MB');
    expect(BackupCatalog.formatSize(0), '');
    expect(BackupCatalog.formatSize(-1), '');
  });
}
