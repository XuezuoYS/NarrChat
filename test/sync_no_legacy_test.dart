import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/database/book_dao.dart';
import 'package:narrchat/database/database_helper.dart';
import 'package:narrchat/database/mod_dao.dart';
import 'package:narrchat/database/round_dao.dart';
import 'package:narrchat/database/world_book_dao.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/mod.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/models/world_book_entry.dart';
import 'package:narrchat/services/sync/remote_snapshot_applier.dart';
import 'package:narrchat/services/sync/sync_action_planner.dart';
import 'package:narrchat/services/sync/sync_local_snapshot.dart';
import 'package:narrchat/services/sync/sync_merge_planner.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 跨设备身份一致性（uuid-only 改造的验收视角）。
///
/// 两台设备各自持有独立的库，子表自增 id 完全互不相干（本地行标识，同步从不
/// 引用）。一次拉取落地后必须满足：书籍与 Mod 以 uuid 对齐、Mod 不重复、
/// **同名而 uuid 不同**的书 / Mod 各自独立（绝不按名称误配），且同一本逻辑书
/// 在两端的部件指纹逐字相同。
const sharedBookUuid = 'a1b2c3d4-0000-4000-8000-0000000000aa';
const sharedModUuid = 'b2c3d4e5-0000-4000-8000-0000000000bb';
const localTwinBookUuid = 'c3d4e5f6-0000-4000-8000-0000000000cc';
const localTwinModUuid = 'd4e5f6a7-0000-4000-8000-0000000000dd';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('sync_no_legacy_');
  });

  tearDown(() async {
    DatabaseHelper.debugDatabasePathOverride = null;
    await DatabaseHelper.instance.close();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {
      // 忽略清理失败。
    }
  });

  /// 以生产 schema 打开一台「设备」的库（切换路径前先关闭单例）。
  Future<({Database db, String path})> openDevice(String name) async {
    await DatabaseHelper.instance.close();
    final path = p.join(dir.path, '$name.db');
    DatabaseHelper.debugDatabasePathOverride = path;
    final db = await DatabaseHelper.instance.database;
    return (db: db, path: path);
  }



  test('设备 A 整本书（含 Mod）拉取到设备 B：按 uuid 对齐、同名不误配、指纹一致',
      () async {
    // ---------- 设备 A：一本书 + 一条用户 Mod + 世界书 ----------
    final a = await openDevice('device_a');
    final aBookUuid = await BookDao().insertBook(
      const Book(
        uuid: sharedBookUuid,
        title: '双城叙事',
        category: '玄幻',
        baseSetting: '设定 A',
      ),
    );
    expect(aBookUuid, sharedBookUuid);
    for (var i = 1; i <= 3; i++) {
      await RoundDao().insertRound(
        Round(
          bookUuid: sharedBookUuid,
          roundIndex: i,
          userInput: '输入 $i',
          aiNarrative: '正文 $i',
          createdAt: DateTime(2026, 8, 1, 10, i),
        ),
      );
    }
    await WorldBookDao().insertEntry(
      const WorldBookEntry(
        bookUuid: sharedBookUuid,
        keyword: '名剑',
        content: '一把会说话的剑',
      ),
    );
    final aModUuid = await ModDao().insertMod(
      const Mod(uuid: sharedModUuid, name: '文风增强', prePrompt: 'A 前置'),
    );
    expect(aModUuid, sharedModUuid);
    await ModDao().replaceBookMods(sharedBookUuid, [
      BookModConfig(modUuid: sharedModUuid, sortOrder: 0),
    ]);

    // A 的部件指纹与子表自增 id（拉取前记录，稍后与 B 对比）。
    final snapA = await SyncLocalSnapshot.build(a.db);
    final aRecord = snapA.books[sharedBookUuid]!;
    // 快照键就是主键 uuid，不存在任何第二种键。
    expect(snapA.books.keys, [sharedBookUuid]);
    expect(snapA.mods.keys, [sharedModUuid]);
    final aRoundIds = (await a.db.query(
      'rounds',
      where: 'book_uuid = ?',
      whereArgs: [sharedBookUuid],
    ))
        .map((r) => r['id'])
        .toList();

    // 快照字节 = A 库文件（生产里是云端代快照，此处逐字等价）。
    await DatabaseHelper.instance.close();
    final snapshotBytes =
        Uint8List.fromList(await File(a.path).readAsBytes());

    // ---------- 设备 B：先落一本同名书 + 同名 Mod（uuid 都不同）----------
    final b = await openDevice('device_b');
    await BookDao().insertBook(
      const Book(
        uuid: localTwinBookUuid,
        title: '双城叙事',
        baseSetting: '设定 B',
      ),
    );
    await RoundDao().insertRound(
      Round(
        bookUuid: localTwinBookUuid,
        roundIndex: 1,
        userInput: 'B 输入',
        aiNarrative: 'B 正文',
        createdAt: DateTime(2026, 8, 2),
      ),
    );
    await ModDao().insertMod(
      const Mod(uuid: localTwinModUuid, name: '文风增强', prePrompt: 'B 前置'),
    );
    await ModDao().replaceBookMods(localTwinBookUuid, [
      BookModConfig(modUuid: localTwinModUuid, sortOrder: 0),
    ]);

    // ---------- 拉取 A 的书 ----------
    await const RemoteSnapshotApplier().apply(
      mergePlan: SyncMergePlan(
        books: [
          const BookSyncDecision(
            localUuid: null,
            remoteUuid: sharedBookUuid,
            title: '双城叙事',
            presence: SyncBookPresence.remoteOnly,
            settings: SyncPartStatus.remoteOnly,
            rounds: SyncPartStatus.remoteOnly,
            worldBook: SyncPartStatus.remoteOnly,
            bookMods: SyncPartStatus.remoteOnly,
          ),
        ],
      ),
      action: const SyncAction(
        pullBookUuids: [sharedBookUuid],
        pushBookUuids: [],
        conflictBookUuids: [],
        deleteLocalBookUuids: [],
        deleteRemoteBookUuids: [],
        pushModUuids: [],
        pullModUuids: [],
        conflictModUuids: [],
        deleteRemoteModUuids: [],
        deleteLocalModUuids: [],
      ),
      snapshotBytes: snapshotBytes,
    );

    // 同名两本书各自独立（无标题回退匹配 → 绝不合并成一本）；
    // books 主键即 uuid，读取按主键升序。
    final books = await b.db.query('books', orderBy: 'uuid ASC');
    expect(
      books.map((r) => r['uuid']),
      [sharedBookUuid, localTwinBookUuid],
    );
    expect(
      (await b.db.query('rounds', where: 'book_uuid = ?', whereArgs: [
        sharedBookUuid,
      ]))
          .map((r) => r['ai_narrative']),
      ['正文 1', '正文 2', '正文 3'],
    );
    // Mod 不重复：A 的 Mod 原样按 uuid 落地，B 的同名 Mod 不受影响。
    final mods = await b.db.query('mods', orderBy: 'uuid ASC');
    expect(mods.map((m) => m['uuid']), [sharedModUuid, localTwinModUuid]);
    expect(
      mods.firstWhere((m) => m['uuid'] == sharedModUuid)['pre_prompt'],
      'A 前置',
    );
    // 书-Mod 引用按 uuid 对齐：各书指向各自的 Mod，没有因同名而串在一起。
    final mounts = await b.db.query('book_mods', orderBy: 'book_uuid ASC');
    expect(mounts, hasLength(2));
    expect(
      {for (final r in mounts) r['book_uuid']: r['mod_uuid']},
      {localTwinBookUuid: localTwinModUuid, sharedBookUuid: sharedModUuid},
    );
    // 世界书随书落地，父引用同样是 uuid。
    expect(
      (await b.db.query(
        'world_book_entries',
        where: 'book_uuid = ?',
        whereArgs: [sharedBookUuid],
      ))
          .single['keyword'],
      '名剑',
    );

    // ---------- 同一本逻辑书在两端指纹一致（本地 int id 从不参与）----------
    final snapB = await SyncLocalSnapshot.build(b.db);
    expect(snapB.books.keys, containsAll([localTwinBookUuid, sharedBookUuid]));
    final bRecord = snapB.books[sharedBookUuid]!;
    expect(bRecord.parts.settingsFp, aRecord.parts.settingsFp);
    expect(bRecord.parts.roundsFp, aRecord.parts.roundsFp);
    expect(bRecord.parts.worldBookFp, aRecord.parts.worldBookFp);
    expect(bRecord.parts.bookModsFp, aRecord.parts.bookModsFp);
    // 子表自增 id 因两台设备写入顺序不同而不同，但绝不进入任何同步标识。
    final bRoundIds = (await b.db.query(
      'rounds',
      where: 'book_uuid = ?',
      whereArgs: [sharedBookUuid],
    )).map((r) => r['id']).toList();
    expect(bRoundIds, isNot(aRoundIds));
    for (final key in {...snapB.books.keys, ...snapB.mods.keys}) {
      expect(key, isNot(contains('legacy')));
      expect(key, isNot(contains(':')));
    }
  });
}