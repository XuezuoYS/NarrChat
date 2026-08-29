import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/database/book_dao.dart';
import 'package:narrchat/database/database_helper.dart';
import 'package:narrchat/database/mod_dao.dart';
import 'package:narrchat/database/round_dao.dart';
import 'package:narrchat/database/sync_dao.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/failed_attempt.dart';
import 'package:narrchat/models/mod.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/services/sync/remote_snapshot_applier.dart';
import 'package:narrchat/services/sync/sync_local_snapshot.dart';
import 'package:narrchat/services/sync/database_sync_runner.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/fakes.dart';

/// 双设备端到端（真库 ×2 + 共享内存云端存储）：
/// 1. A 建书 → A 同步 → 云端 gen1；
/// 2. B 首连拉取整书（uuid 即主键，远端身份原样入库）；
/// 3. B 再次同步 → 无变更（不推进代数）；
/// 4. A 改全局后置词 → 同步 → B 检出「云端单侧设置变更」待确认（不静默覆盖
///    本地），确认后落地新后置词；
/// 5. B 重存相同书籍设置 → 无变更不推送。
///
/// 身份只有一处：`books` / `mods` 的主键 uuid。拉取、删除传播、Mod 去重、
/// 失败条目同步全部按 uuid 定位——不存在标题 / 名称回退匹配。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory dir;
  late String pathA;
  late String pathB;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('sync_e2e_');
    pathA = p.join(dir.path, 'a.db');
    pathB = p.join(dir.path, 'b.db');
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

  Future<void> useDb(String path) async {
    await DatabaseHelper.instance.close();
    DatabaseHelper.debugDatabasePathOverride = path;
    await DatabaseHelper.instance.database;
  }

  DatabaseSyncRunner serviceFor(
    String deviceId,
    String dbPath,
    MemorySyncStore store,
    MemorySyncStateStore state,
  ) {
    return DatabaseSyncRunner(
      store: store,
      stateStore: state,
      deviceId: deviceId,
      buildLocalSnapshot: () async =>
          SyncLocalSnapshot.build(await DatabaseHelper.instance.database),
      buildSnapshotBytes: () async => File(dbPath).readAsBytes(),
      referencedImages: () async => const [],
      keepVersions: 5,
      lockRetryDelay: Duration.zero,
      applyRemotePlan: (action) async {
        // 删除传播：动作清单里的标识就是本地主键，直接按 uuid 软删。
        final bookDao = BookDao();
        for (final b in await bookDao.getAllBooks()) {
          if (action.deleteLocalBookUuids.contains(b.uuid)) {
            await bookDao.softDeleteBook(b.uuid);
          }
        }
        final modDao = ModDao();
        for (final m in await modDao.getAllMods()) {
          if (action.deleteLocalModUuids.contains(m.uuid)) {
            await modDao.deleteMod(m.uuid);
          }
        }
      },
      applyRemoteBooks: (mergePlan, action, bytes) => const RemoteSnapshotApplier()
          .apply(mergePlan: mergePlan, action: action, snapshotBytes: bytes),
    );
  }

  test('A 改后置词 → B 拉到一致；B 重存相同设置不推送；B 再次同步无变更', () async {
    final store = MemorySyncStore();
    final stateA = MemorySyncStateStore();
    final stateB = MemorySyncStateStore();

    // —— A：建书 + 首次同步（云端 gen1）——
    await useDb(pathA);
    final bookDaoA = BookDao();
    final bookAUuid = await bookDaoA.insertBook(
      const Book(title: '书A', category: '玄幻', globalPostPrompt: '旧后置词'),
    );
    var result = await serviceFor('dev-a', pathA, store, stateA).sync();
    expect(result.applied, isTrue);
    expect(result.pushed, isTrue);
    expect(store.manifest!.generation, 1);
    expect(bookAUuid, isNotEmpty);
    expect((await bookDaoA.getBookByUuid(bookAUuid))!.uuid, bookAUuid,
        reason: 'insertBook 返回的 uuid 就是可读回的主键');

    // —— B：首连拉取整书（远端 uuid 原样入库）——
    await useDb(pathB);
    result = await serviceFor('dev-b', pathB, store, stateB).sync();
    expect(result.applied, isTrue);
    expect(result.pushed, isFalse, reason: '仅拉取 → 不推进代数');
    expect(store.manifest!.generation, 1, reason: '云端代数未被 B 推进');
    final bookDaoB = BookDao();
    final bookB = (await bookDaoB.getAllBooks()).single;
    expect(bookB.title, '书A');
    expect(bookB.globalPostPrompt, '旧后置词');
    expect(bookB.uuid, bookAUuid, reason: 'books 主键即同步身份，无第二种标识');

    // —— B 再次同步：已一致 → 无变更 ——
    result = await serviceFor('dev-b', pathB, store, stateB).sync();
    expect(result.applied, isFalse, reason: '两端一致 → 无任何落地');
    expect(store.manifest!.generation, 1);

    // —— A 修改全局后置词并推送（gen2）——
    await useDb(pathA);
    await bookDaoA.updateBook(
      Book(uuid: bookAUuid, title: '书A', category: '玄幻', globalPostPrompt: '新后置词'),
    );
    result = await serviceFor('dev-a', pathA, store, stateA).sync();
    expect(result.applied, isTrue);
    expect(result.pushed, isTrue);
    expect(store.manifest!.generation, 2);

    // —— B 同步：云端新后置词 → 设置类单侧变更走人工确认门（不静默应用）——
    await useDb(pathB);
    result = await serviceFor('dev-b', pathB, store, stateB).sync();
    expect(result.hasConflict, isTrue, reason: '云端单改设置需进合并决策页确认');
    expect(result.applied, isFalse);
    expect(store.manifest!.generation, 2, reason: '确认门前绝不改写云端');
    final pendingB = (await BookDao().getAllBooks()).single;
    expect(pendingB.globalPostPrompt, '旧后置词',
        reason: '未确认前本地不被云端版本覆盖');

    // —— 模拟用户在合并决策页选择「导入」：云端设置落地本地，共基按云端
    // 清单重定基（_rebaseAndQueuedSync 流程）→ 再次同步与云端一致、不推送 ——
    await bookDaoB.updateBook(
      Book(
        uuid: pendingB.uuid,
        title: pendingB.title,
        category: pendingB.category,
        globalPostPrompt: '新后置词',
      ),
    );
    final cloudEntry = store.manifest!.books.single;
    expect(cloudEntry.uuid, bookAUuid, reason: 'manifest 直接以 uuid 定位');
    stateB.bookBases[cloudEntry.uuid] = SyncBookBase(
      uuid: cloudEntry.uuid,
      title: cloudEntry.title,
      settingsFp: cloudEntry.settingsFp,
      roundsFp: cloudEntry.roundsFp,
      worldbookFp: cloudEntry.worldBookFp,
      bookmodsFp: cloudEntry.bookModsFp,
    );
    result = await serviceFor('dev-b', pathB, store, stateB).sync();
    expect(result.applied, isFalse, reason: '导入后与云端一致 → 无需推送');
    expect(store.manifest!.generation, 2);
    final updatedB = (await BookDao().getAllBooks()).single;
    expect(updatedB.globalPostPrompt, '新后置词', reason: '后置词已同步至另一台设备');
    expect(updatedB.uuid, bookAUuid);

    // —— B 重存相同设置（无修改）→ 无变更（代数不再 +1）——
    final b = (await BookDao().getAllBooks()).single;
    await BookDao().updateBook(
      Book(uuid: b.uuid, title: b.title, category: b.category, globalPostPrompt: '新后置词'),
    );
    result = await serviceFor('dev-b', pathB, store, stateB).sync();
    expect(result.applied, isFalse, reason: '内容未变 → 已是最新版本');
    expect(result.pushed, isFalse);
    expect(store.manifest!.generation, 2, reason: '相同内容重复保存不推进代数');
  });

  test('同名不同 uuid 的书 / Mod → 两个独立实体（无标题回退匹配）', () async {
    final store = MemorySyncStore();
    final stateA = MemorySyncStateStore();
    final stateB = MemorySyncStateStore();

    // —— A：同名书 + 同名 Mod，uuid 自定 ——
    await useDb(pathA);
    await BookDao().insertBook(const Book(uuid: 'u-book-A', title: '独立书'));
    await ModDao().insertMod(const Mod(uuid: 'u-mod-A', name: '独立 Mod'));
    expect((await serviceFor('dev-a', pathA, store, stateA).sync()).pushed, isTrue);
    expect(store.manifest!.books.map((e) => e.uuid).toSet(), {'u-book-A'});

    // —— B：本机另建同名同 Mod 不同 uuid ——
    await useDb(pathB);
    await BookDao().insertBook(const Book(uuid: 'u-book-B', title: '独立书'));
    await ModDao().insertMod(const Mod(uuid: 'u-mod-B', name: '独立 Mod'));
    final bResult = await serviceFor('dev-b', pathB, store, stateB).sync();
    expect(bResult.hasConflict, isFalse, reason: '同名不同 uuid = 两个实体，不判冲突');
    expect(bResult.pushed, isTrue);
    expect(store.manifest!.books.map((e) => e.uuid).toSet(),
        {'u-book-A', 'u-book-B'}, reason: '云端并存两本同名书');
    expect(store.manifest!.mods.map((e) => e.uuid).toSet(),
        {'u-mod-A', 'u-mod-B'}, reason: '云端并存两个同名 Mod');

    // —— A 再同步：把 B 的书 / Mod 各自拉成独立一行（不按名称归并）——
    await useDb(pathA);
    final aResult = await serviceFor('dev-a', pathA, store, stateA).sync();
    expect(aResult.applied, isTrue);
    expect((await BookDao().getAllBooks()).map((b) => b.uuid),
        unorderedEquals(['u-book-A', 'u-book-B']));
    expect((await ModDao().getAllMods()).map((m) => m.uuid),
        unorderedEquals(['u-mod-A', 'u-mod-B']));
  });

  test('A 软删 Mod → B 同步删除本地的同一 Mod（uuid 匹配）', () async {
    final store = MemorySyncStore();
    final stateA = MemorySyncStateStore();
    final stateB = MemorySyncStateStore();

    // —— A：建 Mod + 挂载到书 + 首次同步 ——
    await useDb(pathA);
    final bookDao = BookDao();
    await bookDao.insertBook(const Book(title: '书X'));
    final modDao = ModDao();
    final modUuid = await modDao.insertMod(const Mod(name: '风格'));
    expect((await modDao.getAllMods()).single.uuid, modUuid,
        reason: 'insertMod 返回值即 mods 主键');

    var result = await serviceFor('dev-a', pathA, store, stateA).sync();
    expect(result.applied, isTrue);
    expect(store.manifest!.generation, 1);

    // —— B：首连拉取（书 + Mod 独立/引用均落地）——
    await useDb(pathB);
    result = await serviceFor('dev-b', pathB, store, stateB).sync();
    expect(result.applied, isTrue);
    expect((await ModDao().getAllMods()).single.uuid, modUuid,
        reason: '跨设备 Mod 身份一致');
    expect(await ModDao().getModByUuid(modUuid), isNotNull);

    // —— A 删除 Mod → 推送（gen2，manifest 不再含该 Mod）——
    await useDb(pathA);
    await ModDao().deleteMod(modUuid);
    result = await serviceFor('dev-a', pathA, store, stateA).sync();
    expect(result.applied, isTrue);
    expect(result.pushed, isTrue);
    expect(store.manifest!.mods, isEmpty, reason: '远端删除已发布');

    // —— B 同步：采用远端删除（软删本地 Mod + 清理引用）——
    await useDb(pathB);
    result = await serviceFor('dev-b', pathB, store, stateB).sync();
    expect(result.applied, isTrue, reason: '删除传播落地');
    expect(await ModDao().getAllMods(), isEmpty, reason: '远端删除的 Mod 已在本地软删');
    expect(await ModDao().getModByUuid(modUuid), isNull);
    expect(store.manifest!.mods, isEmpty);
    // 重复同步：稳定不变。
    result = await serviceFor('dev-b', pathB, store, stateB).sync();
    expect(result.applied, isFalse, reason: '删除传播后两端一致');
  });

  test('设置部件并发修改（A 改分类、B 改后置词）→ 第二次同步返回真冲突（单部件语义）', () async {
    final store = MemorySyncStore();
    final stateA = MemorySyncStateStore();
    final stateB = MemorySyncStateStore();

    // —— A：建书并同步（云端 gen1 基线）——
    await useDb(pathA);
    final bookDaoA = BookDao();
    final bookUuid = await bookDaoA.insertBook(
      const Book(title: '书C', category: '旧分类', globalPostPrompt: '旧后置词'),
    );
    var result = await serviceFor('dev-a', pathA, store, stateA).sync();
    expect(result.applied, isTrue);
    expect(store.manifest!.generation, 1);
    expect((await bookDaoA.getBookByUuid(bookUuid))!.uuid, bookUuid);

    // —— B：首连拉取（身份一致）——
    await useDb(pathB);
    result = await serviceFor('dev-b', pathB, store, stateB).sync();
    expect(result.applied, isTrue);
    expect((await BookDao().getAllBooks()).single.uuid, bookUuid,
        reason: '两端同一本书 = 同一个 uuid');

    // —— A 改分类并推送 ——
    await useDb(pathA);
    await bookDaoA.updateBook(
      Book(uuid: bookUuid, title: '书C', category: '新分类', globalPostPrompt: '旧后置词'),
    );
    result = await serviceFor('dev-a', pathA, store, stateA).sync();
    expect(result.applied, isTrue);
    expect(result.pushed, isTrue);
    expect(store.manifest!.generation, 2);

    // —— B 改后置词（不同字段）→ 单部件语义：设置双改 → 真冲突 ——
    await useDb(pathB);
    final bookDaoB = BookDao();
    final bookB = (await bookDaoB.getAllBooks()).single;
    await bookDaoB.updateBook(
      Book(
        uuid: bookB.uuid,
        title: bookB.title,
        category: bookB.category,
        globalPostPrompt: '新后置词',
      ),
    );
    result = await serviceFor('dev-b', pathB, store, stateB).sync();
    expect(result.hasConflict, isTrue, reason: '设置任一字段双改必须先弹冲突');
    expect(result.applied, isFalse, reason: '冲突时不静默覆盖');
    // 冲突期间云端未被改写，两端改动都保留。
    expect(store.manifest!.generation, 2);
    final keptA = (await BookDao().getAllBooks()).single;
    expect(keptA.category, '旧分类', reason: 'B 尚未同步成功，B 本地改动保留原样');
    expect(keptA.globalPostPrompt, '新后置词');
  });

  test('失败条目随轮次同步：A 生成失败 → B 拉到；A 成功生成 → 失败条目清空随轮次同步', () async {
    final store = MemorySyncStore();
    final stateA = MemorySyncStateStore();
    final stateB = MemorySyncStateStore();

    await useDb(pathA);
    final bookDaoA = BookDao();
    final bookUuidA = await bookDaoA.insertBook(const Book(title: '书E'));
    var result = await serviceFor('dev-a', pathA, store, stateA).sync();
    expect(result.applied, isTrue);

    await useDb(pathB);
    result = await serviceFor('dev-b', pathB, store, stateB).sync();
    expect(result.applied, isTrue);
    final bookUuidB = (await BookDao().getAllBooks()).single.uuid;
    expect(bookUuidB, bookUuidA);

    // —— A：生成失败（失败条目 + 一条失败占位轮次同生命周期）——
    await useDb(pathA);
    await bookDaoA.setFailedAttempt(
      bookUuidA,
      const FailedAttempt(userInput: '坏输入', errorMessage: '网络超时'),
    );
    result = await serviceFor('dev-a', pathA, store, stateA).sync();
    expect(result.applied, isTrue);
    expect(store.manifest!.generation, 2);

    // —— B：拉到失败条目（与轮次同一部件）——
    await useDb(pathB);
    result = await serviceFor('dev-b', pathB, store, stateB).sync();
    expect(result.applied, isTrue, reason: '失败条目变更作为轮次部件拉取');
    final failedB = await BookDao().getFailedAttempt(bookUuidB);
    expect(failedB.userInput, '坏输入');
    expect(failedB.errorMessage, '网络超时', reason: '失败条目已随轮次部件落地');

    // —— A 成功生成（新增轮次 + 清空失败条目）→ B 同步后失败条目清空 ——
    await useDb(pathA);
    await RoundDao().insertRound(
      Round(bookUuid: bookUuidA, roundIndex: 1, userInput: '好输入', aiNarrative: '正文'),
    );
    await bookDaoA.setFailedAttempt(bookUuidA, const FailedAttempt());
    result = await serviceFor('dev-a', pathA, store, stateA).sync();
    expect(result.applied, isTrue);
    expect(result.pushed, isTrue);

    await useDb(pathB);
    result = await serviceFor('dev-b', pathB, store, stateB).sync();
    expect(result.applied, isTrue);
    final cleared = await BookDao().getFailedAttempt(bookUuidB);
    expect(cleared.userInput, '', reason: '成功生成清空失败条目，作为轮次部件变更同步');
    expect(cleared.errorMessage, '');
    expect((await RoundDao().getRoundsByBook(bookUuidB)).map((r) => r.roundIndex),
        contains(1), reason: '新增轮次同步到达');
  });

  test('同字段并发修改（都改后置词）→ 第二次同步返回真冲突，不做静默覆盖', () async {
    final store = MemorySyncStore();
    final stateA = MemorySyncStateStore();
    final stateB = MemorySyncStateStore();

    await useDb(pathA);
    final bookDaoA = BookDao();
    final bookUuid = await bookDaoA.insertBook(
      const Book(title: '书D', globalPostPrompt: 'P0'),
    );
    var result = await serviceFor('dev-a', pathA, store, stateA).sync();
    expect(result.applied, isTrue);

    await useDb(pathB);
    result = await serviceFor('dev-b', pathB, store, stateB).sync();
    expect(result.applied, isTrue);
    expect((await BookDao().getAllBooks()).single.uuid, bookUuid);

    // A 改后置词 → push（P1）；B 也改后置词 → B 同步必弹冲突。
    await useDb(pathA);
    await bookDaoA.updateBook(
      Book(uuid: bookUuid, title: '书D', globalPostPrompt: 'P1'),
    );
    result = await serviceFor('dev-a', pathA, store, stateA).sync();
    expect(result.applied, isTrue);
    expect(store.manifest!.generation, 2);

    await useDb(pathB);
    final bookB = (await BookDao().getAllBooks()).single;
    await BookDao().updateBook(
      Book(uuid: bookB.uuid, title: bookB.title, globalPostPrompt: 'P2'),
    );
    result = await serviceFor('dev-b', pathB, store, stateB).sync();
    expect(result.hasConflict, isTrue, reason: '设置双改必须先弹冲突');
    expect(result.applied, isFalse, reason: '冲突时不静默覆盖');
    // 冲突期间云端未被改写。
    expect(store.manifest!.generation, 2);
    expect(store.manifest!.books.single.settingsFp, isNotEmpty);
    expect(store.manifest!.books.single.uuid, bookUuid);
  });
}
