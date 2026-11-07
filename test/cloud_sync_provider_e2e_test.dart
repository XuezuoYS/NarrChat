import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/providers/cloud_sync_provider.dart';
import 'package:narrchat/services/cloud_backup/backup_catalog.dart';
import 'package:narrchat/services/cloud_backup/backup_digest.dart';
import 'package:narrchat/services/cloud_backup/backup_manifest.dart';
import 'package:narrchat/services/cloud_backup/backup_planner.dart';
import 'package:narrchat/services/cloud_backup/backup_runner.dart';
import 'package:narrchat/services/cloud_backup/backup_unit.dart';
import 'package:narrchat/services/sync/sync_models.dart';
import 'package:narrchat/services/webdav_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/backup_fakes.dart' hide MemoryTombstoneStore;
import 'helpers/fakes.dart';

/// `CloudSyncProvider` 端到端：真库（`TestStack`）+ 内存云端（`FakeBackupRemote`）。
///
/// 覆盖 provider 独占、单元级 `backup_runner_test` 测不到的东西：
/// - 进度事件 → `SyncPlane` / `SyncPhase` 映射；
/// - `_closeForReplace` 之后各 store **懒重开**（整份替换后还能继续读）；
/// - `unresolvedConflicts` 的填充与 `resolveConflict(local/remote)` 两条真实路径。
///
/// 依赖全部构造注入（仓储 / 云端 / 墓碑），不碰全局单例，也不写真实用户目录。
void main() {
  late TestStack stack;
  late FakeBackupRemote remote;
  late MemoryTombstoneStore tombstones;
  late CloudSyncProvider provider;

  setUp(() async {
    stack = await TestStack.create();
    remote = FakeBackupRemote();
    tombstones = MemoryTombstoneStore();
    provider = CloudSyncProvider(
      repositories: stack.repos,
      backupRemoteFactory: () => remote,
      tombstoneStore: tombstones,
    )..debugSetConfigured();
    // mods 库是懒建的：先读一次，让它在首次同步里算「存在」（否则整单元被跳过）。
    await stack.stores.mods.list();
  });

  tearDown(() async {
    provider.dispose();
    await stack.dispose();
  });

  /// 用生产同一套算法算某个 library 库文件的内容摘要。
  Future<String> digestOfLibrary(String path) async {
    final db = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(),
    );
    try {
      return await BackupDigest.ofLibrary(BackupUnit.library, db);
    } finally {
      await db.close();
    }
  }

  /// 造一份"别的设备"的 library 快照 + 清单，放到云端第 [generation] 代。
  Future<TestStack> putRemoteLibraryFromOtherDevice({
    required String title,
    required int generation,
  }) async {
    final other = await TestStack.create(prefix: 'sync_e2e_other_');
    await other.seedBook(uuid: 'b-cloud', title: title);
    final bytes = await File(other.paths.libraryDbPath).readAsBytes();
    final digest = await digestOfLibrary(other.paths.libraryDbPath);

    remote.put(BackupUnit.library.snapshotName(generation), bytes);
    remote.put(
      BackupUnit.library.manifestName,
      BackupManifest.build(
        unit: BackupUnit.library,
        generation: generation,
        digest: digest,
        deviceId: 'other-device',
      ).encode(),
    );
    return other;
  }

  test('首次同步：各单元推第 1 代，数据面与图片面都成功', () async {
    final bookUuid = await stack.seedBook(title: '书A');
    await stack.seedRound(bookUuid, roundIndex: 1, aiNarrative: '正文');

    final ok = await provider.sync();

    expect(provider.dataError, isNull, reason: '数据面不该报错：${provider.dataError}');
    expect(
      provider.imageError,
      isNull,
      reason: '图片面不该报错：${provider.imageError}',
    );
    expect(ok, isTrue);
    expect(provider.dataSyncState, SyncState.success);
    expect(provider.imageSyncState, SyncState.success);
    expect(provider.dataProgress, isNull, reason: '跑完要清掉进度');
    expect(provider.imageProgress, isNull);

    expect(
      remote.files.keys,
      containsAll([
        'narrchat_library_shot-g1.db',
        'manifest_narrchat_library.json',
        'narrchat_mods_shot-g1.db',
        'narrbook_${bookUuid}_shot-g1.db',
        'manifest_narrbook_$bookUuid.json',
      ]),
    );
  });

  test('进度事件映射到 SyncPhase：至少出现一次 pushSnapshot', () async {
    final bookUuid = await stack.seedBook();
    await stack.seedRound(bookUuid, roundIndex: 1, aiNarrative: '正文');

    final phases = <SyncPhase>{};
    void listener() {
      final progress = provider.dataProgress;
      if (progress != null) phases.add(progress.phase);
    }

    provider.addListener(listener);
    await provider.sync();
    provider.removeListener(listener);

    expect(phases, isNotEmpty, reason: '同步过程中应至少报过一次进度');
    expect(
      phases,
      contains(SyncPhase.pushSnapshot),
      reason: '首次同步全是 push，应映射成 pushSnapshot',
    );
  });

  test('内容没变再同步：不再新增快照', () async {
    final bookUuid = await stack.seedBook();
    await stack.seedRound(bookUuid, roundIndex: 1, aiNarrative: '正文');
    await provider.sync();
    final writesAfterFirst = remote.writeCount;

    final ok = await provider.sync();

    expect(ok, isTrue);
    expect(provider.dataSyncState, SyncState.success);
    expect(remote.writeCount, writesAfterFirst, reason: '内容一致不该再上传');
  });

  test('数据面修剪份数取自云端 sync_config.json（不是内存默认值）', () async {
    final bookUuid = await stack.seedBook();
    await stack.seedRound(bookUuid, roundIndex: 1, aiNarrative: '一');
    remote.put(SyncConfig.remoteFileName, utf8.encode('{"keepVersions":2}'));

    await provider.sync();
    for (var i = 2; i <= 4; i++) {
      await stack.seedRound(bookUuid, roundIndex: i, aiNarrative: '第 $i 轮');
      await provider.sync();
    }

    final names = remote.files.keys.toSet();
    expect(names, contains('narrbook_${bookUuid}_shot-g3.db'));
    expect(names, contains('narrbook_${bookUuid}_shot-g4.db'));
    expect(
      names,
      isNot(contains('narrbook_${bookUuid}_shot-g2.db')),
      reason: '按云端 keep=2 修剪，不能退回内存默认值',
    );
    expect(names, isNot(contains('narrbook_${bookUuid}_shot-g1.db')));
  });

  test('读不到 sync_config.json：本轮不修剪（宁可多留，绝不误删）', () async {
    final bookUuid = await stack.seedBook();
    await stack.seedRound(bookUuid, roundIndex: 1, aiNarrative: '一');
    remote.put(SyncConfig.remoteFileName, utf8.encode('{"keepVersions":1}'));
    remote.failReadsFor.add(SyncConfig.remoteFileName);

    await provider.sync();
    for (var i = 2; i <= 3; i++) {
      await stack.seedRound(bookUuid, roundIndex: i, aiNarrative: '第 $i 轮');
      await provider.sync();
    }

    expect(remote.files.keys, contains('narrbook_${bookUuid}_shot-g1.db'));
    expect(remote.files.keys, contains('narrbook_${bookUuid}_shot-g2.db'));
    expect(remote.files.keys, contains('narrbook_${bookUuid}_shot-g3.db'));

    // 恢复正常后再推一代：按云端 keep=1 把更旧的代清掉。
    remote.failReadsFor.clear();
    await stack.seedRound(bookUuid, roundIndex: 4, aiNarrative: '第 4 轮');
    await provider.sync();
    expect(remote.files.keys, contains('narrbook_${bookUuid}_shot-g4.db'));
    expect(
      remote.files.keys,
      isNot(contains('narrbook_${bookUuid}_shot-g3.db')),
    );
  });

  test('云端前进、本地未改：拉取覆盖本地，之后 store 能懒重开', () async {
    await stack.seedBook(uuid: 'b-local', title: '本地书');
    await provider.sync();

    final other = await putRemoteLibraryFromOtherDevice(
      title: '云端书',
      generation: 2,
    );
    addTearDown(other.dispose);
    final remoteBytes = await File(other.paths.libraryDbPath).readAsBytes();

    var restoredCalls = 0;
    provider.onDataRestored = () async => restoredCalls++;

    final ok = await provider.sync();

    expect(ok, isTrue);
    expect(provider.dataSyncState, SyncState.success);
    expect(restoredCalls, 1, reason: '拉取后应通知上层重载界面');

    // 文件被整份替换。
    expect(await File(stack.paths.libraryDbPath).readAsBytes(), remoteBytes);

    // `_closeForReplace` 关掉了连接，这里验证"下一次读取会自动重开"。
    final rows = await stack.stores.library.books();
    expect(rows.map((b) => b.title), contains('云端书'));
    expect(rows.map((b) => b.title), isNot(contains('本地书')));
  });

  test('两边都改：同步后 unresolvedConflicts 留下待裁决项，本地文件不动', () async {
    await stack.seedBook(uuid: 'b-local', title: '本地书');
    await provider.sync();

    // 本地又建了一本 → library 摘要变了。
    await stack.seedBook(uuid: 'b-local2', title: '本地新书');
    // 云端同时前进到第 2 代（内容不同）。
    final other = await putRemoteLibraryFromOtherDevice(
      title: '云端书',
      generation: 2,
    );
    addTearDown(other.dispose);

    await provider.sync();

    expect(provider.dataSyncState, SyncState.success, reason: '冲突不算单元级失败');
    expect(provider.unresolvedConflicts, isNotEmpty);
    final conflict = provider.unresolvedConflicts.firstWhere(
      (plan) => plan.unit == BackupUnit.library,
    );
    expect(conflict.action, BackupAction.conflict);

    // 待裁决期间本地文件不动。
    final rows = await stack.stores.library.books();
    expect(rows.map((b) => b.title), contains('本地书'));
    expect(rows.map((b) => b.title), isNot(contains('云端书')));
  });

  test('resolveConflict(local)：把本地推成新的一代', () async {
    final bookUuid = await stack.seedBook(uuid: 'b1', title: '本地书');
    await stack.seedRound(bookUuid, roundIndex: 1, aiNarrative: '本地正文');
    await provider.sync();

    // 本地再写一轮：内容真的变了，runner 重新决策时才会推。
    await stack.seedRound(bookUuid, roundIndex: 2, aiNarrative: '又一轮');
    // 云端也前进到第 2 代（这次只断言代数，摘要不需要与本地对得上）。
    final unit0 = BackupUnit.book(bookUuid);
    remote.put(
      unit0.manifestName,
      BackupManifest.build(
        unit: unit0,
        generation: 2,
        digest: 'remote-digest',
        deviceId: 'other-device',
      ).encode(),
    );

    // 造一个书单元的冲突计划（本地改了、云端也前进）。
    final unit = BackupUnit.book(bookUuid);
    final plan = BackupPlanner.plan(
      unit: unit,
      localDigest: 'changed-local',
      base: const BackupBase(generation: 1, baseDigest: 'old'),
      remote: BackupManifest.build(
        unit: unit,
        generation: 2,
        digest: 'changed-remote',
        deviceId: 'other-device',
      ),
    );
    expect(plan.action, BackupAction.conflict);

    final error = await provider.resolveConflict(
      plan,
      BackupConflictChoice.local,
    );

    expect(error, isNull);
    expect(
      remote.files.containsKey('narrbook_b1_shot-g3.db'),
      isTrue,
      reason: '取两边较大代数 + 1',
    );
  });

  test('resolveConflict(remote)：用云端快照整份替换本地，并懒重开', () async {
    final bookUuid = await stack.seedBook(uuid: 'b1', title: '本地书');
    await stack.seedRound(bookUuid, roundIndex: 1, aiNarrative: '本地正文');
    await provider.sync();

    // 云端那份是同一书 uuid 的另一个版本（这里用"空书"，内容明显不同）。
    final other = await TestStack.create(prefix: 'sync_e2e_book_');
    await other.seedBook(uuid: bookUuid, title: '云端书');
    final otherPath = '${other.paths.booksDir}/narrbook_$bookUuid.db';
    final otherBytes = await File(otherPath).readAsBytes();
    addTearDown(other.dispose);
    remote.put('narrbook_${bookUuid}_shot-g2.db', otherBytes);

    final unit = BackupUnit.book(bookUuid);
    final plan = BackupPlanner.plan(
      unit: unit,
      localDigest: 'changed-local',
      base: const BackupBase(generation: 1, baseDigest: 'old'),
      remote: BackupManifest.build(
        unit: unit,
        generation: 2,
        digest: 'changed-remote',
        deviceId: 'other-device',
      ),
    );

    var restoredCalls = 0;
    provider.onDataRestored = () async => restoredCalls++;

    final error = await provider.resolveConflict(
      plan,
      BackupConflictChoice.remote,
    );

    expect(error, isNull);
    expect(restoredCalls, 1);
    expect(
      await File('${stack.paths.booksDir}/narrbook_$bookUuid.db').readAsBytes(),
      otherBytes,
    );

    // 书库连接被关过后，再读要能自动重开。
    final chain = await stack.repos.rounds.loadChain(bookUuid);
    expect(chain.rounds, isEmpty, reason: '替换成了云端那份（没有轮次）');
    final loaded = await stack.repos.books.loadBook(bookUuid);
    expect(loaded?.title, '云端书');
  });

  test('删除书籍后同步：云端只留最新一代，library 墓碑保留', () async {
    final bookUuid = await stack.seedBook(uuid: 'b1', title: '书A');
    await provider.sync();
    expect(remote.files.keys, contains('narrbook_b1_shot-g1.db'));

    await stack.seedRound(bookUuid, roundIndex: 2, aiNarrative: '第二轮');
    await provider.sync();
    expect(remote.files.keys, contains('narrbook_b1_shot-g2.db'));

    final phases = <SyncPhase>{};
    void listener() {
      final progress = provider.dataProgress;
      if (progress != null) phases.add(progress.phase);
    }

    await stack.repos.books.deleteBook(bookUuid);
    provider.addListener(listener);
    final ok = await provider.sync();
    provider.removeListener(listener);

    expect(ok, isTrue);
    expect(provider.dataError, isNull);
    expect(phases, contains(SyncPhase.retainDeletedBooks));
    expect(remote.files.keys.where((name) => name.contains(bookUuid)).toSet(), {
      'manifest_narrbook_b1.json',
      'narrbook_b1_shot-g2.db',
    }, reason: '只剩最新一代快照 + 指向它的清单');
    expect(await stack.stores.books.exists(bookUuid), isFalse);
    final tombstone = (await stack.stores.library.book(bookUuid))!;
    expect(tombstone.isDeleted, isTrue);
    expect(tombstone.deletedRoundIndex, 2);
    expect(
      await stack.stores.sync.unit('book:$bookUuid'),
      isNotNull,
      reason: '保留同步基线，方便还原后继续同步',
    );
    expect(
      remote.files.keys,
      contains('narrchat_library_shot-g2.db'),
      reason: '墓碑随 library 新代推到云端',
    );
  });

  test('拉到另一台设备的墓碑：本机清掉，云端整理成只剩最新一代', () async {
    final bookUuid = await stack.seedBook(uuid: 'b1', title: '本地书');
    await provider.sync();
    expect(remote.files.keys, contains('narrbook_b1_shot-g1.db'));

    // 另一台设备把同一本书删掉，并推上带墓碑的 library 第 2 代。
    final other = await TestStack.create(prefix: 'sync_e2e_tomb_');
    addTearDown(other.dispose);
    await other.seedBook(uuid: bookUuid, title: '本地书');
    await other.repos.books.deleteBook(bookUuid);
    final libraryBytes = await File(other.paths.libraryDbPath).readAsBytes();
    remote.put(BackupUnit.library.snapshotName(2), libraryBytes);
    remote.put(
      BackupUnit.library.manifestName,
      BackupManifest.build(
        unit: BackupUnit.library,
        generation: 2,
        digest: await digestOfLibrary(other.paths.libraryDbPath),
        deviceId: 'other-device',
      ).encode(),
    );
    // 云端还留着一代旧快照（另一台设备之前推的）。
    remote.put('narrbook_${bookUuid}_shot-g2.db', const [1, 2, 3]);

    final ok = await provider.sync();

    expect(ok, isTrue);
    expect(provider.dataError, isNull);
    expect(await stack.stores.books.exists(bookUuid), isFalse);
    expect((await stack.stores.library.book(bookUuid))!.isDeleted, isTrue);
    expect(
      remote.files.keys,
      contains('narrbook_${bookUuid}_shot-g2.db'),
      reason: '拉到墓碑后，云端最新一代要留给回收站',
    );
    expect(
      remote.files.keys.any(
        (name) => name == 'narrbook_${bookUuid}_shot-g3.db',
      ),
      isFalse,
      reason: '不能把删掉的书推回去',
    );
    expect(await stack.stores.sync.unit('book:$bookUuid'), isNotNull);
  });

  test('retainDeletedBookBackup：立即整理云端，只留最新一代', () async {
    final bookUuid = await stack.seedBook(uuid: 'b1', title: '书A');
    await provider.sync();
    await stack.seedRound(bookUuid, roundIndex: 3, aiNarrative: '正文');
    await provider.sync();
    expect(remote.files.keys, contains('narrbook_b1_shot-g2.db'));
    await stack.repos.books.deleteBook(bookUuid);

    final error = await provider.retainDeletedBookBackup(bookUuid);

    expect(error, isNull);
    expect(remote.files.keys, contains('narrbook_b1_shot-g2.db'));
    expect(remote.files.keys, isNot(contains('narrbook_b1_shot-g1.db')));
    expect(remote.files.keys, contains('manifest_narrbook_b1.json'));
    expect(await stack.stores.sync.unit('book:$bookUuid'), isNotNull);
  });

  test('purgeDeletedBookBackup：彻底删云端书单元，不动 library / mods', () async {
    final bookUuid = await stack.seedBook(uuid: 'b1', title: '书A');
    await provider.sync();
    expect(remote.files.keys, contains('manifest_narrbook_b1.json'));

    final error = await provider.purgeDeletedBookBackup(bookUuid);

    expect(error, isNull);
    expect(remote.files.keys.any((name) => name.contains(bookUuid)), isFalse);
    expect(await stack.stores.sync.unit('book:$bookUuid'), isNull);
    expect(remote.files.keys, contains('narrchat_library_shot-g1.db'));
    expect(remote.files.keys, contains('manifest_narrchat_library.json'));
  });

  test('restoreDeletedBook：下载保留的一代，清墓碑并让书重新回到列表', () async {
    final bookUuid = await stack.seedBook(uuid: 'b1', title: '旧名');
    // 另一台设备有同 uuid 的书，作为云端快照来源。
    final other = await TestStack.create(prefix: 'sync_e2e_restore_');
    addTearDown(other.dispose);
    await other.seedBook(uuid: bookUuid, title: '云端名');
    final snapshotName = 'narrbook_${bookUuid}_shot-g1.db';
    remote.put(
      snapshotName,
      await File('${other.paths.booksDir}/narrbook_$bookUuid.db').readAsBytes(),
    );
    await stack.repos.books.deleteBook(bookUuid);
    expect(await stack.repos.books.listBooks(), isEmpty);

    final entry = BackupCatalog.build(
      files: [WebDavFile(name: snapshotName)],
      bookTitles: {bookUuid: '旧名'},
      deletedBooks: {
        bookUuid: BackupDeletedBook(
          deletedAt: DateTime.utc(2026, 11, 7),
          roundIndex: 1,
        ),
      },
    ).single;
    provider.debugSetBackups(
      [WebDavFile(name: snapshotName)],
      bookTitles: {bookUuid: '旧名'},
      deletedBooks: {
        bookUuid: BackupDeletedBook(
          deletedAt: DateTime.utc(2026, 11, 7),
          roundIndex: 1,
        ),
      },
    );

    final error = await provider.restoreDeletedBook(entry);

    expect(error, isNull);
    expect((await stack.stores.library.book(bookUuid))!.isDeleted, isFalse);
    expect(
      (await stack.stores.library.book(bookUuid))!.title,
      '云端名',
      reason: '目录副本要跟快照里的书名对齐',
    );
    expect(await stack.stores.books.exists(bookUuid), isTrue);
    final books = await stack.repos.books.listBooks();
    expect(books.single.uuid, bookUuid);
    expect(books.single.title, '云端名');
    expect(provider.deletedBackupUnits, isEmpty, reason: '已从回收站移除');
    expect(
      provider.backupUnits
          .singleWhere((item) => item.unit.refUuid == bookUuid)
          .bookTitle,
      '云端名',
      reason: '还原后面板立即显示新书名',
    );
  });

  test('permanentlyDeleteDeletedBook：删云端最后一份，保留墓碑', () async {
    final bookUuid = await stack.seedBook(uuid: 'b1', title: '书A');
    await provider.sync();
    await stack.repos.books.deleteBook(bookUuid);
    final snapshotName = 'narrbook_${bookUuid}_shot-g1.db';
    final deletedBooks = {
      bookUuid: BackupDeletedBook(
        deletedAt: DateTime.utc(2026, 11, 7),
        roundIndex: 0,
      ),
    };
    provider.debugSetBackups(
      [WebDavFile(name: snapshotName)],
      bookTitles: {bookUuid: '书A'},
      deletedBooks: deletedBooks,
    );
    final entry = provider.deletedBackupUnits.single;

    final error = await provider.permanentlyDeleteDeletedBook(entry);

    expect(error, isNull);
    expect(remote.files.keys.any((name) => name.contains(bookUuid)), isFalse);
    expect(await stack.stores.sync.unit('book:$bookUuid'), isNull);
    expect(
      (await stack.stores.library.book(bookUuid))!.isDeleted,
      isTrue,
      reason: '彻底删除只删云端备份，墓碑保留',
    );
    expect(provider.deletedBackupUnits, isEmpty);
  });
}
