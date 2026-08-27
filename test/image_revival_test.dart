import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/database/sync_dao.dart';
import 'package:narrchat/services/sync/image_revival.dart';

/// 内存版 [SyncStateStore]，仅承载待推送删除墓碑相关逻辑。
class _FakeStateStore implements SyncStateStore {
  final List<SyncPendingDelete> pending = [];

  @override
  Future<SyncStateRecord> getState() async => const SyncStateRecord();
  @override
  Future<void> saveState(SyncStateRecord s) async {}
  @override
  Future<Map<String, SyncBookBase>> getAllBookBases() async => {};
  @override
  Future<void> putBookBase(SyncBookBase b) async {}
  @override
  Future<void> deleteBookBase(String title) async {}
  @override
  Future<Map<String, SyncModBase>> getAllModBases() async => {};
  @override
  Future<void> putModBase(SyncModBase b) async {}
  @override
  Future<void> deleteModBase(String name) async {}
  @override
  Future<List<SyncPendingDelete>> getPendingDeletes() async => List.of(pending);
  @override
  Future<void> addPendingDelete(SyncPendingDelete d) async => pending.add(d);
  @override
  Future<void> removePendingDelete(String path) async =>
      pending.removeWhere((e) => e.path == path);
}

void main() {
  test('命中墓碑：移除并返回 true', () async {
    final store = _FakeStateStore();
    store.pending.add(const SyncPendingDelete(path: 'img/b.png', deletedAt: 100));
    final revived = await reviveTombstonedImage(store, 'img/b.png');

    expect(revived, isTrue);
    expect(store.pending, isEmpty);
  });

  test('未命中墓碑：返回 false 且不修改墓碑', () async {
    final store = _FakeStateStore();
    store.pending.add(const SyncPendingDelete(path: 'img/b.png', deletedAt: 100));
    final revived = await reviveTombstonedImage(store, 'img/a.png');

    expect(revived, isFalse);
    expect(store.pending, hasLength(1));
    expect(store.pending.single.path, 'img/b.png');
  });

  test('多个墓碑仅移除命中的那一个', () async {
    final store = _FakeStateStore();
    store.pending.add(const SyncPendingDelete(path: 'img/b.png', deletedAt: 100));
    store.pending.add(const SyncPendingDelete(path: 'img/c.png', deletedAt: 200));
    final revived = await reviveTombstonedImage(store, 'img/c.png');

    expect(revived, isTrue);
    expect(store.pending.single.path, 'img/b.png');
  });
}
