import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/cloud_backup/backup_remote.dart';

import 'helpers/backup_fakes.dart';

/// `WebDavBackupRemote`：把「这个远端在云端哪个目录」落实到每一次 WebDAV 操作。
///
/// 回归重点：曾经 `ensureReady` / `list` / `get` / `put` / `delete` 全都传 `''`，
/// 于是快照、清单、图片全堆在 WebDAV 根目录，而不是 `<folder>/`。
void main() {
  test('ensureReady 逐级建出目录（父级 + 自己）', () async {
    final dav = FakeWebDavService();
    final remote = WebDavBackupRemote(dav, folder: 'narrchat/img');

    await remote.ensureReady();

    expect(dav.ensureCalls, ['', 'narrchat', 'narrchat/img']);
  });

  test('读写列删全部落在指定目录，根目录不留文件', () async {
    final dav = FakeWebDavService(pathScoped: true);
    final remote = WebDavBackupRemote(dav, folder: 'narrchat');

    await remote.ensureReady();
    await remote.write('narrbook_b1_shot-g1.db', Uint8List.fromList([1, 2, 3]));
    await remote.write('manifest_narrbook_b1.json', '{}'.codeUnits);

    expect(dav.files.keys.toSet(), {
      'narrchat/narrbook_b1_shot-g1.db',
      'narrchat/manifest_narrbook_b1.json',
    });

    expect(await remote.list(), {
      'narrbook_b1_shot-g1.db',
      'manifest_narrbook_b1.json',
    });
    expect(await remote.read('narrbook_b1_shot-g1.db'), [1, 2, 3]);

    await remote.delete('manifest_narrbook_b1.json');
    expect(dav.files.keys.toSet(), {'narrchat/narrbook_b1_shot-g1.db'});

    expect(dav.writes.map((w) => w.path).toSet(), {'narrchat'});
    expect(dav.reads.single.path, 'narrchat');
    expect(dav.deletes.single.path, 'narrchat');
    expect(dav.listPaths, ['narrchat']);
  });

  test('文件夹为空串时退回根目录（兜底语义）', () async {
    final dav = FakeWebDavService();
    final remote = WebDavBackupRemote(dav, folder: '');

    await remote.write('a.db', Uint8List.fromList([9]));

    expect(dav.files.containsKey('a.db'), isTrue);
    expect(dav.writes.single.path, '');
  });

  test('WebDAV 异常统一转成 BackupRemoteException（保留状态码）', () async {
    final dav = FakeWebDavService(getError: '连接超时');
    final remote = WebDavBackupRemote(dav, folder: 'narrchat');

    await expectLater(
      remote.read('x.db'),
      throwsA(
        isA<BackupRemoteException>().having(
          (error) => error.message,
          'message',
          contains('读取云端文件失败'),
        ),
      ),
    );
  });
}
