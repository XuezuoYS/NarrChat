import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/round_warnings_store.dart';
import 'package:path/path.dart' as p;

/// [FileRoundWarningsStore]（本地数据层）单元测试。
///
/// 覆盖：文件路径与格式、save/load round-trip、空 map 清书语义、
/// 损坏 / 非法结构容错、并发读写不丢失更新（互斥队列）。
void main() {
  late Directory tempRoot;

  setUp(() async {
    tempRoot =
        await Directory.systemTemp.createTemp('narrchat_round_warnings_');
    FileRoundWarningsStore.testRootOverride = tempRoot.path;
    FileRoundWarningsStore.resetForTest();
  });

  tearDown(() async {
    FileRoundWarningsStore.testRootOverride = null;
    FileRoundWarningsStore.resetForTest();
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  String filePath() =>
      p.join(tempRoot.path, 'local_config', 'round_warnings.json');

  group('FileRoundWarningsStore', () {
    test('文件不存在时返回空（首次启动无缓存）', () async {
      final store = FileRoundWarningsStore();
      expect(await store.loadForBook('b1'), isEmpty);
    });

    test('save → load round-trip：多轮多行、行序保持', () async {
      final store = FileRoundWarningsStore();
      await store.saveForBook('b1', {
        1: ['世界状态本轮未更新', '记忆总结本轮未更新'],
        3: ['本轮未产出正文（模型只返回了工具调用），本轮的状态改动已作废。'],
      });

      final loaded = await store.loadForBook('b1');
      expect(loaded.keys, [1, 3]);
      expect(loaded[1], ['世界状态本轮未更新', '记忆总结本轮未更新']);
      expect(loaded[3], hasLength(1));
      // 文件落在 local_config/round_warnings.json（与应用设置同目录）。
      expect(await File(filePath()).exists(), isTrue);
    });

    test('空 map 保存 = 清除该书全部条目，其它书不受影响', () async {
      final store = FileRoundWarningsStore();
      await store.saveForBook('b1', {1: ['警告 A']});
      await store.saveForBook('b2', {2: ['警告 B']});

      await store.saveForBook('b1', const {});

      expect(await store.loadForBook('b1'), isEmpty);
      expect(await store.loadForBook('b2'), {2: ['警告 B']});
    });

    test('覆盖保存仅替换本书条目', () async {
      final store = FileRoundWarningsStore();
      await store.saveForBook('b1', {1: ['旧'], 2: ['保留']});
      await store.saveForBook('b1', {2: ['保留'], 3: ['新']});

      expect(await store.loadForBook('b1'), {
        2: ['保留'],
        3: ['新'],
      });
    });

    test('损坏 JSON 返回空且不抛，随后 save 可修复文件', () async {
      await File(filePath()).create(recursive: true);
      await File(filePath()).writeAsString('{ 不是合法 JSON');

      final store = FileRoundWarningsStore();
      expect(await store.loadForBook('b1'), isEmpty);

      await store.saveForBook('b1', {1: ['修复后']});
      expect(await store.loadForBook('b1'), {1: ['修复后']});
    });

    test('结构非法（books 非 map / 条目非字符串列表 / index 非法）容错', () async {
      await File(filePath()).create(recursive: true);
      await File(filePath()).writeAsString(
        '{"version":1,"books":'
        '{"b1":{"1":["ok"],"abc":["丢弃：index 非数字"],"-1":["丢弃：负值"],'
        '"3":"非列表","4":[42,"混入数字"]}}}',
      );

      final store = FileRoundWarningsStore();
      expect(await store.loadForBook('b1'), {1: ['ok'], 4: ['混入数字']});
    });

    test('不同书并发 save 互不覆盖（互斥队列 + 读-改-写）', () async {
      final store = FileRoundWarningsStore();
      await Future.wait([
        for (var i = 0; i < 10; i++)
          store.saveForBook('a', {i: ['A$i']}),
        for (var i = 0; i < 10; i++)
          store.saveForBook('b', {i: ['B$i']}),
      ]);

      expect((await store.loadForBook('a')).keys, [9]);
      expect((await store.loadForBook('b')).keys, [9]);
      expect(await store.loadForBook('a'), {9: ['A9']});
      expect(await store.loadForBook('b'), {9: ['B9']});
    });
  });

  group('MemoryRoundWarningsStore', () {
    test('基本读写与清空（默认注入语义）', () async {
      final store = MemoryRoundWarningsStore();
      expect(await store.loadForBook('b1'), isEmpty);

      await store.saveForBook('b1', {1: ['仅本轮']});
      expect(await store.loadForBook('b1'), {1: ['仅本轮']});

      await store.saveForBook('b1', const {});
      expect(await store.loadForBook('b1'), isEmpty);
    });
  });
}
