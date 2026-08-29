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
import 'package:narrchat/services/sync/sync_merge_planner.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 远端快照里那本书的主键：v16 起 uuid 即唯一身份，两侧同一 uuid = 同一实体。
const String kRemoteBookUuid = 'remote-uuid-1';

/// 远端快照里被书引用的用户 Mod 主键。
const String kRemoteModUuid = 'remote-mod-uuid-1';

/// [RemoteSnapshotApplier] 真库集成测试：把远端快照里的书籍 / Mod 变更按部件级
/// 决策落地到本地库（本地无该 uuid → 整本复制；本地已有同 uuid → 部件级就地
/// 合并），用 `sqflite_common_ffi` + 临时库，不发网络。
///
/// 定位**只按 uuid**（`books.uuid` / `mods.uuid` / 子表 `book_uuid` /
/// `mod_uuid`）：不做标题/名称回退匹配，也不存在「采用远端 uuid」的身份迁移步骤
/// ——同一主键本就是一本书；同名而 uuid 不同就是两本独立的书、两个独立 Mod。
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
    String? remoteUuid = kRemoteBookUuid,
    SyncBookPresence presence = SyncBookPresence.both,
    SyncPartStatus settings = SyncPartStatus.unchanged,
    SyncPartStatus rounds = SyncPartStatus.unchanged,
    SyncPartStatus worldBook = SyncPartStatus.unchanged,
    SyncPartStatus bookMods = SyncPartStatus.unchanged,
  }) {
    return BookSyncDecision(
      localUuid: localUuid,
      remoteUuid: remoteUuid,
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
          remoteUuid: kRemoteBookUuid,
          presence: SyncBookPresence.remoteOnly,
        ),
      ],
    );
    const applier = RemoteSnapshotApplier();
    await applier.apply(
      mergePlan: plan,
      action: action(const [kRemoteBookUuid]),
      snapshotBytes: snapshotBytes,
    );
    // 再拉一次：本地已有同一 uuid → 部件整体替换，不应重复插书。
    await applier.apply(
      mergePlan: plan,
      action: action(const [kRemoteBookUuid]),
      snapshotBytes: snapshotBytes,
    );

    final books = await BookDao().getAllBooks();
    expect(books, hasLength(1), reason: 'uuid 即主键：重复拉取不产生第二本');
    final book = books.single;
    // 远端 uuid 原样落入本地（跨设备身份自此一致）。
    expect(book.uuid, kRemoteBookUuid);
    expect(book.title, '远端书');
    expect(book.category, '玄幻');

    final rounds = await RoundDao().getRoundsByBook(book.uuid);
    expect(rounds, hasLength(1));
    expect(rounds.single.userInput, '你好');
    expect(rounds.single.aiNarrative, '正文');
    expect(rounds.single.bookUuid, kRemoteBookUuid, reason: '子表按 book_uuid 归属');

    final wbs = await WorldBookDao().getEntriesByBook(book.uuid);
    expect(wbs, hasLength(1));
    expect(wbs.single.keyword, '主角');

    final modDao = ModDao();
    final mods = await modDao.getAllMods();
    expect(mods, hasLength(1));
    expect(mods.single.name, '风格');
    expect(mods.single.uuid, kRemoteModUuid);

    final configs = await modDao.getBookMods(book.uuid);
    expect(configs, hasLength(1));
    expect(configs.single.bookUuid, kRemoteBookUuid);
    expect(configs.single.modUuid, kRemoteModUuid);
  });

  test('同一 uuid 就地部件级合并：仅替换 remoteOnly 部件（设置/轮次），未改部件保留本地', () async {
    // 本地已有书 X（与远端同一 uuid = 同一本书）：1 轮 + 1 条世界书 + 挂载「风格」Mod。
    final bookDao = BookDao();
    final localBookUuid = await bookDao.insertBook(
      const Book(uuid: kRemoteBookUuid, title: 'X', category: '旧分类'),
    );
    await RoundDao().insertRound(
      Round(
        bookUuid: localBookUuid,
        roundIndex: 1,
        userInput: '本地轮',
        aiNarrative: '本地正文',
      ),
    );
    await WorldBookDao().insertEntry(
      WorldBookEntry(
        bookUuid: localBookUuid,
        keyword: '本地词条',
        content: '本地内容',
      ),
    );
    final modDao = ModDao();
    final localModUuid = await modDao.insertMod(
      const Mod(
        uuid: kRemoteModUuid,
        name: '风格',
        description: '本地描述',
      ),
    );
    await modDao.replaceBookMods(localBookUuid, [
      BookModConfig(
        bookUuid: localBookUuid,
        modUuid: localModUuid,
        sortOrder: 0,
      ),
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

    // 决策：settings / rounds 远端更新；worldBook / bookMods 未变（本地保留）。
    final plan = SyncMergePlan(
      books: [
        decision(
          'X',
          localUuid: localBookUuid,
          remoteUuid: kRemoteBookUuid,
          presence: SyncBookPresence.both,
          settings: SyncPartStatus.remoteOnly,
          rounds: SyncPartStatus.remoteOnly,
        ),
      ],
    );
    await const RemoteSnapshotApplier().apply(
      mergePlan: plan,
      action: action(const [kRemoteBookUuid]),
      snapshotBytes: snapshotBytes,
    );

    final books = await bookDao.getAllBooks();
    expect(books, hasLength(1), reason: '同一 uuid = 同一本书，不得再插一本');
    final book = books.single;
    expect(book.uuid, kRemoteBookUuid);
    expect(book.category, '新分类', reason: 'settings remoteOnly → 采用远端设置');
    expect(book.baseSetting, '');

    // 轮次：本地旧轮被远端轮次整体替换。
    final rounds = await RoundDao().getRoundsByBook(localBookUuid);
    expect(rounds.map((r) => r.userInput).toList(), ['第零轮输入', '新轮输入']);

    // 世界书未变：本地词条保留。
    final wbs = await WorldBookDao().getEntriesByBook(localBookUuid);
    expect(wbs.single.keyword, '本地词条');

    // 书-Mod 未变：仍引用原本地 Mod。
    final configs = await modDao.getBookMods(localBookUuid);
    expect(configs.single.modUuid, localModUuid);
    final mods = await modDao.getAllMods();
    expect(mods.where((m) => m.name == '风格'), hasLength(1));
    final keptMod = await modDao.getModByUuid(localModUuid);
    expect(keptMod!.description, '本地描述', reason: 'bookMods 部件未变 → 不覆盖本地 Mod 行');
  });

  test('远端书引用同一 uuid 的用户 Mod：命中本地行 → 复用并用远端内容整体覆盖', () async {
    // 本地已有同一 uuid 的「风格」Mod（书 X 尚未挂载）。
    final modDao = ModDao();
    final localModUuid = await modDao.insertMod(
      const Mod(uuid: kRemoteModUuid, name: '风格', description: '本地描述'),
    );

    final snapshotBytes = await _buildRemoteSnapshot(
      title: '远端书',
      category: '玄幻',
    );
    final plan = SyncMergePlan(
      books: [
        decision(
          '远端书',
          remoteUuid: kRemoteBookUuid,
          presence: SyncBookPresence.remoteOnly,
        ),
      ],
    );
    await const RemoteSnapshotApplier().apply(
      mergePlan: plan,
      action: action(const [kRemoteBookUuid]),
      snapshotBytes: snapshotBytes,
    );

    // 「风格」只有本地这一份：按 uuid 命中，不另插一行。
    final mods = await modDao.getAllMods();
    expect(mods.where((m) => m.name == '风格'), hasLength(1));
    expect(localModUuid, kRemoteModUuid);
    // 命中 → 远端内容整体覆盖（快照里那一行只写了 name）。
    final reused = await modDao.getModByUuid(kRemoteModUuid);
    expect(reused, isNotNull);
    expect(reused!.description, '', reason: '采用远端内容，指纹自此与远端一致');
    // 新书挂到本地同一 Mod 行上。
    final book = (await BookDao().getAllBooks()).single;
    final configs = await modDao.getBookMods(book.uuid);
    expect(configs.single.modUuid, kRemoteModUuid);
  });

  test('远端书引用不同 uuid 的同名 Mod → 两个独立 Mod，新书挂远端那一本', () async {
    // 本地「风格」是自己生成的 uuid（与远端那一本无任何关系）。
    final modDao = ModDao();
    final localModUuid = await modDao.insertMod(
      const Mod(name: '风格', description: '本地描述'),
    );
    expect(localModUuid, isNot(kRemoteModUuid));

    final snapshotBytes = await _buildRemoteSnapshot(
      title: '远端书',
      category: '玄幻',
    );
    final plan = SyncMergePlan(
      books: [
        decision(
          '远端书',
          remoteUuid: kRemoteBookUuid,
          presence: SyncBookPresence.remoteOnly,
        ),
      ],
    );
    await const RemoteSnapshotApplier().apply(
      mergePlan: plan,
      action: action(const [kRemoteBookUuid]),
      snapshotBytes: snapshotBytes,
    );

    // 名称从不参与身份：两本同名 Mod 各自独立，本地那一本内容未被覆盖。
    final mods = await modDao.getAllMods();
    expect(mods.where((m) => m.name == '风格'), hasLength(2));
    final local = await modDao.getModByUuid(localModUuid);
    expect(local!.description, '本地描述');
    final remote = await modDao.getModByUuid(kRemoteModUuid);
    expect(remote, isNotNull);

    final book = (await BookDao().getAllBooks()).single;
    final configs = await modDao.getBookMods(book.uuid);
    expect(configs.single.modUuid, kRemoteModUuid);
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
    final mod = mods.firstWhere((m) => m.uuid == 'remote-mod-uuid-x');
    expect(mod.name, '独立Mod');
    expect(mod.description, '远端独立描述');
    expect(mod.prePrompt, 'pre');
    // 时间戳按远端原样保留（指纹跨设备稳定）。
    expect(mod.createdAt?.toIso8601String(), '2026-01-01T00:00:00.000');
    expect(mod.updatedAt?.toIso8601String(), '2026-01-02T00:00:00.000');
    expect(mods.where((m) => m.name == '独立Mod'), hasLength(1));
  });

  test('独立 Mod 拉取：同一 uuid → 远端内容整体覆盖（含时间戳），仍是一行', () async {
    final modDao = ModDao();
    await modDao.insertMod(
      const Mod(
        uuid: 'remote-mod-uuid-style',
        name: '风格',
        description: '本地旧描述',
        prePrompt: '旧',
      ),
    );
    final snapshotBytes = await _buildRemoteSnapshot(
      // 远端仅包含该「风格」独立 Mod（无同 uuid 重复行）。
      withReferencedMod: false,
      extraMods: [
        {
          'uuid': 'remote-mod-uuid-style',
          'name': '风格',
          'description': '远端新描述',
          'pre_prompt': '新',
          'world_book': '[{"keyword": "主角", "content": "新世界书"}]',
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
    expect(mods, hasLength(1), reason: '同一 uuid → 就地覆盖，不新增行');
    final mod = mods.single;
    expect(mod.description, '远端新描述', reason: '采用远端内容');
    expect(mod.prePrompt, '新');
    expect(mod.worldBookEntries.single.keyword, '主角');
    expect(mod.worldBookEntries.single.content, '新世界书');
    // uuid 与时间戳与远端一致 → 指纹与远端相同，不会来回推送。
    expect(mod.uuid, 'remote-mod-uuid-style');
    expect(mod.createdAt?.toIso8601String(), '2026-02-01T08:00:00.000');
    expect(mod.updatedAt?.toIso8601String(), '2026-02-02T09:00:00.000');
  });

  test('独立 Mod 拉取：不同 uuid 的同名 Mod → 两个独立 Mod，本地那本不受影响', () async {
    final modDao = ModDao();
    final localModUuid = await modDao.insertMod(
      const Mod(name: '风格', description: '本地旧描述', prePrompt: '旧'),
    );
    final snapshotBytes = await _buildRemoteSnapshot(
      withReferencedMod: false,
      extraMods: [
        {
          'uuid': 'remote-mod-uuid-style',
          'name': '风格',
          'description': '远端新描述',
          'pre_prompt': '新',
        },
      ],
    );

    await const RemoteSnapshotApplier().apply(
      mergePlan: SyncMergePlan(books: const []),
      action: action(const [], pullModUuids: const ['remote-mod-uuid-style']),
      snapshotBytes: snapshotBytes,
    );

    final mods = await modDao.getAllMods();
    expect(mods.where((m) => m.name == '风格'), hasLength(2), reason: '名称不是身份');
    final local = await modDao.getModByUuid(localModUuid);
    expect(local!.description, '本地旧描述');
    expect(local.prePrompt, '旧');
    final remote = await modDao.getModByUuid('remote-mod-uuid-style');
    expect(remote!.description, '远端新描述');
  });

  test('设置部件 remoteOnly：同一 uuid 就地合并，设置列整体落地（身份无需迁移）', () async {
    // 本地已有同一 uuid 的书（旧分类、旧后置词）。
    final bookDao = BookDao();
    final localBookUuid = await bookDao.insertBook(
      const Book(
        uuid: kRemoteBookUuid,
        title: 'X',
        category: '旧分类',
        globalPostPrompt: '旧后置词',
      ),
    );
    // 远端书 X：新分类 + 新后置词（同一主键 → 就地合并）。
    final snapshotBytes = await _buildRemoteSnapshot(
      title: 'X',
      category: '新分类',
      globalPostPrompt: '新后置词',
    );

    final plan = SyncMergePlan(
      books: [
        decision(
          'X',
          localUuid: localBookUuid,
          remoteUuid: kRemoteBookUuid,
          presence: SyncBookPresence.both,
          settings: SyncPartStatus.remoteOnly,
        ),
      ],
    );
    await const RemoteSnapshotApplier().apply(
      mergePlan: plan,
      action: action(const [kRemoteBookUuid]),
      snapshotBytes: snapshotBytes,
    );

    final books = await bookDao.getAllBooks();
    expect(books, hasLength(1));
    final book = books.single;
    expect(book.uuid, kRemoteBookUuid, reason: '两侧同一主键，无需改写身份');
    expect(book.globalPostPrompt, '新后置词', reason: '设置部件整体采用远端');
    expect(book.category, '新分类', reason: '设置部件整体采用远端');
  });

  test('同名但 uuid 不同 → 两本独立的书：远端整本导入，本地同名书原样保留', () async {
    final bookDao = BookDao();
    final localBookUuid = await bookDao.insertBook(
      const Book(title: 'X', category: '旧分类', globalPostPrompt: '旧后置词'),
    );
    expect(localBookUuid, isNot(kRemoteBookUuid));

    final snapshotBytes = await _buildRemoteSnapshot(
      title: 'X',
      category: '新分类',
      globalPostPrompt: '新后置词',
    );
    final plan = SyncMergePlan(
      books: [
        decision(
          'X',
          localUuid: localBookUuid,
          remoteUuid: kRemoteBookUuid,
          presence: SyncBookPresence.remoteOnly,
        ),
      ],
    );
    await const RemoteSnapshotApplier().apply(
      mergePlan: plan,
      action: action(const [kRemoteBookUuid]),
      snapshotBytes: snapshotBytes,
    );

    final books = await bookDao.getAllBooks();
    expect(books, hasLength(2), reason: '标题从不参与定位：同名不同 uuid = 两本书');
    expect(books.where((b) => b.title == 'X'), hasLength(2));

    // 本地那本完全未被触碰。
    final local = await bookDao.getBookByUuid(localBookUuid);
    expect(local, isNotNull);
    expect(local!.category, '旧分类');
    expect(local.globalPostPrompt, '旧后置词');

    // 远端那本整本导入（含自己的轮次）。
    final imported = await bookDao.getBookByUuid(kRemoteBookUuid);
    expect(imported, isNotNull);
    expect(imported!.category, '新分类');
    expect(imported.globalPostPrompt, '新后置词');
    final remoteRounds = await RoundDao().getRoundsByBook(kRemoteBookUuid);
    expect(remoteRounds.single.userInput, '你好');
    expect(await RoundDao().getRoundsByBook(localBookUuid), isEmpty);
  });
}

/// 生成一份远端快照字节：一本主键为 [kRemoteBookUuid] 的书（可指定标题 /
/// 分类 / 后置词、轮次、是否带世界书），它引用主键 [kRemoteModUuid] 的用户
/// Mod，另可附 [extraMods] 未被任何书引用的独立 Mod。
///
/// schema 与本地库一致（v16）：`books` / `mods` 以 uuid 为主键（无 int id），
/// `rounds` / `world_book_entries` / `book_mods` 保留自身自增 id，父表以
/// `book_uuid` / `mod_uuid` 引用。用例要在本地预置「同一本书 / 同一个 Mod」，
/// 就往本地库写同一个 uuid。
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
      uuid TEXT PRIMARY KEY,
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
      book_uuid TEXT NOT NULL,
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
      book_uuid TEXT NOT NULL,
      keyword TEXT NOT NULL,
      content TEXT DEFAULT '',
      is_active INTEGER NOT NULL DEFAULT 1,
      created_at DATETIME,
      updated_at INTEGER NOT NULL DEFAULT 0
    )
  ''');
  await db.execute('''
    CREATE TABLE mods (
      uuid TEXT PRIMARY KEY,
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
      book_uuid TEXT NOT NULL,
      preset_key TEXT,
      mod_uuid TEXT,
      sort_order INTEGER NOT NULL DEFAULT 0,
      is_enabled INTEGER NOT NULL DEFAULT 1
    )
  ''');

  await db.insert('books', {
    'uuid': kRemoteBookUuid,
    'title': title,
    'category': category,
    'global_post_prompt': globalPostPrompt,
    'settings_updated_at': 100,
    'rounds_updated_at': 200,
  });
  if (withReferencedMod) {
    await db.insert('mods', {
      'uuid': kRemoteModUuid,
      'name': '风格',
    });
  }
  for (final extra in extraMods) {
    await db.insert('mods', extra);
  }
  for (final (index, input, narrative) in rounds) {
    await db.insert('rounds', {
      'book_uuid': kRemoteBookUuid,
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
      'book_uuid': kRemoteBookUuid,
      'keyword': '主角',
      'content': '设定',
      'is_active': 1,
    });
  }
  if (withReferencedMod) {
    await db.insert('book_mods', {
      'book_uuid': kRemoteBookUuid,
      'mod_uuid': kRemoteModUuid,
      'sort_order': 0,
      'is_enabled': 1,
    });
  }

  final bytes = await File(path).readAsBytes();
  await db.close();
  try {
    dir.deleteSync(recursive: true);
  } catch (_) {
    // 忽略清理失败。
  }
  return bytes;
}
