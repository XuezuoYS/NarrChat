import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/local_config_service.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tempRoot;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('narrchat_local_config_');
    LocalConfigService.testRootOverride = tempRoot.path;
  });

  tearDown(() async {
    LocalConfigService.testRootOverride = null;
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  group('LocalConfigService 并发读写', () {
    test('配置文件落在 local_config/app_settings.json', () async {
      await LocalConfigService.update({'themeMode': 'dark'});

      final file = await LocalConfigService.file();
      expect(
        file.path,
        p.join(tempRoot.path, 'local_config', 'app_settings.json'),
      );
      expect(await file.exists(), isTrue);
      expect(await LocalConfigService.readValue<String>('themeMode'), 'dark');
    });

    test('多个 update 并发执行时各键均被保留（不丢失更新）', () async {
      // 模拟启动阶段多个 Provider（AI 设置 / UI 设置 / 云同步）同时写同一文件：
      // 串行化前，后写者可能基于旧快照覆盖先写者的键，导致部分设置被清。
      final patches = <String, dynamic>{
        for (var i = 0; i < 30; i++) 'key$i': 'value$i',
      };
      await Future.wait([
        for (final e in patches.entries)
          LocalConfigService.update({e.key: e.value}),
      ]);

      final cfg = await LocalConfigService.read();
      for (final e in patches.entries) {
        expect(cfg[e.key], e.value, reason: '并发更新丢失了键 ${e.key}');
      }
    });

    test('不同键组的并发 update 互不覆盖（模拟 AI / UI / 云同步同写一文件）', () async {
      // 启动阶段三个 Provider 会同时 update 各自的键；串行化前，
      // 后完成者基于旧快照写回会把先完成者的键抹掉。
      final groups = <String, dynamic>{
        'baseUrl': 'https://api.example.com',
        'selectedPreset': 'deepseek-v4-pro',
        'themeMode': 'dark',
        'fontFamily': 'Noto Sans',
        'webdavUrl': 'https://dav.example.com',
        'webdavAutoUpload': true,
      };
      final keys = groups.keys.toList();
      await Future.wait([
        for (var i = 0; i < 3; i++)
          LocalConfigService.update({
            for (var j = i; j < keys.length; j += 3) keys[j]: groups[keys[j]],
          }),
      ]);

      final cfg = await LocalConfigService.read();
      for (final e in groups.entries) {
        expect(cfg[e.key], e.value, reason: '并发 update 覆盖了键 ${e.key}');
      }
    });

    test('write 为整体替换语义：后续 update 保留既有键并合并新键', () async {
      await LocalConfigService.write({'keep': 'yes', 'b': '2'});
      await LocalConfigService.update({'c': '3'});

      final cfg = await LocalConfigService.read();
      expect(cfg['keep'], 'yes');
      expect(cfg['b'], '2');
      expect(cfg['c'], '3');
    });

    test('写入后不残留临时文件', () async {
      await LocalConfigService.update({'themeMode': 'light'});

      final dir = Directory(p.join(tempRoot.path, 'local_config'));
      final leftovers = await dir
          .list()
          .where((e) => e.path.contains('.tmp-'))
          .toList();
      expect(leftovers, isEmpty);
    });
  });
}
