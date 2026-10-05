import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/db_fingerprint_store.dart';
import 'package:path/path.dart' as p;

import 'helpers/fakes.dart';

/// 启动指纹（AD-8）：库文件基线写入 / 变化判定 / 变化时触发一次全量采纳。
///
/// 用临时文件 + 注入路径，**不触碰真实用户库与 platform 目录**。
void main() {
  late Directory dir;
  late File dbFile;
  late File baselineFile;
  late DbFingerprintStore store;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('db_fingerprint_test_');
    dbFile = File(p.join(dir.path, 'narrchat.db'))..writeAsStringSync('v1');
    baselineFile = File(p.join(dir.path, 'db_fingerprint.json'));
    store = DbFingerprintStore(file: baselineFile, databaseFile: dbFile);
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {
      // 忽略清理失败。
    }
  });

  test('saveBaseline：记录库路径 / 大小 / mtime（含 updatedAt）', () async {
    await store.saveBaseline();
    expect(baselineFile.existsSync(), isTrue);
    final data = jsonDecode(await baselineFile.readAsString()) as Map;
    expect(data['path'], dbFile.path);
    expect(data['size'], dbFile.lengthSync());
    expect(data['mtimeMs'], dbFile.statSync().modified.millisecondsSinceEpoch);
    expect((data['updatedAt'] as int) > 0, isTrue);
  });

  test('无基线 → 判定为「未变化」（宁可不采纳，也不误触发全量扫描）', () async {
    expect(await store.changedSinceBaseline(), isFalse);
    expect(await store.runStartupAdoption(FakeRoundStackService()), isFalse);
  });

  test('大小变化 → 判定为变化', () async {
    await store.saveBaseline();
    expect(await store.changedSinceBaseline(), isFalse);
    dbFile.writeAsStringSync('v2-更长的内容');
    expect(await store.changedSinceBaseline(), isTrue);
  });

  test('同大小但 mtime 更新 → 判定为变化', () async {
    await store.saveBaseline();
    final original = dbFile.readAsStringSync();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    dbFile.writeAsStringSync(original);
    dbFile.setLastModifiedSync(DateTime.now().add(const Duration(seconds: 5)));
    expect(await store.changedSinceBaseline(), isTrue);
  });

  test('换了库文件（路径不同）→ 判定为变化', () async {
    await store.saveBaseline();
    final other = File(p.join(dir.path, 'other.db'))
      ..writeAsStringSync('v1');
    final otherStore = DbFingerprintStore(
      file: baselineFile,
      databaseFile: other,
    );
    expect(await otherStore.changedSinceBaseline(), isTrue);
  });

  test('AD-8 启动采纳：未变化不触发；变化触发全量采纳并重写基线（幂等）', () async {
    final stack = FakeRoundStackService();
    await store.saveBaseline();

    // 未变化 → 不触发。
    expect(await store.runStartupAdoption(stack), isFalse);
    expect(stack.adoptAllCalls, 0);

    // 变化 → 触发一次全量采纳，并立刻重写基线（第二次不再触发）。
    dbFile.writeAsStringSync('v2');
    expect(await store.changedSinceBaseline(), isTrue);
    expect(await store.runStartupAdoption(stack), isTrue);
    expect(stack.adoptAllCalls, 1);
    expect(await store.changedSinceBaseline(), isFalse, reason: '采纳后基线已更新');
    expect(await store.runStartupAdoption(stack), isFalse);
    expect(stack.adoptAllCalls, 1, reason: '误报不得反复采纳');
  });

  test('基线文件损坏 / 库文件缺失 → 判定为未变化（不得因诊断数据阻断启动）', () async {
    await baselineFile.writeAsString('not-json');
    expect(await store.changedSinceBaseline(), isFalse);

    await store.saveBaseline();
    dbFile.deleteSync();
    expect(await store.changedSinceBaseline(), isFalse);
  });
}
