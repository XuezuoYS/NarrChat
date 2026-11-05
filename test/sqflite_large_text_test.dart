import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/database/sqflite_large_text.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// `readRowsWithLargeText`：把可能上 MB 的 TEXT 列分片读回来。
///
/// 背景（真机事故）：Android 上 sqflite 走系统 CursorWindow，**单行**超出窗口
/// （约 1~2 MB）就抛 `Row too big to fit into CursorWindow`。云同步共基的
/// `rounds_fp` 是一本书全部轮次的完整文本，长书能到 2 MB 以上——整表
/// `SELECT *` 在手机端必崩，桌面 FFI 却一切正常。
///
/// 这里锁定分片读的语义：拼回的字符串必须与整列一次读出**逐字符一致**
/// （含 CJK 与 emoji 代理对），且 NULL / 空串 / 普通列 / 行序都不变。
void main() {
  late Database db;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    db = await openDatabase(
      inMemoryDatabasePath,
      version: 1,
      singleInstance: false,
      onCreate: (d, _) async {
        await d.execute('''
          CREATE TABLE t(
            uuid TEXT PRIMARY KEY,
            title TEXT,
            sort_order INTEGER DEFAULT 0,
            big_a TEXT,
            big_b TEXT
          )
        ''');
      },
    );
  });

  tearDown(() async {
    await db.close();
  });

  test('多分片拼回：CJK + emoji 跨分片边界逐字符一致（不劈开代理对）', () async {
    // 6 码点 × 40 + 1 码点 = 241 码点；chunkChars=3 时最后一片只剩 1 个字符。
    final text = '${'深🐳a「潮」' * 40}尾';
    await db.insert('t', {
      'uuid': 'u1',
      'title': '大书',
      'sort_order': 7,
      'big_a': text,
    });

    final rows = await readRowsWithLargeText(
      db,
      table: 't',
      keyColumn: 'uuid',
      plainColumns: ['uuid', 'title', 'sort_order'],
      largeTextColumns: ['big_a'],
      chunkChars: 3,
    );

    expect(rows, hasLength(1));
    expect(rows.single['big_a'], text);
    expect(rows.single['big_a'], hasLength(text.length));
    expect(rows.single['title'], '大书');
    expect(rows.single['sort_order'], 7);
    expect(
      rows.single.containsKey('__len_big_a'),
      isFalse,
      reason: '内部长度别名不应出现在返回结果里',
    );
  });

  test('NULL 与空串保真、两列大字段互不串位、行序不变', () async {
    await db.insert('t', {
      'uuid': 'null-row',
      'title': 'n',
      'big_a': null,
      'big_b': '',
    });
    await db.insert('t', {
      'uuid': 'empty-row',
      'title': 'e',
      'big_a': '',
      'big_b': null,
    });
    await db.insert('t', {
      'uuid': 'text-row',
      'title': 't',
      'big_a': '甲' * 9,
      'big_b': '乙',
    });

    final rows = await readRowsWithLargeText(
      db,
      table: 't',
      keyColumn: 'uuid',
      plainColumns: ['uuid', 'title'],
      largeTextColumns: ['big_a', 'big_b'],
      chunkChars: 2,
    );

    expect(rows.map((r) => r['uuid']), ['null-row', 'empty-row', 'text-row']);
    expect(rows[0]['big_a'], isNull);
    expect(rows[0]['big_b'], '');
    expect(rows[1]['big_a'], '');
    expect(rows[1]['big_b'], isNull);
    expect(rows[2]['big_a'], '甲' * 9);
    expect(rows[2]['big_b'], '乙');
  });

  test('空表返回空列表', () async {
    final rows = await readRowsWithLargeText(
      db,
      table: 't',
      keyColumn: 'uuid',
      plainColumns: ['uuid', 'title'],
      largeTextColumns: ['big_a'],
    );
    expect(rows, isEmpty);
  });

  test('可在事务内调用（DAO 的实际路径）', () async {
    final text = '深🐳' * 30;
    await db.insert('t', {'uuid': 'u1', 'big_a': text});

    final rows = await db.transaction(
      (txn) => readRowsWithLargeText(
        txn,
        table: 't',
        keyColumn: 'uuid',
        plainColumns: const ['uuid'],
        largeTextColumns: const ['big_a'],
        chunkChars: 4,
      ),
    );

    expect(rows.single['big_a'], text);
  });

  test('分片长度非正数 → ArgumentError（否则分片循环会原地打转）', () async {
    for (final chunkChars in [0, -1]) {
      await expectLater(
        () => readRowsWithLargeText(
          db,
          table: 't',
          keyColumn: 'uuid',
          plainColumns: const ['uuid'],
          largeTextColumns: const ['big_a'],
          chunkChars: chunkChars,
        ),
        throwsA(isA<ArgumentError>()),
        reason: 'chunkChars=$chunkChars 必须被拒绝',
      );
    }
  });
}
