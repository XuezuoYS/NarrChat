import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/cloud_backup/backup_unit.dart';
import 'package:path/path.dart' as p;

/// 备份单元命名与路径解析。
void main() {
  group('单元键', () {
    test('library / mods 固定键，book 带 uuid', () {
      expect(BackupUnit.library.unitKey, 'library');
      expect(BackupUnit.mods.unitKey, 'mods');
      expect(BackupUnit.book('b1').unitKey, 'book:b1');
    });

    test('parseUnitKey 往返，非法键返回 null', () {
      expect(BackupUnit.parseUnitKey('library'), BackupUnit.library);
      expect(BackupUnit.parseUnitKey('mods'), BackupUnit.mods);
      expect(BackupUnit.parseUnitKey('book:b1'), BackupUnit.book('b1'));
      expect(BackupUnit.parseUnitKey('book:'), isNull);
      expect(BackupUnit.parseUnitKey('book:a/b'), isNull);
      expect(BackupUnit.parseUnitKey('whatever'), isNull);
    });

    test('相等性按 (kind, refUuid)', () {
      expect(BackupUnit.book('b1'), BackupUnit.book('b1'));
      expect(BackupUnit.book('b1'), isNot(BackupUnit.book('b2')));
      expect(BackupUnit.library, isNot(BackupUnit.mods));
    });

    test('空 uuid 直接拒绝', () {
      expect(() => BackupUnit.book(''), throwsArgumentError);
    });
  });

  group('云端命名', () {
    test('基名 = 数据库原名去掉 .db', () {
      expect(BackupUnit.library.baseName, 'narrchat_library');
      expect(BackupUnit.mods.baseName, 'narrchat_mods');
      expect(BackupUnit.book('b1').baseName, 'narrbook_b1');
    });

    test('快照与清单命名固定格式', () {
      expect(
        BackupUnit.library.snapshotName(1),
        'narrchat_library_shot-g1.db',
      );
      expect(
        BackupUnit.mods.snapshotName(12),
        'narrchat_mods_shot-g12.db',
      );
      expect(
        BackupUnit.book('b1').snapshotName(3),
        'narrbook_b1_shot-g3.db',
      );
      expect(
        BackupUnit.book('b1').manifestName,
        'manifest_narrbook_b1.json',
      );
    });

    test('本地文件名与 R3 库文件名一致', () {
      expect(BackupUnit.library.fileName, 'narrchat_library.db');
      expect(BackupUnit.mods.fileName, 'narrchat_mods.db');
      expect(BackupUnit.book('b1').fileName, 'narrbook_b1.db');
    });
  });

  group('BackupLocator', () {
    const locator = BackupLocator(userDataDir: r'C:\data\user_data');

    test('三类单元映射到真实路径', () {
      expect(
        locator.localPathOf(BackupUnit.library),
        p.join(r'C:\data\user_data', 'narrchat_library.db'),
      );
      expect(
        locator.localPathOf(BackupUnit.mods),
        p.join(r'C:\data\user_data', 'narrchat_mods.db'),
      );
      expect(
        locator.localPathOf(BackupUnit.book('b1')),
        p.join(r'C:\data\user_data', 'books', 'narrbook_b1.db'),
      );
    });

    test('图片目录在 user_data/img', () {
      expect(locator.imagesDir, p.join(r'C:\data\user_data', 'img'));
    });
  });
}
