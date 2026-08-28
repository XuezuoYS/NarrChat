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

    test('撤销（全局）：复活标记抵消云端残留条目，且标记随结果传播', () {
      final merged = mergeTombstones(
        local: ImgTombstones(revived: {'img/a.png': 300}),
        cloud: ImgTombstones(entries: [entry('img/a.png', 200)]),
        now: now,
      );
      expect(merged.entries, isEmpty);
      expect(merged.revived['img/a.png'], 300,
          reason: '标记必须保留在合并结果里（上云传播给他机，抵消其陈旧条目）');
    });

    test('他机陈旧条目被云端标记抵消（复活传播，不反杀）', () {
      // 设备 B 工作副本仍带着同步过的删除条目，云端已被 A 复活清空、只剩标记。
      final merged = mergeTombstones(
        local: ImgTombstones(entries: [entry('img/b.png', 200)]),
        cloud: ImgTombstones(revived: {'img/b.png': 400}),
        now: now,
      );
      expect(merged.entries, isEmpty,
          reason: 'deletedAt(200) <= revivedAt(400)：删除意图已被撤销');
      expect(merged.revived['img/b.png'], 400, reason: '标记继续在副本中保留');
    });

    test('复活后的新删除（deletedAt 晚于标记）不受抵消', () {
      final merged = mergeTombstones(
        local: ImgTombstones(entries: [entry('img/a.png', 500)]),
        cloud: ImgTombstones(revived: {'img/a.png': 300}),
        now: now,
      );
      expect(merged.entries.single.deletedAt, 500,
          reason: '重新添加之后再删除：最后一次操作为准');
    });

    test('标记并集取较晚时刻（本地与云端各带不同时间）', () {
      final merged = mergeTombstones(
        local: ImgTombstones(revived: {'img/a.png': 300}),
        cloud: ImgTombstones(revived: {'img/a.png': 900}),
        now: now,
      );
      expect(merged.revived['img/a.png'], 900);
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

    test('标记只抵消命中路径；不影响其它条目', () {
      final merged = mergeTombstones(
        local: ImgTombstones(
          entries: [entry('img/a.png', 100)],
          revived: {'img/b.png': 300},
        ),
        cloud: ImgTombstones(
          entries: [entry('img/a.png', 50), entry('img/b.png', 60)],
        ),
        now: now,
      );
      expect(merged.entries.map((e) => e.path).toList(), ['img/a.png']);
      expect(merged.entries.single.deletedAt, 100);
      expect(merged.revived['img/b.png'], 300);
    });

    test('标记过期（一年）后被清除；未过期保留', () {
      final merged = mergeTombstones(
        local: ImgTombstones(revived: {
          'img/fresh.png': now - ImgTombstoneEntry.ttlMillis + 1000,
          'img/stale.png': now - ImgTombstoneEntry.ttlMillis - 1000,
        }),
        cloud: ImgTombstones.empty,
        now: now,
      );
      expect(merged.revived.keys, ['img/fresh.png']);
    });
  });

  test('条目保留一年：expiresAt = deletedAt + 365 天', () {
    final e = ImgTombstoneEntry.deleted('img/a.png', 1000);
    expect(e.deletedAt, 1000);
    expect(e.expiresAt, 1000 + ImgTombstoneEntry.ttlMillis);
  });

  test('FileTombstoneStore：读写往返（含全局复活标记）', () async {
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
      revived: {'img/b.png': 300},
    );
    await store.save(file);
    final loaded = await store.load();

    expect(loaded.entries.single.path, 'img/a.png');
    expect(loaded.entries.single.expiresAt,
        100 + ImgTombstoneEntry.ttlMillis);
    expect(loaded.revived, {'img/b.png': 300});
    expect(
      File(p.join(root.path, 'local_config', 'img_tombstones.json')).existsSync(),
      isTrue,
    );
  });

  test('v1 旧格式（revoked 列表）容错解析：撤销迁移为复活标记', () {
    final before = DateTime.now().millisecondsSinceEpoch;
    final loaded = ImgTombstones.fromJson(const {
      'version': 1,
      'entries': [
        {'path': 'img/a.png', 'deletedAt': 100, 'expiresAt': 200},
      ],
      'revoked': ['img/b.png'],
    });
    final after = DateTime.now().millisecondsSinceEpoch;
    expect(loaded.entries.single.path, 'img/a.png');
    // v1 中未同步消费的撤销迁移为「读取时刻」的复活标记（抵消既有删除）。
    expect(loaded.revived['img/b.png'], inInclusiveRange(before, after));
  });
}
