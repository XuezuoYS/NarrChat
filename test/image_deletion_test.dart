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
    expect(store.state.revived, isEmpty);
  });

  test('重复删除同一张图：条目唯一并刷新删除/过期时间，撤销清单清除', () async {
    final store = MemoryTombstoneStore();
    final service = SyncImageDeletionService(store: store);

    await service.delete('img/a.png');
    await service.delete('img/a.png');

    expect(store.state.entries, hasLength(1));
    expect(store.state.entries.single.path, 'img/a.png');
  });

  test('重新添加（已登记复活标记）后再删除：新条目晚于标记，删除意图生效', () async {
    // 复活标记保留在副本中（还要抵消他机陈旧条目，不能清）；
    // 删除时间戳必须严格大于标记，合并时条目才不被抵消。
    final store = MemoryTombstoneStore();
    await store.save(
      ImgTombstones(revived: {'img/a.png': 9_999_999_999_999}),
    );
    final service = SyncImageDeletionService(store: store);

    await service.delete('img/a.png');

    expect(store.state.entries.single.path, 'img/a.png');
    expect(store.state.entries.single.deletedAt,
        greaterThan(store.state.revived['img/a.png']!),
        reason: '同一毫秒/时钟回摆也保证「最后一次操作为准」');
    expect(store.state.revived, hasLength(1), reason: '标记原样保留');
  });

  test('删除不存在的图片：路径仍登记条目（删除意图不丢失）', () async {
    final store = MemoryTombstoneStore();
    final service = SyncImageDeletionService(store: store);
    await service.delete('img/missing.png');

    expect(store.state.entries.single.path, 'img/missing.png');
  });
}
