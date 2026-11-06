import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/cloud_backup/backup_image_plane.dart';
import 'package:narrchat/services/sync/img_tombstones.dart';
import 'package:path/path.dart' as p;

import 'helpers/backup_fakes.dart';

/// 图片平面（`BackupImagePlane`）单元测试。
///
/// 云端根目录是**混放**的：各库快照（`*_shot-gN.db`）与清单
/// （`manifest_*.json`）和图片在同一个目录里。图片平面必须只碰图片，
/// 否则会把数据库快照当图片下载进 `img/`（曾经的真 bug）。
void main() {
  late Directory root;
  late Directory imagesDir;
  late FakeBackupRemote remote;
  late MemoryTombstoneStore tombstones;
  late BackupImagePlane plane;

  final now = DateTime.utc(2026, 6, 1, 12);
  final nowMs = now.millisecondsSinceEpoch;

  setUp(() {
    root = Directory.systemTemp.createTempSync('img_plane_');
    imagesDir = Directory(p.join(root.path, 'img'))
      ..createSync(recursive: true);
    remote = FakeBackupRemote();
    tombstones = MemoryTombstoneStore();
    plane = BackupImagePlane(
      remote: remote,
      imagesDir: imagesDir.path,
      tombstoneStore: tombstones,
      clock: () => now,
    );
  });

  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } catch (_) {
      // Windows 偶发占用，不影响结论。
    }
  });

  void writeLocal(String name, List<int> bytes) {
    File(p.join(imagesDir.path, name)).writeAsBytesSync(bytes);
  }

  bool localHas(String name) => File(p.join(imagesDir.path, name)).existsSync();

  group('扩展名过滤', () {
    test('云端快照与清单不会被当成图片下载（回归哨兵）', () async {
      remote.put('a.png', const [1, 1, 1]);
      remote.put('b.jpg', const [2, 2, 2]);
      // 同目录下的数据库快照与备份清单：都不属于图片平面。
      remote.put('narrbook_b1_shot-g1.db', const [9, 9, 9]);
      remote.put('manifest_narrbook_b1.json', const [8, 8, 8]);

      final report = await plane.sync();

      expect(report.error, isNull);
      expect(report.pulled, 2, reason: '只下载两张真图片');
      expect(localHas('a.png'), isTrue);
      expect(localHas('b.jpg'), isTrue);
      expect(localHas('narrbook_b1_shot-g1.db'), isFalse,
          reason: '数据库快照绝不能进 img/');
      expect(localHas('manifest_narrbook_b1.json'), isFalse,
          reason: '清单绝不能进 img/');
      // 云端也没被误删。
      expect(remote.files.containsKey('narrbook_b1_shot-g1.db'), isTrue);
      expect(remote.files.containsKey('manifest_narrbook_b1.json'), isTrue);
    });

    test('本地非图片文件不会被上传', () async {
      writeLocal('a.png', const [1]);
      writeLocal('notes.txt', const [2]);

      final report = await plane.sync();

      expect(report.uploaded, 1);
      expect(remote.files.containsKey('a.png'), isTrue);
      expect(remote.files.containsKey('notes.txt'), isFalse);
    });

    test('大写扩展名按图片处理', () async {
      remote.put('C.PNG', const [3]);

      await plane.sync();

      expect(localHas('C.PNG'), isTrue);
    });
  });

  group('墓碑合并', () {
    test('本地墓碑 + 云端仍有该图 → 合并后仍删云端，不复活', () async {
      remote.put('gone.png', const [7, 7, 7]);
      tombstones.value = ImgTombstones(
        entries: [ImgTombstoneEntry.deleted('img/gone.png', nowMs - 1000)],
      );

      final report = await plane.sync();

      expect(report.deleted, 1);
      expect(remote.files.containsKey('gone.png'), isFalse);
      expect(localHas('gone.png'), isFalse, reason: '墓碑的图不该被下载回来');
    });

    test('云端墓碑同样生效（另一台设备删的）', () async {
      remote.put('remote_gone.png', const [5]);
      remote.put(
        BackupImagePlane.tombstoneFileName,
        utf8.encode(jsonEncode(
          ImgTombstones(
            entries: [
              ImgTombstoneEntry.deleted('img/remote_gone.png', nowMs - 500),
            ],
          ).toJson(),
        )),
      );

      final report = await plane.sync();

      expect(localHas('remote_gone.png'), isFalse,
          reason: '云端墓碑声明的图不下载');
      expect(report.pulled, 0);
    });

    test('墓碑合并结果会写回本地工作副本', () async {
      remote.put('gone.png', const [7]);
      tombstones.value = ImgTombstones(
        entries: [ImgTombstoneEntry.deleted('img/gone.png', nowMs - 1000)],
      );

      await plane.sync();

      expect(tombstones.saveCount, greaterThan(0));
      expect(
        tombstones.value.entries.map((e) => e.path),
        contains('img/gone.png'),
      );
    });
  });

  group('复活抵消', () {
    test('本地「再添加」取消墓碑 → 合并后不上报删除', () async {
      remote.put('revived.png', const [4, 4, 4]);
      // 先删过（deletedAt 较早），后来又登记了更晚的复活标记。
      tombstones.value = ImgTombstones(
        entries: [ImgTombstoneEntry.deleted('img/revived.png', nowMs - 5000)],
        revived: {'img/revived.png': nowMs - 1000},
      );

      final report = await plane.sync();

      expect(report.deleted, 0, reason: '复活后不再是待删');
      expect(remote.files.containsKey('revived.png'), isTrue,
          reason: '云端那份要留着');
      expect(localHas('revived.png'), isTrue, reason: '本地没有就补下来');
    });

    test('复活之后再删除：更晚的删除仍然生效', () async {
      remote.put('again.png', const [6]);
      tombstones.value = ImgTombstones(
        entries: [ImgTombstoneEntry.deleted('img/again.png', nowMs - 100)],
        revived: {'img/again.png': nowMs - 2000},
      );

      final report = await plane.sync();

      expect(report.deleted, 1, reason: 'deletedAt 晚于 revivedAt，删除有效');
      expect(remote.files.containsKey('again.png'), isFalse);
    });
  });

  group('同名内容不一致', () {
    test('图片名是内容寻址的：同名不同内容按本地为准，不覆盖', () async {
      // `<sha256>.<ext>` 命名下同名即同内容；出现同名不同内容说明有一端脏了，
      // 当前实现选择"不覆盖本地"（远端那份不下载），避免来回抖动。
      writeLocal('same.png', const [1, 1, 1]);
      remote.put('same.png', const [2, 2, 2]);

      final report = await plane.sync();

      expect(report.pulled, 0, reason: '本地已有同名文件，不重复下载');
      expect(
        File(p.join(imagesDir.path, 'same.png')).readAsBytesSync(),
        const [1, 1, 1],
        reason: '本地内容保持原样',
      );
      expect(remote.files['same.png'], isNotNull);
    });

    test('本地缺失时按远端内容补下来', () async {
      remote.put('only_remote.png', const [2, 2, 2]);

      final report = await plane.sync();

      expect(report.pulled, 1);
      expect(
        File(p.join(imagesDir.path, 'only_remote.png')).readAsBytesSync(),
        const [2, 2, 2],
      );
    });
  });

  test('双向增量：第二轮不再重复搬运', () async {
    writeLocal('a.png', const [1]);
    remote.put('b.png', const [2]);

    await plane.sync();
    final writes = remote.writeCount;
    final second = await plane.sync();

    expect(second.uploaded, 0);
    expect(second.pulled, 0);
    expect(remote.writeCount, writes, reason: '墓碑内容没变就不重写');
  });

  test('取消：sync 中途取消后不再继续搬运', () async {
    writeLocal('a.png', const [1]);
    writeLocal('b.png', const [2]);

    final report = await plane.sync(isCancelled: () => true);

    expect(report.uploaded, 0);
    expect(remote.files.containsKey('a.png'), isFalse);
  });
}
