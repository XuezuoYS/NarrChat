import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/database/sync_store.dart';
import 'package:narrchat/services/cloud_backup/backup_book_purge.dart';
import 'package:narrchat/services/cloud_backup/backup_manifest.dart';
import 'package:narrchat/services/cloud_backup/backup_unit.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/backup_fakes.dart';

/// 云端“已删除书”的清理：只删目标书的快照与清单，别的一律不碰。
void main() {
  final tempDirs = <Directory>[];
  late FakeBackupRemote remote;
  late SyncDb store;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    final dir = Directory.systemTemp.createTempSync('book_purge_');
    tempDirs.add(dir);
    remote = FakeBackupRemote();
    store = SyncDb(pathOverride: p.join(dir.path, 'sync.db'));
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

  test('只删目标书的全部快照 + 清单，其它书 / library / 图片不动', () async {
    remote.put('narrbook_b1_shot-g1.db', const [1]);
    remote.put('narrbook_b1_shot-g2.db', const [2]);
    remote.put('manifest_narrbook_b1.json', const [3]);
    remote.put('narrbook_b10_shot-g1.db', const [4]);
    remote.put('manifest_narrbook_b10.json', const [5]);
    remote.put('narrchat_library_shot-g1.db', const [6]);
    remote.put('manifest_narrchat_library.json', const [7]);
    remote.put('abcd.png', const [8]);
    remote.put('img_tombstones.json', const [9]);
    await store.putUnit(
      const SyncUnitRow(
        unitKey: 'book:b1',
        kind: 'book',
        refUuid: 'b1',
        generation: 2,
      ),
    );
    await store.putUnit(
      const SyncUnitRow(
        unitKey: 'book:b10',
        kind: 'book',
        refUuid: 'b10',
        generation: 1,
      ),
    );

    final removed = await purgeRemoteBook(
      remote: remote,
      bookUuid: 'b1',
      remoteNames: await remote.list(),
      store: store,
    );

    expect(removed, 3, reason: '两代快照 + 一份清单');
    expect(remote.files.keys, isNot(contains('narrbook_b1_shot-g1.db')));
    expect(remote.files.keys, isNot(contains('narrbook_b1_shot-g2.db')));
    expect(remote.files.keys, isNot(contains('manifest_narrbook_b1.json')));
    expect(
      remote.files.keys,
      containsAll([
        'narrbook_b10_shot-g1.db',
        'manifest_narrbook_b10.json',
        'narrchat_library_shot-g1.db',
        'manifest_narrchat_library.json',
        'abcd.png',
        'img_tombstones.json',
      ]),
      reason: '相似 uuid 的书和共享文件不能被误删',
    );
    expect(await store.unit('book:b1'), isNull);
    expect(await store.unit('book:b10'), isNotNull);
  });

  test('幂等：没有残留文件时不再发删除请求', () async {
    remote.put('narrbook_b1_shot-g1.db', const [1]);
    await purgeRemoteBook(
      remote: remote,
      bookUuid: 'b1',
      remoteNames: await remote.list(),
      store: store,
    );
    final deletesAfterFirst = remote.deleteCount;

    final again = await purgeRemoteBook(
      remote: remote,
      bookUuid: 'b1',
      remoteNames: await remote.list(),
      store: store,
    );

    expect(again, 0);
    expect(remote.deleteCount, deletesAfterFirst);
  });

  test('不传 remoteNames 时自己列一次云端', () async {
    remote.put('narrbook_b1_shot-g1.db', const [1]);
    final before = remote.listCount;

    final removed = await purgeRemoteBook(remote: remote, bookUuid: 'b1');

    expect(remote.listCount, before + 1);
    expect(removed, 1);
  });

  test('空 uuid：明确报错，不发任何请求', () async {
    await expectLater(
      purgeRemoteBook(remote: remote, bookUuid: ''),
      throwsA(isA<ArgumentError>()),
    );
    expect(remote.deleteCount, 0);
  });

  group('保留最新一代（正常删除）', () {
    BackupManifest manifestFor(String uuid, int generation) {
      return BackupManifest.build(
        unit: BackupUnit.book(uuid),
        generation: generation,
        digest: 'digest-$generation',
        deviceId: 'dev-1',
      );
    }

    test('只留最高代快照：删旧代，保留清单与同步单元，其它文件不动', () async {
      remote.put('narrbook_b1_shot-g1.db', const [1]);
      remote.put('narrbook_b1_shot-g2.db', const [2]);
      remote.put('narrbook_b1_shot-g3.db', const [3]);
      remote.put('manifest_narrbook_b1.json', manifestFor('b1', 3).encode());
      remote.put('narrbook_b10_shot-g1.db', const [10]);
      remote.put('manifest_narrbook_b10.json', const [11]);
      remote.put('narrchat_library_shot-g1.db', const [12]);
      await store.putUnit(
        const SyncUnitRow(
          unitKey: 'book:b1',
          kind: 'book',
          refUuid: 'b1',
          generation: 3,
        ),
      );

      final result = await retainLatestRemoteBookSnapshot(
        remote: remote,
        bookUuid: 'b1',
        remoteNames: await remote.list(),
        store: store,
      );

      expect(result.removed, 2);
      expect(result.keptSnapshotName, 'narrbook_b1_shot-g3.db');
      expect(remote.files.keys, contains('narrbook_b1_shot-g3.db'));
      expect(remote.files.keys, contains('manifest_narrbook_b1.json'));
      expect(remote.files.keys, isNot(contains('narrbook_b1_shot-g1.db')));
      expect(remote.files.keys, isNot(contains('narrbook_b1_shot-g2.db')));
      expect(
        remote.files.keys,
        containsAll([
          'narrbook_b10_shot-g1.db',
          'manifest_narrbook_b10.json',
          'narrchat_library_shot-g1.db',
        ]),
      );
      expect(await store.unit('book:b1'), isNotNull, reason: '保留同步基线');
    });

    test('代数按数字比较：g10 保留，g9 删掉', () async {
      remote.put('narrbook_b1_shot-g9.db', const [9]);
      remote.put('narrbook_b1_shot-g10.db', const [10]);

      final result = await retainLatestRemoteBookSnapshot(
        remote: remote,
        bookUuid: 'b1',
        remoteNames: await remote.list(),
      );

      expect(result.keptSnapshotName, 'narrbook_b1_shot-g10.db');
      expect(remote.files.keys, contains('narrbook_b1_shot-g10.db'));
      expect(remote.files.keys, isNot(contains('narrbook_b1_shot-g9.db')));
    });

    test('清单指向被删的旧代：一并删掉；指向保留代则留下', () async {
      remote.put('narrbook_b1_shot-g1.db', const [1]);
      remote.put('narrbook_b1_shot-g2.db', const [2]);
      remote.put('manifest_narrbook_b1.json', manifestFor('b1', 1).encode());

      await retainLatestRemoteBookSnapshot(
        remote: remote,
        bookUuid: 'b1',
        remoteNames: await remote.list(),
      );
      expect(
        remote.files.containsKey('manifest_narrbook_b1.json'),
        isFalse,
        reason: '清单指向已删的第 1 代，留着会误导以后的同步',
      );

      remote.put('narrbook_b1_shot-g3.db', const [3]);
      remote.put('manifest_narrbook_b1.json', manifestFor('b1', 3).encode());
      await retainLatestRemoteBookSnapshot(
        remote: remote,
        bookUuid: 'b1',
        remoteNames: await remote.list(),
      );
      expect(
        remote.files.containsKey('manifest_narrbook_b1.json'),
        isTrue,
        reason: '清单指向保留下来的第 3 代',
      );
    });

    test('云端没有快照：清掉残留清单与同步单元', () async {
      remote.put('manifest_narrbook_b1.json', const [1]);
      await store.putUnit(
        const SyncUnitRow(
          unitKey: 'book:b1',
          kind: 'book',
          refUuid: 'b1',
          generation: 2,
        ),
      );

      final result = await retainLatestRemoteBookSnapshot(
        remote: remote,
        bookUuid: 'b1',
        remoteNames: await remote.list(),
        store: store,
      );

      expect(result.keptSnapshotName, isNull);
      expect(result.removed, 0);
      expect(remote.files.containsKey('manifest_narrbook_b1.json'), isFalse);
      expect(await store.unit('book:b1'), isNull);
    });

    test('幂等：只剩一代时不再发删除请求', () async {
      remote.put('narrbook_b1_shot-g2.db', const [2]);
      await retainLatestRemoteBookSnapshot(
        remote: remote,
        bookUuid: 'b1',
        remoteNames: await remote.list(),
      );
      final deletes = remote.deleteCount;

      final again = await retainLatestRemoteBookSnapshot(
        remote: remote,
        bookUuid: 'b1',
        remoteNames: await remote.list(),
      );

      expect(again.removed, 0);
      expect(again.keptSnapshotName, 'narrbook_b1_shot-g2.db');
      expect(remote.deleteCount, deletes);
    });

    test('空 uuid：明确报错，不发任何请求', () async {
      await expectLater(
        retainLatestRemoteBookSnapshot(remote: remote, bookUuid: ''),
        throwsA(isA<ArgumentError>()),
      );
      expect(remote.deleteCount, 0);
    });
  });
}
