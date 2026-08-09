import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:narrchat/services/cloud_sync_service.dart';
import 'package:narrchat/services/database_merge_service.dart';
import 'package:narrchat/services/webdav_service.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 供重定向测试使用的 PROPFIND 207 响应样例。
const String _multistatusXml = '''
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dav/narrchat/narrchat_user_2026-08-09_10-00-00.db</d:href>
    <d:propstat><d:prop>
      <d:getlastmodified>Mon, 09 Aug 2026 10:00:00 GMT</d:getlastmodified>
      <d:getcontentlength>2048</d:getcontentlength>
    </d:prop></d:propstat>
  </d:response>
</d:multistatus>''';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDownAll(() async {
    for (final dir in _tempDirs) {
      try {
        await dir.delete(recursive: true);
      } catch (_) {
        // 忽略清理失败。
      }
    }
    _tempDirs.clear();
  });

  group('WebDavService.parseMultiStatus', () {
    test('解析文件条目并跳过目录', () {
      const xml = '''
<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:" xmlns:s="http://sabredav.org/ns">
  <d:response>
    <d:href>/dav/narrchat/</d:href>
    <d:propstat><d:prop>
      <d:getlastmodified>Mon, 09 Aug 2026 10:00:00 GMT</d:getlastmodified>
      <d:getcontentlength>0</d:getcontentlength>
    </d:prop></d:propstat>
  </d:response>
  <d:response>
    <d:href>/dav/narrchat/narrchat_user_2026-08-09_10-00-00.db</d:href>
    <d:propstat><d:prop>
      <d:getlastmodified>Mon, 09 Aug 2026 10:00:00 GMT</d:getlastmodified>
      <d:getcontentlength>2048</d:getcontentlength>
    </d:prop></d:propstat>
  </d:response>
  <d:response>
    <d:href>/dav/narrchat/other.txt</d:href>
    <d:propstat><d:prop>
      <d:getcontentlength>10</d:getcontentlength>
    </d:prop></d:propstat>
  </d:response>
</d:multistatus>''';

      final files = WebDavService.parseMultiStatus(xml);
      expect(files, hasLength(2));
      expect(files[0].name, 'narrchat_user_2026-08-09_10-00-00.db');
      expect(files[0].size, 2048);
      expect(files[0].lastModified, isNotNull);
      expect(files[1].name, 'other.txt');
      expect(files[1].lastModified, isNull);
      expect(files[1].size, 10);
    });

    test('解码 URL 编码的 href 文件名', () {
      const xml = '''
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dav/narrchat/narrchat%20user_2026-08-09_11-00-00.db</d:href>
    <d:propstat><d:prop><d:getcontentlength>100</d:getcontentlength></d:prop></d:propstat>
  </d:response>
</d:multistatus>''';
      final files = WebDavService.parseMultiStatus(xml);
      expect(files.single.name, 'narrchat user_2026-08-09_11-00-00.db');
    });

    test('空响应返回空列表', () {
      expect(
        WebDavService.parseMultiStatus('<d:multistatus xmlns:d="DAV:"/>'),
        isEmpty,
      );
    });
  });

  group('WebDavService 重定向跟随', () {
    test('PROPFIND 收到 301 后跟随重定向成功列出', () async {
      var callCount = 0;
      String? lastMethod;
      String? lastAuth;
      final client = MockClient((request) async {
        callCount++;
        lastMethod = request.method;
        lastAuth = request.headers['Authorization'];
        if (request.url.path == '/dav/narrchat') {
          // 无尾斜杠目录 → 301 到带尾斜杠地址（Apache mod_dav 常见行为）。
          return http.Response(
            '<html>301 Moved</html>',
            301,
            headers: {
              'location': 'https://webdav.hk.xuezuo.xyz/dav/narrchat/',
            },
          );
        }
        return http.Response(_multistatusXml, 207);
      });
      final dav = WebDavService(
        baseUrl: 'https://webdav.hk.xuezuo.xyz/dav/',
        username: 'user',
        password: 'pass',
        client: client,
      );
      final files = await dav.list('narrchat');
      expect(callCount, 2);
      // 重定向后仍以 PROPFIND 发送，且同主机跳转保留 Authorization。
      expect(lastMethod, 'PROPFIND');
      expect(lastAuth, isNotNull);
      expect(files, hasLength(1));
      expect(files.single.name, 'narrchat_user_2026-08-09_10-00-00.db');
    });

    test('跨主机跳转时移除 Authorization', () async {
      String? lastAuth;
      final client = MockClient((request) async {
        lastAuth = request.headers['Authorization'];
        if (request.url.host == 'a.example.com') {
          return http.Response(
            'redirect',
            302,
            headers: {'location': 'https://b.example.com/dav/narrchat/'},
          );
        }
        return http.Response(_multistatusXml, 207);
      });
      final dav = WebDavService(
        baseUrl: 'https://a.example.com/dav/',
        username: 'user',
        password: 'pass',
        client: client,
      );
      final files = await dav.list('narrchat');
      expect(files, hasLength(1));
      expect(lastAuth, isNull); // 跨主机不携带凭据
    });

    test('重定向次数超过上限时抛错', () async {
      final client = MockClient((request) async {
        return http.Response(
          'redirect',
          302,
          headers: {'location': 'https://a.example.com/again'},
        );
      });
      final dav = WebDavService(
        baseUrl: 'https://a.example.com/',
        username: 'user',
        password: 'pass',
        client: client,
      );
      await expectLater(
        dav.list('narrchat'),
        throwsA(isA<WebDavException>()),
      );
    });
  });

  group('CloudSyncService.buildBackupFileName', () {
    test('生成标准格式文件名', () {
      final name = CloudSyncService.buildBackupFileName(
        'user',
        DateTime(2026, 8, 9, 10, 30, 5),
      );
      expect(name, 'narrchat_user_2026-08-09_10-30-05.db');
    });

    test('非法文件名与空白用户名被净化', () {
      final name = CloudSyncService.buildBackupFileName(
        'a/b:c',
        DateTime(2026, 8, 9, 10, 30, 5),
      );
      expect(name, 'narrchat_a_b_c_2026-08-09_10-30-05.db');
      final empty = CloudSyncService.buildBackupFileName(
        '   ',
        DateTime(2026, 1, 2, 3, 4, 5),
      );
      expect(empty, 'narrchat_user_2026-01-02_03-04-05.db');
    });
  });

  group('CloudSyncService.matchBackups / compareBackups', () {
    test('仅匹配本应用备份文件名', () {
      final files = [
        const WebDavFile(name: 'narrchat_user_2026-08-09_10-00-00.db'),
        const WebDavFile(name: 'other.db'),
        const WebDavFile(name: 'narrchat_user_bad.db'),
        const WebDavFile(name: 'narrchat_user_2026-08-09_10-00-00.db.bak'),
      ];
      final matched = CloudSyncService.matchBackups(files);
      expect(matched.map((f) => f.name), [
        'narrchat_user_2026-08-09_10-00-00.db',
      ]);
    });

    test('按修改时间新 → 旧排序', () {
      final files = [
        WebDavFile(
          name: 'a.db',
          lastModified: DateTime.utc(2026, 8, 1),
        ),
        WebDavFile(
          name: 'b.db',
          lastModified: DateTime.utc(2026, 8, 9),
        ),
        WebDavFile(name: 'c.db'),
      ];
      files.sort(CloudSyncService.compareBackups);
      expect(files.map((f) => f.name).toList(), ['b.db', 'a.db', 'c.db']);
    });
  });

  group('DatabaseMergeService.mergeDatabases', () {
    test('合并去重：书籍/轮次/世界书/Mod 均取并集', () async {
      final local = await _createDb();
      final backup = await _createDb();
      try {
        // 本地：一本书（第 1 轮），一个 Mod。
        final localBookId = await local.insert('books', {'title': '本地书'});
        await local.insert('rounds', {
          'book_id': localBookId,
          'round_index': 1,
          'user_input': '本地输入',
        });
        await local.insert('mods', {'name': '本地Mod'});
        await local.insert('world_book_entries', {
          'book_id': localBookId,
          'keyword': 'k1',
          'content': '本地k1',
        });

        // 备份：同名书（含第 1 轮重复 + 第 2 轮新增），一本新书，一个新 Mod。
        final backupBook1 = await backup.insert('books', {'title': '本地书'});
        await backup.insert('rounds', {
          'book_id': backupBook1,
          'round_index': 1,
          'user_input': '备份输入',
        });
        await backup.insert('rounds', {
          'book_id': backupBook1,
          'round_index': 2,
          'user_input': '备份第2轮',
        });
        final backupBook2 = await backup.insert('books', {'title': '云端书'});
        await backup.insert('rounds', {
          'book_id': backupBook2,
          'round_index': 1,
          'user_input': '云端输入',
        });
        await backup.insert('world_book_entries', {
          'book_id': backupBook1,
          'keyword': 'k1',
          'content': '备份k1',
        });
        await backup.insert('world_book_entries', {
          'book_id': backupBook1,
          'keyword': 'k2',
          'content': '备份k2',
        });
        await backup.insert('world_book_entries', {
          'book_id': backupBook2,
          'keyword': 'k3',
          'content': '云端k3',
        });
        await backup.insert('mods', {'name': '本地Mod'});
        final backupMod2 = await backup.insert('mods', {'name': '云端Mod'});
        // 新书启用「云端Mod」，应随新书一并复制。
        await backup.insert('book_mods', {
          'book_id': backupBook2,
          'mod_id': backupMod2,
          'sort_order': 0,
          'is_enabled': 1,
        });

        final result = await DatabaseMergeService.mergeDatabases(
          backup,
          local,
        );
        expect(result.booksAdded, 1);
        expect(result.modsAdded, 1);
        expect(result.roundsAdded, 2);
        expect(result.worldBookAdded, 2);
        expect(result.bookModsAdded, 1);

        // 校验合并结果。
        final books = await local.query('books', orderBy: 'id ASC');
        expect(books, hasLength(2));
        final cloudBook = books.firstWhere((b) => b['title'] == '云端书');
        final localRounds = await local.query('rounds');
        expect(localRounds, hasLength(3)); // 本地1 + 备份新2
        final cloudRounds = localRounds
            .where((r) => r['book_id'] == cloudBook['id'])
            .toList();
        expect(cloudRounds, hasLength(1));
        expect(cloudRounds.single['user_input'], '云端输入');

        final localWbe = await local.query('world_book_entries');
        expect(localWbe, hasLength(3));
        expect(
          localWbe.map((w) => w['keyword']).toSet(),
          {'k1', 'k2', 'k3'},
        );

        final localMods = await local.query('mods');
        expect(localMods, hasLength(2));
        final cloudMod = localMods.firstWhere((m) => m['name'] == '云端Mod');
        final localBookMods = await local.query('book_mods');
        expect(localBookMods, hasLength(1));
        expect(localBookMods.single['book_id'], cloudBook['id']);
        expect(localBookMods.single['mod_id'], cloudMod['id']);
      } finally {
        await local.close();
        await backup.close();
      }
    });

    test('备份为空时无变化', () async {
      final local = await _createDb();
      final backup = await _createDb();
      try {
        await local.insert('books', {'title': 'A'});
        final result = await DatabaseMergeService.mergeDatabases(
          backup,
          local,
        );
        expect(result.isEmpty, isTrue);
        final books = await local.query('books');
        expect(books, hasLength(1));
      } finally {
        await local.close();
        await backup.close();
      }
    });
  });
}

final List<Directory> _tempDirs = [];

/// 创建与正式库同构的独立临时文件数据库（仅含合并所需的五张表）。
Future<Database> _createDb() async {
  final dir = await Directory.systemTemp.createTemp('narrchat_test_');
  _tempDirs.add(dir);
  final db = await databaseFactoryFfi.openDatabase(p.join(dir.path, 'test.db'));
  await db.execute('''
    CREATE TABLE books (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      title TEXT NOT NULL,
      category TEXT DEFAULT '',
      base_setting TEXT DEFAULT '',
      writing_requirements TEXT DEFAULT '',
      writing_style TEXT DEFAULT '',
      global_pre_prompt TEXT DEFAULT '',
      global_post_prompt TEXT DEFAULT '',
      history_rounds INTEGER NOT NULL DEFAULT 1,
      role_hierarchy TEXT DEFAULT '',
      role_hierarchy_detail TEXT DEFAULT ''
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
      created_at DATETIME
    )
  ''');
  await db.execute('''
    CREATE TABLE world_book_entries (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      book_id INTEGER NOT NULL,
      keyword TEXT NOT NULL,
      content TEXT DEFAULT '',
      is_active INTEGER NOT NULL DEFAULT 1,
      created_at DATETIME
    )
  ''');
  await db.execute('''
    CREATE TABLE mods (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      description TEXT DEFAULT '',
      pre_prompt TEXT DEFAULT '',
      post_prompt TEXT DEFAULT '',
      system_prompt TEXT DEFAULT '',
      world_book TEXT DEFAULT '',
      created_at DATETIME,
      updated_at DATETIME
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
  return db;
}
