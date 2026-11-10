import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/cloud_backup/backup_manifest.dart';
import 'package:narrchat/services/cloud_backup/backup_pk.dart';
import 'package:narrchat/services/cloud_backup/backup_planner.dart';
import 'package:narrchat/services/cloud_backup/backup_preview.dart';
import 'package:narrchat/services/cloud_backup/backup_remote.dart';
import 'package:narrchat/services/cloud_backup/backup_unit.dart';
import 'package:narrchat/services/sync/sync_conflict.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/backup_fakes.dart';
import 'helpers/fakes.dart';

/// 冲突页预览读取器：本地走 store、云端临时下载快照只读打开。
void main() {
  late TestStack stack;
  late FakeBackupRemote remote;
  late BackupPreviewReader reader;

  setUp(() async {
    stack = await TestStack.create();
    remote = FakeBackupRemote();
    reader = BackupPreviewReader(
      remoteFactory: () => remote,
      locator: BackupLocator(userDataDir: stack.paths.userDataDir),
      books: stack.stores.books,
      mods: stack.stores.mods,
      library: stack.stores.library,
    );
  });

  tearDown(() async {
    await stack.dispose();
  });

  /// 造一个「冲突中的单元」，清单指向云端第 [generation] 代。
  SyncConflict conflictOf(BackupUnit unit, {int generation = 2}) {
    final manifest = BackupManifest(
      unitKey: unit.unitKey,
      kind: unit.kind,
      refUuid: unit.refUuid,
      generation: generation,
      digest: 'remote-digest',
      snapshotName: unit.snapshotName(generation),
      savedAt: '2026-01-01T00:00:00.000Z',
      deviceId: 'other-device',
      contentUpdatedAt: '2026-01-01T00:00:00.000Z',
    );
    final plan = BackupPlanner.plan(
      unit: unit,
      localDigest: 'local-digest',
      base: const BackupBase(generation: 1, baseDigest: 'base-digest'),
      remote: manifest,
    );
    return SyncConflict(
      unit: unit,
      plan: plan,
      pk: const SyncPkResult.unavailable('测试用'),
      title: '测试单元',
    );
  }

  /// 把另一份文件塞进内存云端，作为该单元的第 2 代快照。
  Future<void> putSnapshot(BackupUnit unit, String sourcePath) async {
    remote.put(unit.snapshotName(2), await File(sourcePath).readAsBytes());
  }

  test('本地书籍预览：设置 / 世界书 / 启用 Mod / 最新一轮取 is_using 那一代', () async {
    final uuid = await stack.seedBook(
      uuid: 'b1',
      title: '本地书',
      category: '奇幻',
      baseSetting: '本地基础设定',
    );
    await stack.seedWorldBookEntry(uuid, keyword: '关键词', content: '内容');
    final modUuid = await stack.seedMod(name: '我的 Mod');
    await stack.repos.mod.setUseModUuids(uuid, [modUuid]);
    await stack.seedRound(uuid, roundIndex: 1, aiNarrative: '第一轮');
    await stack.seedRound(
      uuid,
      roundIndex: 2,
      aiNarrative: '选中的正文',
      userInput: '选中的提问',
    );
    // 同轮的另一代（未选中）用来证明预览取的是 is_using 那一行。
    await stack.seedRound(
      uuid,
      roundIndex: 2,
      aiNarrative: '未选中的正文',
      isUsing: false,
    );

    final preview = await reader.read(
      conflictOf(BackupUnit.book(uuid)),
      SyncPreviewSide.local,
    );

    final book = preview.book!;
    expect(book.title, '本地书');
    expect(book.category, '奇幻');
    expect(book.baseSetting, '本地基础设定');
    expect(book.worldBookCount, 1);
    expect(book.worldBookKeywords, ['关键词']);
    expect(book.modNames, ['我的 Mod']);
    expect(book.roundGenerationCount, 3);
    expect(book.latestRoundIndex, 2);
    expect(book.latestUserInput, '选中的提问');
    expect(book.latestNarrative, '选中的正文');
  });

  test('云端书籍预览：下载快照并读同一套字段', () async {
    final uuid = await stack.seedBook(uuid: 'b1', title: '本地书');
    await stack.seedRound(uuid, roundIndex: 1, aiNarrative: '本地正文');

    final other = await TestStack.create(prefix: 'preview_other_');
    addTearDown(other.dispose);
    await other.seedBook(
      uuid: uuid,
      title: '云端书',
      category: '科幻',
      baseSetting: '云端设定',
    );
    await other.seedRound(uuid, roundIndex: 1, aiNarrative: '云端正文');
    await other.seedRound(uuid, roundIndex: 2, aiNarrative: '云端第二轮');
    await putSnapshot(BackupUnit.book(uuid), other.paths.bookDbPath(uuid));

    final preview = await reader.read(
      conflictOf(BackupUnit.book(uuid)),
      SyncPreviewSide.remote,
    );

    final book = preview.book!;
    expect(book.title, '云端书');
    expect(book.category, '科幻');
    expect(book.baseSetting, '云端设定');
    expect(book.roundGenerationCount, 2);
    expect(book.latestRoundIndex, 2);
    expect(book.latestNarrative, '云端第二轮');
  });

  test('Mod 库两侧预览：含墓碑标记与两侧条目', () async {
    final alive = await stack.seedMod(name: '本地 Mod');
    final deleted = await stack.seedMod(name: '已删 Mod');
    await stack.repos.mod.deleteMod(deleted);

    final other = await TestStack.create(prefix: 'preview_mods_');
    addTearDown(other.dispose);
    await other.seedMod(name: '云端 Mod');
    await putSnapshot(BackupUnit.mods, other.paths.modsDbPath);

    final local = await reader.read(
      conflictOf(BackupUnit.mods),
      SyncPreviewSide.local,
    );
    final localMods = local.mods!.mods;
    expect(localMods.map((mod) => mod.name), containsAll(['本地 Mod', '已删 Mod']));
    expect(localMods.firstWhere((mod) => mod.uuid == alive).deleted, isFalse);
    expect(localMods.firstWhere((mod) => mod.uuid == deleted).deleted, isTrue);

    final remotePreview = await reader.read(
      conflictOf(BackupUnit.mods),
      SyncPreviewSide.remote,
    );
    expect(remotePreview.mods!.mods.map((mod) => mod.name), ['云端 Mod']);
  });

  test('书架两侧预览：活书 / 已删除分组与删除轮号', () async {
    final aliveUuid = await stack.seedBook(uuid: 'b1', title: '活书');
    final deletedUuid = await stack.seedBook(uuid: 'b2', title: '删掉的书');
    await stack.seedRound(deletedUuid, roundIndex: 1, aiNarrative: '一轮');
    await stack.repos.books.deleteBook(deletedUuid);

    final other = await TestStack.create(prefix: 'preview_lib_');
    addTearDown(other.dispose);
    await other.seedBook(uuid: 'b3', title: '云端活书');
    await other.seedBook(uuid: 'b4', title: '云端删书');
    await other.repos.books.deleteBook('b4');
    await putSnapshot(BackupUnit.library, other.paths.libraryDbPath);

    final local = await reader.read(
      conflictOf(BackupUnit.library),
      SyncPreviewSide.local,
    );
    expect(local.library!.alive.map((book) => book.title), ['活书']);
    expect(local.library!.deleted.map((book) => book.title), ['删掉的书']);
    expect(local.library!.deleted.single.deletedRoundIndex, 1);
    expect(local.library!.alive.single.bookUuid, aliveUuid);

    final remotePreview = await reader.read(
      conflictOf(BackupUnit.library),
      SyncPreviewSide.remote,
    );
    expect(remotePreview.library!.alive.map((book) => book.title), ['云端活书']);
    expect(remotePreview.library!.deleted.map((book) => book.title), ['云端删书']);
  });

  test('云端快照不存在：抛 BackupRemoteException', () async {
    await stack.seedBook(uuid: 'b1', title: '本地书');
    await expectLater(
      reader.read(conflictOf(BackupUnit.book('b1')), SyncPreviewSide.remote),
      throwsA(isA<BackupRemoteException>()),
    );
  });

  test('云端预览：临时文件读完即删、连接按需关闭、绝不写云端', () async {
    final uuid = await stack.seedBook(uuid: 'b1', title: '本地书');
    final other = await TestStack.create(prefix: 'preview_tmp_');
    addTearDown(other.dispose);
    await other.seedBook(uuid: uuid, title: '云端书');
    await putSnapshot(BackupUnit.book(uuid), other.paths.bookDbPath(uuid));

    final opened = <String>[];
    final trackingReader = BackupPreviewReader(
      remoteFactory: () => remote,
      locator: BackupLocator(userDataDir: stack.paths.userDataDir),
      books: stack.stores.books,
      mods: stack.stores.mods,
      library: stack.stores.library,
      openDatabase: (path) async {
        opened.add(path);
        return databaseFactory.openDatabase(
          path,
          options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
        );
      },
    );

    await trackingReader.read(
      conflictOf(BackupUnit.book(uuid)),
      SyncPreviewSide.remote,
    );

    expect(opened, hasLength(1));
    expect(opened.single, contains('narrchat_preview_'));
    expect(await File(opened.single).exists(), isFalse, reason: '读完立刻删临时快照');
    expect(remote.closed, isTrue);
    expect(remote.writeCount, 0);
  });
}
