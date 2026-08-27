import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/image_store.dart';
import 'package:narrchat/services/sync/image_deletion.dart';
import 'package:narrchat/services/sync/img_tombstones.dart';
import 'package:path/path.dart' as p;

import 'helpers/fakes.dart';

void main() {
  late Directory userData;

  setUp(() async {
    userData = await Directory.systemTemp.createTemp('narrchat_del_');
    ImageStore.testUserDataRoot = userData.path;
  });

  tearDown(() async {
    ImageStore.testUserDataRoot = null;
    if (await userData.exists()) await userData.delete(recursive: true);
  });

  test('删除图片：删除本机文件 + 登记墓碑条目（含一年过期时间）', () async {
    final imgDir = Directory(p.join(userData.path, 'img'));
    await imgDir.create(recursive: true);
    await File(p.join(imgDir.path, 'a.png')).writeAsBytes([1, 2, 3]);
    expect(ImageStore.exists('img/a.png'), completion(isTrue));

    final store = MemoryTombstoneStore();
    final service = SyncImageDeletionService(store: store);
    await service.delete('img/a.png');

    expect(ImageStore.exists('img/a.png'), completion(isFalse));
    final entry = store.state.entries.single;
    expect(entry.path, 'img/a.png');
    expect(entry.deletedAt, greaterThan(0));
    expect(entry.expiresAt, entry.deletedAt + ImgTombstoneEntry.ttlMillis,
        reason: '条目保留一年');
    expect(store.state.revoked, isEmpty);
  });

  test('重复删除同一张图：条目唯一并刷新删除/过期时间，撤销清单清除', () async {
    final store = MemoryTombstoneStore();
    final service = SyncImageDeletionService(store: store);

    await service.delete('img/a.png');
    await service.delete('img/a.png');

    expect(store.state.entries, hasLength(1));
    expect(store.state.entries.single.path, 'img/a.png');
  });

  test('重新添加后再删除：删除意图回归，撤销清单清除该路径', () async {
    final store = MemoryTombstoneStore();
    await store.save(
      ImgTombstones(revoked: ['img/a.png']),
    );
    final service = SyncImageDeletionService(store: store);

    await service.delete('img/a.png');

    expect(store.state.revoked, isEmpty);
    expect(store.state.entries.single.path, 'img/a.png');
  });

  test('删除不存在的图片：路径仍登记条目（删除意图不丢失）', () async {
    final store = MemoryTombstoneStore();
    final service = SyncImageDeletionService(store: store);
    await service.delete('img/missing.png');

    expect(store.state.entries.single.path, 'img/missing.png');
  });
}
