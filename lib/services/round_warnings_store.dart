import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

import 'app_paths.dart';

/// 轮次常驻黄框警告的**本地**存取抽象。
///
/// 警告属于本机生成过程的诊断信息：
/// - 必须持久化，应用重启 / 重新进入书籍后仍能恢复展示（本次需求）；
/// - 只写入本地数据层，**绝不**进入用户 sqlite 库、不参与云同步，
///   不跨设备共享（保持「不污染用户数据」的既有原则）。
///
/// 键为 `(bookUuid, roundIndex)`——roundIndex 是整个同步 / 合并体系
/// （指纹、行比对、云端恢复）的对齐单位，远端替换轮次后仍指向同一逻辑轮。
abstract class RoundWarningsStore {
  /// 读取某本书的全部常驻警告（roundIndex → 警告行）。
  Future<Map<int, List<String>>> loadForBook(String bookUuid);

  /// 整体保存某本书的常驻警告（键 = roundIndex；空 map 即清除该书全部）。
  Future<void> saveForBook(String bookUuid, Map<int, List<String>> warnings);
}

/// 内存实现：缺省注入（测试 / 未显式接线的路径），行为与「仅内存」时代一致，
/// 不触碰任何磁盘文件。生产由 [main] 显式注入 [FileRoundWarningsStore]。
class MemoryRoundWarningsStore implements RoundWarningsStore {
  final Map<String, Map<int, List<String>>> _books = {};

  @override
  Future<Map<int, List<String>>> loadForBook(String bookUuid) async {
    final book = _books[bookUuid];
    return book == null
        ? const {}
        : {for (final e in book.entries) e.key: List.of(e.value)};
  }

  @override
  Future<void> saveForBook(
    String bookUuid,
    Map<int, List<String>> warnings,
  ) async {
    final book = warnings.isEmpty
        ? null
        : {for (final e in warnings.entries) e.key: List.of(e.value)};
    if (book == null) {
      _books.remove(bookUuid);
    } else {
      _books[bookUuid] = book;
    }
  }
}

/// 文件实现：`<local_config>/round_warnings.json`（与 AppSettings 同目录，
/// 明文 JSON；写入采用「临时文件 + 原子替换」，避免进程被杀留下截断文件）。
///
/// 并发安全：多本书可并发生成并各自读写本人警告，save 属于「读-改-写」
/// 整体操作，若不加串行化会发生丢失更新（后写者基于旧快照覆盖先写者的
/// 键）。因此所有操作经过同一把异步互斥锁（FIFO）。
class FileRoundWarningsStore implements RoundWarningsStore {
  /// 测试用配置根目录覆盖（null 时走真实 [AppPaths.localConfig]）。
  @visibleForTesting
  static String? testRootOverride;

  /// 串行化所有文件操作的异步互斥链（与 [LocalConfigService] 同策略）。
  static Future<void> _queue = Future<void>.value();

  /// 测试专用：重置互斥队列（隔离用例间状态）。
  @visibleForTesting
  static void resetForTest() {
    _queue = Future<void>.value();
  }

  static Future<File> _file() async {
    final dir = testRootOverride != null
        ? Directory(p.join(testRootOverride!, 'local_config'))
        : await AppPaths.localConfig();
    await dir.create(recursive: true);
    return File(p.join(dir.path, 'round_warnings.json'));
  }

  /// 将 [task] 排入互斥队列，保证同一时刻只有一个文件操作在执行。
  static Future<T> _runLocked<T>(Future<T> Function() task) {
    final result = _queue.then((_) => task());
    // 队列本身不吞掉异常：让调用方感知失败，同时保证后续任务不被卡死。
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  @override
  Future<Map<int, List<String>>> loadForBook(String bookUuid) {
    return _runLocked(() async {
      final books = await _readBooks();
      return _decodeBook(books[bookUuid]);
    });
  }

  @override
  Future<void> saveForBook(
    String bookUuid,
    Map<int, List<String>> warnings,
  ) {
    return _runLocked(() async {
      final target = await _file();
      // 读-改-写：仅替换本书条目，其余书（可能由其它生成任务并发维护）不动。
      final books = await _readBooks();
      if (warnings.isEmpty) {
        books.remove(bookUuid);
      } else {
        books[bookUuid] = <String, dynamic>{
          for (final e in warnings.entries) '${e.key}': List<String>.of(e.value),
        };
      }
      final data = <String, dynamic>{
        'version': 1,
        'books': books,
      };
      final temp = File(
        '${target.path}.tmp-${DateTime.now().microsecondsSinceEpoch}',
      );
      try {
        await temp.writeAsString(
          const JsonEncoder.withIndent('  ').convert(data),
          flush: true,
        );
        await temp.rename(target.path);
      } finally {
        if (await temp.exists()) {
          await temp.delete();
        }
      }
    });
  }

  /// 读取全文 `books` 映射；文件不存在 / 解析失败 / 结构非法 → 空映射。
  static Future<Map<String, dynamic>> _readBooks() async {
    try {
      final f = await _file();
      if (!await f.exists()) return <String, dynamic>{};
      final decoded = jsonDecode(await f.readAsString());
      if (decoded is! Map<String, dynamic>) return <String, dynamic>{};
      final books = decoded['books'];
      return books is Map<String, dynamic> ? books : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  /// 解析单本书的警告条目：index 非数字 / 负值 / 行非字符串均丢弃，
  /// 失败整体视为空（诊断缓存，宁可少显示也不违反结构）。
  static Map<int, List<String>> _decodeBook(Object? raw) {
    if (raw is! Map) return const {};
    final result = <int, List<String>>{};
    for (final e in raw.entries) {
      final index = int.tryParse(e.key.toString());
      if (index == null || index < 0) continue;
      final lines = e.value;
      if (lines is! List) continue;
      final parsed = <String>[];
      for (final line in lines) {
        if (line is! String) continue;
        parsed.add(line);
      }
      if (parsed.isEmpty) continue;
      result[index] = parsed;
    }
    return result;
  }
}
