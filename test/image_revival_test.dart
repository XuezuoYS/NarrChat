import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/sync/image_revival.dart';
import 'package:narrchat/services/sync/img_tombstones.dart';

import 'helpers/fakes.dart';

void main() {
  group('SyncImageRevivalService.revive（墓碑文件）', () {
    test('命中条目：删除对应条目并记录撤销，返回 true', () async {
      final store = MemoryTombstoneStore(
        ImgTombstones(entries: [
          ImgTombstoneEntry(
            path: 'img/b.png',
            deletedAt: 100,
            expiresAt: 100 + ImgTombstoneEntry.ttlMillis,
          ),
        ]),
      );
      final service = SyncImageRevivalService(store: store);

      final revived = await service.revive('img/b.png');

      expect(revived, isTrue);
      expect(store.state.entries, isEmpty);
      expect(store.state.revoked, ['img/b.png'],
          reason: '撤销记录用于抵消云端残留条目，防止复活被覆盖');
    });

    test('未命中条目：返回 false 且不修改墓碑', () async {
      final store = MemoryTombstoneStore(
        ImgTombstones(entries: [
          ImgTombstoneEntry(
            path: 'img/b.png',
            deletedAt: 100,
            expiresAt: 200,
          ),
        ]),
      );
      final service = SyncImageRevivalService(store: store);

      final revived = await service.revive('img/a.png');

      expect(revived, isFalse);
      expect(store.state.entries.single.path, 'img/b.png');
      expect(store.state.revoked, isEmpty);
    });

    test('多次重新添加：撤销清单累积（同步成功后统一消费）', () async {
      final store = MemoryTombstoneStore(
        ImgTombstones(entries: [
          ImgTombstoneEntry(
            path: 'img/b.png',
            deletedAt: 100,
            expiresAt: 200,
          ),
          ImgTombstoneEntry(
            path: 'img/c.png',
            deletedAt: 101,
            expiresAt: 201,
          ),
        ]),
      );
      final service = SyncImageRevivalService(store: store);

      await service.revive('img/b.png');
      await service.revive('img/c.png');

      expect(store.state.entries, isEmpty);
      expect(store.state.revoked.toSet(), {'img/b.png', 'img/c.png'});
    });
  });
}
