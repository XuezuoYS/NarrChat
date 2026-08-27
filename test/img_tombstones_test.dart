import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/sync/img_tombstones.dart';
import 'package:path/path.dart' as p;

void main() {
  const now = 1_000_000_000;

  ImgTombstoneEntry entry(String path, int deletedAt, {int? expiresAt}) =>
      ImgTombstoneEntry(
        path: path,
        deletedAt: deletedAt,
        expiresAt: expiresAt ?? deletedAt + ImgTombstoneEntry.ttlMillis,
      );

  group('mergeTombstones', () {
    test('并集：仅本地（离线删除）/ 仅云端（其它设备删除）都保留', () {
      final merged = mergeTombstones(
        local: ImgTombstones(entries: [entry('img/local.png', 100)]),
        cloud: ImgTombstones(entries: [entry('img/cloud.png', 200)]),
        now: now,
      );
      expect(
        merged.entries.map((e) => e.path).toSet(),
        {'img/local.png', 'img/cloud.png'},
      );
    });

    test('两边都有同一路径：取删除时间较新的一条', () {
      final merged = mergeTombstones(
        local: ImgTombstones(entries: [entry('img/a.png', 300)]),
        cloud: ImgTombstones(entries: [entry('img/a.png', 200)]),
        now: now,
      );
      expect(merged.entries.single.deletedAt, 300);

      final reversed = mergeTombstones(
        local: ImgTombstones(entries: [entry('img/a.png', 100)]),
        cloud: ImgTombstones(entries: [entry('img/a.png', 250)]),
        now: now,
      );
      expect(reversed.entries.single.deletedAt, 250);
    });

    test('撤销：本机重新添加（revoked）抵消云端残留条目', () {
      final merged = mergeTombstones(
        local: ImgTombstones(revoked: ['img/a.png']),
        cloud: ImgTombstones(entries: [entry('img/a.png', 200)]),
        now: now,
      );
      expect(merged.entries, isEmpty);
    });

    test('过期清除：expiresAt <= now 的条目被移除', () {
      final merged = mergeTombstones(
        local: ImgTombstones(entries: [
          entry('img/expired.png', 100, expiresAt: now),
          entry('img/live.png', 100, expiresAt: now + 1000),
        ]),
        cloud: ImgTombstones.empty,
        now: now,
      );
      expect(merged.entries.single.path, 'img/live.png');
    });

    test('撤销只影响本机合并结果；不影响其它路径', () {
      final merged = mergeTombstones(
        local: ImgTombstones(
          entries: [entry('img/a.png', 100)],
          revoked: ['img/b.png'],
        ),
        cloud: ImgTombstones(
          entries: [entry('img/a.png', 50), entry('img/b.png', 60)],
        ),
        now: now,
      );
      expect(merged.entries.single.path, 'img/a.png');
    });
  });

  test('条目保留一年：expiresAt = deletedAt + 365 天', () {
    final e = ImgTombstoneEntry.deleted('img/a.png', 1000);
    expect(e.deletedAt, 1000);
    expect(e.expiresAt, 1000 + ImgTombstoneEntry.ttlMillis);
  });

  test('FileTombstoneStore：读写往返（含撤销清单）', () async {
    final root = await Directory.systemTemp.createTemp('narrchat_tomb_');
    addTearDown(() async {
      FileTombstoneStore.testRootOverride = null;
      if (await root.exists()) await root.delete(recursive: true);
    });
    FileTombstoneStore.testRootOverride = root.path;

    final store = FileTombstoneStore();
    expect((await store.load()).entries, isEmpty, reason: '文件不存在 → 空清单');

    final file = ImgTombstones(
      entries: [ImgTombstoneEntry.deleted('img/a.png', 100)],
      revoked: ['img/b.png'],
    );
    await store.save(file);
    final loaded = await store.load();

    expect(loaded.entries.single.path, 'img/a.png');
    expect(loaded.entries.single.expiresAt,
        100 + ImgTombstoneEntry.ttlMillis);
    expect(loaded.revoked, ['img/b.png']);
    expect(
      File(p.join(root.path, 'local_config', 'img_tombstones.json')).existsSync(),
      isTrue,
    );
  });
}
