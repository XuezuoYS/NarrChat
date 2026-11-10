import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/database/library_store.dart';
import 'package:narrchat/services/cloud_backup/backup_library_merge.dart';

/// 书架自动合并：并集、墓碑传播、回收站还原、未知时间的保守取舍。
void main() {
  final createdAt = DateTime.utc(2026, 1, 1);
  final deletedAt = DateTime.utc(2026, 2, 1);
  final restoredAt = DateTime.utc(2026, 3, 1);

  LibraryBookRow alive(String uuid, {String? title}) =>
      LibraryBookRow(bookUuid: uuid, title: title ?? '书$uuid');

  LibraryBookRow tombstone(
    String uuid, {
    DateTime? at,
    int? roundIndex = 3,
    String? title,
  }) {
    return LibraryBookRow(
      bookUuid: uuid,
      title: title ?? '书$uuid',
      deletedAt: at ?? deletedAt,
      deletedRoundIndex: roundIndex,
    );
  }

  test('两侧并集：本地独有与云端独有的行都保留', () {
    final result = LibraryMerger.merge(
      LibraryMergeInputs(
        localRows: [alive('a'), alive('only-local')],
        remoteRows: [alive('a'), alive('only-remote')],
      ),
    );

    expect(result.mergedRows.map((row) => row.bookUuid), [
      'a',
      'only-local',
      'only-remote',
    ]);
    expect(result.addedLocal, 1);
    expect(result.addedRemote, 1);
    expect(result.changedRows.map((row) => row.bookUuid), ['only-remote']);
    expect(result.hasChanges, isTrue);
    expect(result.summary, contains('补入云端新增 1 本'));
  });

  test('两侧都活：留活，书名副本优先本地', () {
    final result = LibraryMerger.merge(
      LibraryMergeInputs(
        localRows: [alive('a', title: '本地名')],
        remoteRows: [alive('a', title: '云端名')],
      ),
    );

    expect(result.mergedRows.single.isDeleted, isFalse);
    expect(result.mergedRows.single.title, '本地名');
    expect(result.changedRows, isEmpty);
  });

  test('删除传播：墓碑更新（活侧书库时间更旧）→ 墓碑胜', () {
    final result = LibraryMerger.merge(
      LibraryMergeInputs(
        localRows: [tombstone('a', at: deletedAt)],
        remoteRows: [alive('a')],
        remoteBookContentAt: {'a': createdAt},
      ),
    );

    expect(result.mergedRows.single.isDeleted, isTrue);
    expect(result.mergedRows.single.deletedAt, deletedAt);
    expect(result.keptLocalTombstone, 1);
  });

  test('回收站还原：活侧书库时间更新 → 活胜，不被旧墓碑反杀', () {
    final result = LibraryMerger.merge(
      LibraryMergeInputs(
        localRows: [alive('a')],
        remoteRows: [tombstone('a', at: deletedAt)],
        localBookContentAt: {'a': restoredAt},
      ),
    );

    expect(result.mergedRows.single.isDeleted, isFalse);
    expect(result.revived, 1);
  });

  test('活侧时间未知：墓碑胜（绝不静默复活）', () {
    final result = LibraryMerger.merge(
      LibraryMergeInputs(
        localRows: [alive('a')],
        remoteRows: [tombstone('a', at: deletedAt)],
      ),
    );

    expect(result.mergedRows.single.isDeleted, isTrue);
    expect(result.adoptedRemoteTombstone, 1);
  });

  test('两侧都是墓碑：取 deleted_at 较新的一条（含删除轮号）', () {
    final result = LibraryMerger.merge(
      LibraryMergeInputs(
        localRows: [tombstone('a', at: deletedAt, roundIndex: 3)],
        remoteRows: [
          tombstone('a', at: DateTime.utc(2026, 4, 1), roundIndex: 7),
        ],
      ),
    );

    expect(result.mergedRows.single.deletedAt, DateTime.utc(2026, 4, 1));
    expect(result.mergedRows.single.deletedRoundIndex, 7);
    expect(result.adoptedRemoteTombstone, 1);
  });

  test('云端墓碑本地没有该行：整行补进来（继续向其它设备传播）', () {
    final result = LibraryMerger.merge(
      LibraryMergeInputs(
        localRows: [alive('a')],
        remoteRows: [alive('a'), tombstone('b', roundIndex: 5)],
      ),
    );

    final row = result.mergedRows.firstWhere((item) => item.bookUuid == 'b');
    expect(row.isDeleted, isTrue);
    expect(row.deletedRoundIndex, 5);
    expect(result.addedRemote, 1);
  });
}
