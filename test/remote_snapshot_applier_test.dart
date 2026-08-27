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
import 'package:narrchat/services/sync/sync_image_planner.dart';
import 'package:narrchat/services/sync/sync_merge_planner.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// [RemoteSnapshotApplier] 真库集成测试：把远端快照里的书籍变更按部件级
/// 决策落地到本地库（整本复制 / 同名书就地合并），用 `sqflite_common_ffi`
/// + 临时库，不发网络。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory dir;
  late String dbPath;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('remote_apply_');
    dbPath = p.join(dir.path, 'local.db');
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

  BookSyncDecision decision(
    String title, {
    String? localUuid,
    String? remoteUuid,
    SyncBookPresence presence = SyncBookPresence.both,
    SyncPartStatus settings = SyncPartStatus.unchanged,
    SyncPartStatus rounds = SyncPartStatus.unchanged,
    SyncPartStatus worldBook = SyncPartStatus.unchanged,
    SyncPartStatus bookMods = SyncPartStatus.unchanged,
  }) {
    return BookSyncDecision(
      localUuid: localUuid,
      remoteUuid: remoteUuid ?? 'remote-uuid-1',
      title: title,
      presence: presence,
      settings: settings,
      rounds: rounds,
      worldBook: worldBook,
      bookMods: bookMods,
    );
  }

  SyncAction action(
    List<String> pullBookUuids, {
    List<String> pullModUuids = const [],
  }) {
    return SyncAction(
      pullBookUuids: pullBookUuids,
      pushBookUuids: const [],
      conflictBookUuids: const [],
      deleteLocalBookUuids: const [],
      deleteRemoteBookUuids: const [],
      pushModUuids: const [],
      pullModUuids: pullModUuids,
      conflictModUuids: const [],
      deleteRemoteModUuids: const [],
      deleteLocalModUuids: const [],
      images: const ImageSyncPlan(
        toUpload: [],
        toPull: [],
        toDeleteCloud: [],
      ),
    );
  }

  test('拉取远端独有书：书/轮次/世界书/用户Mod/书-Mod 全部落库，重复拉取不产生重复', () async {
    final snapshotBytes = await _buildRemoteSnapshot(
      title: '远端书',
      category: '玄幻',
    );

    final plan = SyncMergePlan(
      books: [
        decision(
          '远端书',
          remoteUuid: 'remote-uuid-1',
          presence: SyncBookPresence.remoteOnly,
        ),
      ],
    );
    await const RemoteSnapshotApplier().apply(
      mergePlan: plan,
      action: action(const ['remote-uuid-1']),
      snapshotBytes: snapshotBytes,
    );
    // 再拉一次：同名书不应重复插入（直接整体替换到已存在的书）。
    await const RemoteSnapshotApplier().apply(
      mergePlan: plan,
      action: action(const ['remote-uuid-1']),
      snapshotBytes: snapshotBytes,
    );

    final bookDao = BookDao();
    final books = await bookDao.getAllBooks();
    expect(books.where((b) => b.title == '远端书'), hasLength(1));
    final book = books.firstWhere((b) => b.title == '远端书');
    final bookId = book.id!;
    expect(book.category, '玄幻');
    // 远端 uuid 原样落入本地（跨设备身份自此一致）。
    expect(book.uuid, 'remote-uuid-1');

    final rounds = await RoundDao().getRoundsByBook(bookId);
    expect(rounds, hasLength(1));
    expect(rounds.single.userInput, '你好');
    expect(rounds.single.aiNarrative, '正文');

    final wbs = await WorldBookDao().getEntriesByBook(bookId);
    expect(wbs, hasLength(1));
    expect(wbs.single.keyword, '主角');

    final modDao = ModDao();
    final mods = await modDao.getAllMods();
    expect(mods.where((m) => m.name == '风格'), hasLength(1));

    final configs = await modDao.getBookMods(bookId);
    expect(configs, hasLength(1));
    expect(configs.single.modId, isNotNull);
  });

  test('同名书部件级合并：仅替换 remoteOnly 部件（轮次/信息），不生成重复书', () async {
    // 本地已有书 X：1 轮 + 1 条世界书 + 挂载「风格」Mod。
    final bookDao = BookDao();
    final localBookId = await bookDao.insertBook(
      const Book(title: 'X', category: '旧分类'),
    );
    await RoundDao().insertRound(
      Round(bookId: localBookId, roundIndex: 1, userInput: '本地轮', aiNarrative: '本地正文'),
    );
    await WorldBookDao().insertEntry(
      WorldBookEntry(bookId: localBookId, keyword: '本地词条', content: '本地内容'),
    );
    final modDao = ModDao();
    final localModId = await modDao.insertMod(const Mod(name: '风格'));
    await modDao.replaceBookMods(localBookId, [
      BookModConfig(bookId: localBookId, modId: localModId, sortOrder: 0),
    ]);

    // 远端书 X：分类改为「新分类」，轮次 2 条（第 0 轮 + 1 轮），无世界书。
    final snapshotBytes = await _buildRemoteSnapshot(
      title: 'X',
      category: '新分类',
      rounds: [
        (0, '第零轮输入', '第零轮正文'),
        (1, '新轮输入', '新轮正文'),
      ],
      withWorldBooks: false,
    );

    // 决策：info / rounds 远端更新；worldBook / bookMods 未变（本地保留）。
    final plan = SyncMergePlan(
      books: [
        decision(
          'X',
          remoteUuid: 'remote-uuid-1',
          presence: SyncBookPresence.both,
          settings: SyncPartStatus.remoteOnly,
          rounds: SyncPartStatus.remoteOnly,
        ),
      ],
    );
    await const RemoteSnapshotApplier().apply(
      mergePlan: plan,
      action: action(const ['remote-uuid-1']),
      snapshotBytes: snapshotBytes,
    );

    final books = await bookDao.getAllBooks();
    expect(books.where((b) => b.title == 'X'), hasLength(1), reason: '不得重复插入同名书');
    final book = books.firstWhere((b) => b.title == 'X');
    expect(book.id, localBookId);
    expect(book.category, '新分类', reason: 'info remoteOnly → 采用远端设置');
    expect(book.baseSetting, '');

    // 轮次：本地旧轮被远端轮次整体替换。
    final rounds = await RoundDao().getRoundsByBook(localBookId);
    expect(rounds.map((r) => r.userInput).toList(), ['第零轮输入', '新轮输入']);

    // 世界书未变：本地词条保留。
    final wbs = await WorldBookDao().getEntriesByBook(localBookId);
    expect(wbs.single.keyword, '本地词条');

    // 书-Mod 未变：仍引用原本地 Mod。
    final configs = await modDao.getBookMods(localBookId);
    expect(configs.single.modId, localModId);
    expect((await modDao.getAllMods()).where((m) => m.name == '风格'), hasLength(1));
  });

  test('远端书引用同一用户 Mod：按 uuid 复用本地 Mod，不重复插入', () async {
    // 本地已有「风格」Mod（但书 X 尚未挂载）。
    final modDao = ModDao();
    final localModId = await modDao.insertMod(const Mod(name: '风格'));

    final snapshotBytes = await _buildRemoteSnapshot(
      title: '远端书',
      category: '玄幻',
    );
    final plan = SyncMergePlan(
      books: [
        decision(
          '远端书',
          remoteUuid: 'remote-uuid-1',
          presence: SyncBookPresence.remoteOnly,
        ),
      ],
    );
    await const RemoteSnapshotApplier().apply(
      mergePlan: plan,
      action: action(const ['remote-uuid-1']),
      snapshotBytes: snapshotBytes,
    );

    // 「风格」只有本地这一份；新书挂载到本地 Mod。
    expect((await modDao.getAllMods()).where((m) => m.name == '风格'), hasLength(1));
    final book = (await BookDao().getAllBooks()).firstWhere((b) => b.title == '远端书');
    final configs = await modDao.getBookMods(book.id!);
    expect(configs.single.modId, localModId);
  });

  test('独立 Mod 拉取：未被任何书引用的远端 Mod 新增到本地', () async {
    final snapshotBytes = await _buildRemoteSnapshot(
      extraMods: [
        {
          'uuid': 'remote-mod-uuid-x',
          'name': '独立Mod',
          'description': '远端独立描述',
          'pre_prompt': 'pre',
          'created_at': '2026-01-01T00:00:00.000',
          'updated_at': '2026-01-02T00:00:00.000',
        },
      ],
    );

    final nullPlan = SyncMergePlan(books: const []);
    await const RemoteSnapshotApplier().apply(
      mergePlan: nullPlan,
      action: action(const [], pullModUuids: const ['remote-mod-uuid-x']),
      snapshotBytes: snapshotBytes,
    );

    final mods = await ModDao().getAllMods();
    final mod = mods.firstWhere((m) => m.name == '独立Mod');
    expect(mod.description, '远端独立描述');
    expect(mod.prePrompt, 'pre');
    expect(mod.uuid, 'remote-mod-uuid-x');
    // 时间戳按远端原样保留（指纹跨设备稳定）。
    expect(mod.createdAt?.toIso8601String(), '2026-01-01T00:00:00.000');
    expect(mod.updatedAt?.toIso8601String(), '2026-01-02T00:00:00.000');
    expect(mods.where((m) => m.name == '独立Mod'), hasLength(1));
  });

  test('独立 Mod 拉取：本地同名 Mod 整体采用远端内容（含时间戳与 uuid）', () async {
    final modDao = ModDao();
    await modDao.insertMod(
      const Mod(name: '风格', description: '本地旧描述', prePrompt: '旧'),
    );
    final snapshotBytes = await _buildRemoteSnapshot(
      // 远端仅包含该「风格」独立 Mod（无同名重复行）。
      withReferencedMod: false,
      extraMods: [
        {
          'uuid': 'remote-mod-uuid-style',
          'name': '风格',
          'description': '远端新描述',
          'pre_prompt': '新',
          'world_book': '新世界书',
          'created_at': '2026-02-01T08:00:00.000',
          'updated_at': '2026-02-02T09:00:00.000',
        },
      ],
    );

    await const RemoteSnapshotApplier().apply(
      mergePlan: SyncMergePlan(books: const []),
      action: action(const [], pullModUuids: const ['remote-mod-uuid-style']),
      snapshotBytes: snapshotBytes,
    );

    final mods = await modDao.getAllMods();
    expect(mods.where((m) => m.name == '风格'), hasLength(1));
    final mod = mods.single;
    expect(mod.description, '远端新描述', reason: '采用远端内容');
    expect(mod.prePrompt, '新');
    expect(mod.worldBookEntries.single.content, '新世界书');
    // uuid 与时间戳与远端一致 → 指纹与远端相同，不会来回推送。
    expect(mod.uuid, 'remote-mod-uuid-style');
    expect(mod.createdAt?.toIso8601String(), '2026-02-01T08:00:00.000');
    expect(mod.updatedAt?.toIso8601String(), '2026-02-02T09:00:00.000');
  });

  test('设置部件 remoteOnly → 设置列整体落地且本地 uuid 收敛为远端 uuid', () async {
    // 本地已有同名书（自己的 uuid、旧后置词）。
    final bookDao = BookDao();
    final localBookId = await bookDao.insertBook(
      const Book(title: 'X', category: '旧分类', globalPostPrompt: '旧后置词'),
    );
    // 远端书 X：新后置词 + 远端 uuid（回退匹配按书名命中 → 就地合并 + 身份收敛）。
    final snapshotBytes = await _buildRemoteSnapshot(
      title: 'X',
      category: '新分类',
      globalPostPrompt: '新后置词',
    );

    final plan = SyncMergePlan(
      books: [
        decision(
          'X',
          remoteUuid: 'remote-uuid-1',
          presence: SyncBookPresence.both,
          settings: SyncPartStatus.remoteOnly,
        ),
      ],
    );
    await const RemoteSnapshotApplier().apply(
      mergePlan: plan,
      action: action(const ['remote-uuid-1']),
      snapshotBytes: snapshotBytes,
    );

    final books = await bookDao.getAllBooks();
    expect(books.where((b) => b.title == 'X'), hasLength(1));
    final book = books.firstWhere((b) => b.title == 'X');
    expect(book.id, localBookId, reason: '就地合并，不重复插入');
    expect(book.globalPostPrompt, '新后置词', reason: '设置部件整体采用远端');
    expect(book.category, '新分类', reason: '设置部件整体采用远端');
    expect(book.uuid, 'remote-uuid-1', reason: '回退匹配命中 → 身份收敛为远端 uuid');
  });
}

/// 生成一个带单本书（可指定轮次 / 世界书 / 额外独立 Mod）的远端快照字节（同应用 schema）。
Future<Uint8List> _buildRemoteSnapshot({
  String title = '远端书',
  String category = '玄幻',
  String globalPostPrompt = '',
  List<(int, String, String)> rounds = const [(1, '你好', '正文')],
  bool withWorldBooks = true,
  List<Map<String, Object?>> extraMods = const [],
  bool withReferencedMod = true,
}) async {
  final dir = Directory.systemTemp.createTempSync('remote_snap_');
  final path = p.join(dir.path, 'snapshot.db');
  final db = await databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  await db.execute('''
    CREATE TABLE books (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      uuid TEXT NOT NULL DEFAULT '',
      title TEXT NOT NULL,
      category TEXT DEFAULT '',
      base_setting TEXT DEFAULT '',
      writing_requirements TEXT DEFAULT '',
      writing_style TEXT DEFAULT '',
      global_pre_prompt TEXT DEFAULT '',
      global_post_prompt TEXT DEFAULT '',
      history_rounds INTEGER NOT NULL DEFAULT 1,
      role_hierarchy TEXT DEFAULT '',
      role_hierarchy_detail TEXT DEFAULT '',
      failed_user_input TEXT DEFAULT '',
      failed_error_message TEXT DEFAULT '',
      failed_user_images TEXT NOT NULL DEFAULT '[]',
      settings_updated_at INTEGER NOT NULL DEFAULT 0,
      rounds_updated_at INTEGER NOT NULL DEFAULT 0,
      deleted_at INTEGER
    )
  ''');
  await db.execute('''
    CREATE TABLE rounds (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      book_id INTEGER NOT NULL,
      round_index INTEGER NOT NULL,
      user_input TEXT DEFAULT '',
      ai_narrative TEXT DEFAULT '',
      world_state TEXT DEFAULT '',
      character_state TEXT DEFAULT '',
      memory_summary TEXT DEFAULT '',
      current_time TEXT DEFAULT '',
      recommended_action TEXT DEFAULT '',
      tokens_in INTEGER NOT NULL DEFAULT 0,
      tokens_out INTEGER NOT NULL DEFAULT 0,
      model_name TEXT DEFAULT '',
      user_images TEXT NOT NULL DEFAULT '[]',
      ai_images TEXT NOT NULL DEFAULT '[]',
      created_at DATETIME,
      updated_at INTEGER NOT NULL DEFAULT 0
    )
  ''');
  await db.execute('''
    CREATE TABLE world_book_entries (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      book_id INTEGER NOT NULL,
      keyword TEXT NOT NULL,
      content TEXT DEFAULT '',
      is_active INTEGER NOT NULL DEFAULT 1,
      created_at DATETIME,
      updated_at INTEGER NOT NULL DEFAULT 0
    )
  ''');
  await db.execute('''
    CREATE TABLE mods (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      uuid TEXT NOT NULL DEFAULT '',
      name TEXT NOT NULL,
      description TEXT DEFAULT '',
      pre_prompt TEXT DEFAULT '',
      post_prompt TEXT DEFAULT '',
      system_prompt TEXT DEFAULT '',
      world_book TEXT DEFAULT '',
      created_at DATETIME,
      updated_at DATETIME,
      deleted_at INTEGER
    )
  ''');
  await db.execute('''
    CREATE TABLE book_mods (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      book_id INTEGER NOT NULL,
      preset_key TEXT,
      mod_id INTEGER,
      sort_order INTEGER NOT NULL DEFAULT 0,
      is_enabled INTEGER NOT NULL DEFAULT 1
    )
  ''');

  await db.insert('books', {
    'uuid': 'remote-uuid-1',
    'title': title,
    'category': category,
    'global_post_prompt': globalPostPrompt,
    'settings_updated_at': 100,
    'rounds_updated_at': 200,
  });
  for (final (index, input, narrative) in rounds) {
    await db.insert('rounds', {
      'book_id': 1,
      'round_index': index,
      'user_input': input,
      'ai_narrative': narrative,
      'tokens_in': 1,
      'tokens_out': 2,
      'user_images': '[]',
      'ai_images': '[]',
    });
  }
  if (withWorldBooks) {
    await db.insert('world_book_entries', {
      'book_id': 1,
      'keyword': '主角',
      'content': '设定',
      'is_active': 1,
    });
  }
  if (withReferencedMod) {
    await db.insert('mods', {
      'uuid': 'remote-mod-uuid-1',
      'name': '风格',
    });
  }
  for (final extra in extraMods) {
    await db.insert('mods', extra);
  }
  await db.insert('book_mods', {
    'book_id': 1,
    'mod_id': 1,
    'sort_order': 0,
    'is_enabled': 1,
  });

  final bytes = await File(path).readAsBytes();
  await db.close();
  try {
    dir.deleteSync(recursive: true);
  } catch (_) {
    // 忽略清理失败。
  }
  return bytes;
}
