import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/database/book_db.dart';
import 'package:narrchat/database/library_store.dart';
import 'package:narrchat/database/mods_store.dart';
import 'package:narrchat/database/sync_store.dart';
import 'package:narrchat/models/book_meta.dart';
import 'package:narrchat/models/round_generation.dart';
import 'package:narrchat/services/cloud_backup/backup_digest.dart';
import 'package:narrchat/services/cloud_backup/backup_image_plane.dart';
import 'package:narrchat/services/cloud_backup/backup_manifest.dart';
import 'package:narrchat/services/cloud_backup/backup_runner.dart';
import 'package:narrchat/services/cloud_backup/backup_unit.dart';
import 'package:narrchat/services/sync/img_tombstones.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/backup_fakes.dart';

/// 云备份端到端：用内存云端 + 临时目录里的真实 sqlite 跑完整流程。
void main() {
  final tempDirs = <Directory>[];
  late Directory userData;
  late Directory localConfig;
  late BackupLocator locator;
  late FakeBackupRemote remote;
  late SyncDb store;

  String newTempDir(String prefix) {
    final dir = Directory.systemTemp.createTempSync(prefix);
    tempDirs.add(dir);
    return dir.path;
  }

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    userData = Directory(newTempDir('backup_user_'));
    localConfig = Directory(newTempDir('backup_cfg_'));
    locator = BackupLocator(userDataDir: userData.path);
    remote = FakeBackupRemote();
    store = SyncDb(pathOverride: p.join(localConfig.path, 'sync.db'));
  });

  tearDown(() async {
    await store.close();
  });

  tearDownAll(() async {
    for (final dir in tempDirs) {
      try {
        await dir.delete(recursive: true);
      } catch (_) {
        // 清理失败不影响结论。
      }
    }
    tempDirs.clear();
  });

  String bookPath(String uuid) =>
      p.join(userData.path, 'books', 'narrbook_$uuid.db');

  BookMeta bookMeta(String uuid, {String title = '书'}) => BookMeta(
        bookUuid: uuid,
        masterUuid: 'm',
        title: title,
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 2),
      );

  RoundGeneration gen(String uuid, int index, {String narrative = ''}) {
    return RoundGeneration(
      meta: RoundMeta(
        uuid: uuid,
        roundIndex: index,
        roundSerialNum: 1,
        isUsing: true,
        operatedAt: DateTime.utc(2026, 1, 1),
      ),
      userInput: '问',
      aiNarrative: narrative,
    );
  }

  Future<void> seed() async {
    final library = LibraryDb(
      pathOverride: p.join(userData.path, 'narrchat_library.db'),
      masterUuidOverride: 'm',
    );
    await library.putBook(const LibraryBookRow(bookUuid: 'b1', title: '书'));
    await library.close();

    final mods = ModsDb(
      pathOverride: p.join(userData.path, 'narrchat_mods.db'),
      masterUuidOverride: 'm',
    );
    await mods.putMasterUuid('m');
    await mods.close();

    final book = await BookDb.create(
      meta: bookMeta('b1'),
      pathOverride: bookPath('b1'),
    );
    await book.rounds.insert(gen('g1', 1, narrative: '一'));
    await book.close();

    final img = File(p.join(userData.path, 'img', 'a.png'));
    await img.parent.create(recursive: true);
    await img.writeAsBytes(const [1, 2, 3]);
  }

  BackupContext context({
    List<String> books = const ['b1'],
    Future<void> Function(BackupUnit)? beforeReplace,
    Future<void> Function(BackupUnit)? afterReplace,
    Future<DateTime?> Function(BackupUnit)? updatedAtOf,
  }) {
    return BackupContext(
      bookUuids: () async => books,
      updatedAtOf: updatedAtOf ?? (unit) async =>
          unit.isBook ? DateTime.utc(2026, 1, 2) : null,
      beforeReplace: beforeReplace,
      afterReplace: afterReplace,
    );
  }

  BackupRunner runner({
    int keepVersions = 5,
    void Function(BackupProgress)? onProgress,
    bool Function()? isCancelled,
  }) {
    return BackupRunner(
      remote: remote,
      locator: locator,
      store: store,
      deviceId: 'dev-1',
      keepVersions: keepVersions,
      onProgress: onProgress,
      isCancelled: isCancelled,
    );
  }

  Future<String> digestOfPath(String path) async {
    final db = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(),
    );
    final unit = BackupUnit.book('b1');
    final digest = await BackupDigest.ofBook(unit, db);
    await db.close();
    return digest;
  }

  test('首次备份：三个单元各推第 1 代，并写下清单与本机代数', () async {
    await seed();
    final report = await runner().run(context: context());

    expect(report.fatalError, isNull);
    expect(report.errors, isEmpty);
    expect(report.pushed, 3);
    expect(report.unresolved, isEmpty);
    expect(remote.ready, isTrue);

    expect(remote.files.keys.where((n) => n.endsWith('.json')).toSet(), {
      'manifest_narrchat_library.json',
      'manifest_narrchat_mods.json',
      'manifest_narrbook_b1.json',
    });
    expect(remote.files.keys.where((n) => n.endsWith('.db')).toSet(), {
      'narrchat_library_shot-g1.db',
      'narrchat_mods_shot-g1.db',
      'narrbook_b1_shot-g1.db',
    });

    final manifest = BackupManifest.decode(
      remote.files['manifest_narrbook_b1.json']!,
    );
    expect(manifest.generation, 1);
    expect(manifest.unitKey, 'book:b1');
    expect(manifest.deviceId, 'dev-1');
    expect(manifest.snapshotName, 'narrbook_b1_shot-g1.db');

    for (final key in ['library', 'mods', 'book:b1']) {
      final row = await store.unit(key);
      expect(row!.generation, 1, reason: '$key 的代数应各自独立记 1');
      expect(row.baseDigest, isNotEmpty);
    }
  });

  test('内容没变再来一次：全部 upToDate，不重复上传', () async {
    await seed();
    final first = await runner().run(context: context());
    expect(first.errors, isEmpty, reason: '首轮备份不能有单元级错误');
    expect(first.pushed, 3);
    final writesAfterFirst = remote.writeCount;

    // 隔一秒以上再同步：摘要里若混进秒级墙上时间，这一轮会把每个单元又推一遍。
    await Future<void>.delayed(const Duration(milliseconds: 1100));

    final second = await runner().run(context: context());
    final detail = second.plans
        .map((plan) => '${plan.unit.unitKey}=${plan.action.name}')
        .join(',');
    expect(second.errors, isEmpty, reason: '第二次同步不该有单元级错误：$detail');
    expect(second.upToDate, 3, reason: '各单元现状：$detail');
    expect(second.pushed, 0);
    expect(remote.writeCount, writesAfterFirst);
  });

  test('只改一本书：只推这本书，代数 +1', () async {
    await seed();
    await runner().run(context: context());

    final book = await BookDb.open(bookUuid: 'b1', pathOverride: bookPath('b1'));
    await book.rounds.insert(gen('g2', 2, narrative: '二'));
    await book.close();

    final report = await runner().run(context: context());
    expect(report.pushed, 1);
    expect(report.plans.singleWhere((p) => p.unit.isBook).nextGeneration, 2);
    expect(remote.files.containsKey('narrbook_b1_shot-g2.db'), isTrue);
    expect((await store.unit('book:b1'))!.generation, 2);
  });

  test('云端前进且本地未改：拉下来覆盖本地，钩子按序调用', () async {
    await seed();
    final first = await runner().run(context: context());
    expect(first.errors, isEmpty, reason: '首轮备份不能有单元级错误');
    expect(first.pushed, 3);

    // 另一台设备推了第 2 代（内容不同）。
    final otherDir = newTempDir('backup_other_');
    final otherPath = p.join(otherDir, 'narrbook_b1.db');
    final other = await BookDb.create(
      meta: bookMeta('b1', title: '云端改过的书'),
      pathOverride: otherPath,
    );
    await other.rounds.insert(gen('g9', 1, narrative: '云端正文'));
    await other.close();
    final otherBytes = await File(otherPath).readAsBytes();
    final otherDigest = await digestOfPath(otherPath);

    remote.put('narrbook_b1_shot-g2.db', otherBytes);
    remote.put(
      'manifest_narrbook_b1.json',
      BackupManifest.build(
        unit: BackupUnit.book('b1'),
        generation: 2,
        digest: otherDigest,
        deviceId: 'dev-2',
      ).encode(),
    );

    final calls = <String>[];
    final report = await runner().run(
      context: context(
        beforeReplace: (unit) async => calls.add('before:${unit.unitKey}'),
        afterReplace: (unit) async => calls.add('after:${unit.unitKey}'),
      ),
    );

    expect(report.pulled, 1);
    expect(calls, ['before:book:b1', 'after:book:b1']);

    final localBytes = await File(bookPath('b1')).readAsBytes();
    expect(localBytes, otherBytes, reason: '本地文件被云端快照整份替换');

    final row = await store.unit('book:b1');
    expect(row!.generation, 2);
    expect(row.baseDigest, otherDigest);
  });

  test('两边都改：无裁决器时只报告冲突，不动本地文件', () async {
    await seed();
    await runner().run(context: context());

    final book = await BookDb.open(bookUuid: 'b1', pathOverride: bookPath('b1'));
    await book.rounds.insert(gen('g2', 2, narrative: '本地新轮'));
    await book.close();
    final localBefore = await File(bookPath('b1')).readAsBytes();

    remote.put(
      'narrbook_b1_shot-g2.db',
      const [9, 9, 9],
    );
    remote.put(
      'manifest_narrbook_b1.json',
      BackupManifest.build(
        unit: BackupUnit.book('b1'),
        generation: 2,
        digest: 'remote-digest',
        deviceId: 'dev-2',
      ).encode(),
    );

    final report = await runner().run(context: context());
    expect(report.hasConflicts, isTrue);
    expect(report.unresolved.single.unit, BackupUnit.book('b1'));
    expect(await File(bookPath('b1')).readAsBytes(), localBefore);
  });

  test('冲突选本地：把本地推成新的一代', () async {
    await seed();
    await runner().run(context: context());

    final book = await BookDb.open(bookUuid: 'b1', pathOverride: bookPath('b1'));
    await book.rounds.insert(gen('g2', 2, narrative: '本地新轮'));
    await book.close();

    remote.put('narrbook_b1_shot-g2.db', const [9, 9, 9]);
    remote.put(
      'manifest_narrbook_b1.json',
      BackupManifest.build(
        unit: BackupUnit.book('b1'),
        generation: 2,
        digest: 'remote-digest',
        deviceId: 'dev-2',
      ).encode(),
    );

    final report = await runner().run(
      context: context(),
      resolver: (plan) async => BackupConflictChoice.local,
    );
    expect(report.pushed, 1);
    expect(report.hasConflicts, isFalse);
    expect(remote.files.containsKey('narrbook_b1_shot-g3.db'), isTrue);
    expect((await store.unit('book:b1'))!.generation, 3);
  });

  test('冲突选云端：用云端快照覆盖本地', () async {
    await seed();
    await runner().run(context: context());

    final book = await BookDb.open(bookUuid: 'b1', pathOverride: bookPath('b1'));
    await book.rounds.insert(gen('g2', 2, narrative: '本地新轮'));
    await book.close();

    remote.put('narrbook_b1_shot-g2.db', const [7, 7, 7]);
    remote.put(
      'manifest_narrbook_b1.json',
      BackupManifest.build(
        unit: BackupUnit.book('b1'),
        generation: 2,
        digest: 'remote-digest',
        deviceId: 'dev-2',
      ).encode(),
    );

    final report = await runner().run(
      context: context(),
      resolver: (plan) async => BackupConflictChoice.remote,
    );
    expect(report.pulled, 1);
    expect(await File(bookPath('b1')).readAsBytes(), const [7, 7, 7]);
  });

  test('清单损坏：整轮停止并报错，绝不覆盖', () async {
    await seed();
    remote.put('manifest_narrchat_library.json', utf8.encode('{不是清单'));

    final report = await runner().run(context: context());
    expect(report.fatalError, isNotNull);
    expect(report.fatalError, contains('清单'));
    expect(remote.writeCount, 0, reason: '出错时不能写任何东西');
  });

  test('keepVersions：按库各自修剪旧快照', () async {
    await seed();
    await runner(keepVersions: 2).run(context: context());

    for (var i = 0; i < 2; i++) {
      final book =
          await BookDb.open(bookUuid: 'b1', pathOverride: bookPath('b1'));
      await book.rounds.insert(gen('extra$i', 2 + i, narrative: '追加'));
      await book.close();
      await runner(keepVersions: 2).run(context: context());
    }

    final bookSnapshots = remote.files.keys
        .where((n) => n.startsWith('narrbook_b1_shot-g'))
        .toSet();
    expect(bookSnapshots, {'narrbook_b1_shot-g2.db', 'narrbook_b1_shot-g3.db'});
  });

  test('取消：中途标记取消后不再处理后续单元', () async {
    await seed();
    var calls = 0;
    final report = await runner(
      isCancelled: () => ++calls > 1,
    ).run(context: context());

    expect(report.cancelled, isTrue);
    expect(report.pushed, lessThan(3));
  });

  test('进度回调覆盖检查 / 推送 / 完成三个阶段', () async {
    await seed();
    final phases = <String>[];
    await runner(onProgress: (progress) => phases.add(progress.phase))
        .run(context: context());

    expect(phases.first, 'digest');
    expect(phases, contains('push'));
    expect(phases.last, 'done');
  });

  group('图片平面', () {
    late MemoryTombstoneStore tombstones;
    late BackupImagePlane plane;

    setUp(() {
      tombstones = MemoryTombstoneStore();
      plane = BackupImagePlane(
        remote: remote,
        imagesDir: p.join(userData.path, 'img'),
        tombstoneStore: tombstones,
        clock: () => DateTime.utc(2026, 5, 1),
      );
    });

    test('本地新图上传，云端新图下载，墓碑图删云端', () async {
      // 本地 a.png（seed 里已建）→ 应上传
      await seed();
      // 云端已有 b.png → 应下载
      remote.put('b.png', const [4, 5, 6]);
      // 本地 c.png 已删除并立墓碑、云端还有 → 应删云端
      remote.put('c.png', const [7, 8, 9]);
      tombstones.value = ImgTombstones(
        entries: [
          ImgTombstoneEntry.deleted(
            'img/c.png',
            DateTime.utc(2026, 5, 1).millisecondsSinceEpoch,
          ),
        ],
      );

      final report = await plane.sync();
      expect(report.error, isNull);
      expect(report.uploaded, 1);
      expect(report.pulled, 1);
      expect(report.deleted, 1);

      expect(remote.files.containsKey('a.png'), isTrue);
      expect(File(p.join(userData.path, 'img', 'b.png')).existsSync(), isTrue);
      expect(remote.files.containsKey('c.png'), isFalse);
      expect(remote.files.containsKey(BackupImagePlane.tombstoneFileName), isTrue);
    });

    test('第二次同步不重复搬运', () async {
      await seed();
      await plane.sync();
      final writes = remote.writeCount;
      final second = await plane.sync();
      expect(second.uploaded, 0);
      expect(second.pulled, 0);
      expect(remote.writeCount, writes, reason: '墓碑内容没变就不重写');
    });
  });
}
