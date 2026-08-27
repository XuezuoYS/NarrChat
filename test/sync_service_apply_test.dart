import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/database/book_dao.dart';
import 'package:narrchat/database/database_helper.dart';
import 'package:narrchat/database/sync_dao.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/services/sync/sync_local_snapshot.dart';
import 'package:narrchat/services/sync/sync_models.dart';
import 'package:narrchat/services/sync/sync_service.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/fakes.dart';

/// `SyncService` 真库 apply（删除传播）：远端删除一本书 → 同步落地为本地软删，
/// 默认列表立即隐藏、`includeDeleted` 仍可见并有删除标记。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory dir;
  late String dbPath;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('sync_apply_test_');
    dbPath = p.join(dir.path, 'narrchat.db');
    DatabaseHelper.debugDatabasePathOverride = dbPath;
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

  test('远端删除的书 → 本地软删并落地（uuid 匹配）', () async {
    final bookDao = BookDao();
    final bookId = await bookDao.insertBook(const Book(title: '书A', category: '玄幻'));

    // 本地部件指纹（用于共基比对，使本地未改 → deletedOnRemote）。
    final localSnap = await SyncLocalSnapshot.build(await DatabaseHelper.instance.database);
    final record = localSnap.books.values.single;
    final parts = record.parts;
    final uuid = record.uuid;

    final store = MemorySyncStore()
      ..manifest = SyncManifest(
        generation: 2,
        lastWriterDeviceId: 'dev-2',
        knownDevices: ['dev-2'],
        books: [
          SyncBookEntry(
            uuid: uuid,
            title: '书A',
            deleted: true,
            settingsFp: parts.settingsFp,
            settingsUpdatedAt: 100,
            roundsFp: parts.roundsFp,
            roundsUpdatedAt: 100,
            worldBookFp: parts.worldBookFp,
            bookModsFp: parts.bookModsFp,
          ),
        ],
      );
    final state = MemorySyncStateStore()
      ..bookBases[uuid] = SyncBookBase(
        uuid: uuid,
        title: '书A',
        settingsFp: parts.settingsFp,
        roundsFp: parts.roundsFp,
        worldbookFp: parts.worldBookFp,
        bookmodsFp: parts.bookModsFp,
      );

    final svc = SyncService(
      store: store,
      stateStore: state,
      deviceId: 'dev-1',
      buildLocalSnapshot: () async =>
          SyncLocalSnapshot.build(await DatabaseHelper.instance.database),
      buildSnapshotBytes: () async => Uint8List.fromList([1, 2, 3]),
      referencedImages: () async => const [],
      localImages: () async => const [],
      readLocalImage: (_) async => null,
      writeLocalImage: (_, _) async {},
      keepVersions: 5,
      lockRetryDelay: Duration.zero,
      applyRemotePlan: (action) async {
        final dao = BookDao();
        for (final b in await dao.getAllBooks()) {
          if (action.deleteLocalBookUuids.contains(b.uuid) && b.id != null) {
            await dao.softDeleteBook(b.id!);
          }
        }
      },
    );

    final result = await svc.sync();

    expect(result.applied, isTrue);
    expect(result.hasConflict, isFalse);
    expect(result.pushed, isFalse,
        reason: '远端清单已含删除墓碑，本地落地后无需推送/推进代数');
    // 本地软删落地：默认列表隐藏。
    expect(await bookDao.getAllBooks(), isEmpty);
    // includeDeleted 可见且带删除标记。
    final softDeleted = await bookDao.getBookById(bookId, includeDeleted: true);
    expect(softDeleted, isNotNull);
    final row = (await DatabaseHelper.instance.database)
        .query('books', where: 'id = ?', whereArgs: [bookId]);
    expect((await row).first['deleted_at'], isNotNull);
    // manifest 保持当前代（删除墓碑本来就在远端清单中）。
    expect(store.manifest!.generation, 2);
    expect(store.manifest!.books.single.deleted, isTrue);
    // 共基保留（软删书仍在快照中；无 base 反而可能在异常路径被误判"远端独有"拉回）。
    expect(state.bookBases.containsKey(uuid), isTrue);
  });
}
