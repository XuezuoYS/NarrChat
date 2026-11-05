import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 单次分片读取的字符数。
///
/// `substr()` / `length()` 都按**字符**（Unicode 码点）计数，所以单片最多
/// `chunkChars × 4` 字节（UTF-8 最坏情况）。默认 64 K 字符 = 256 KB，
/// 远低于任何 Android `CursorWindow`（常见约 1~2 MB）。
const int kLargeTextChunkChars = 64 * 1024;

/// 分片读出「可能很大的 TEXT 列」，规避 Android CursorWindow 单行上限。
///
/// 背景：Android 上的 sqflite 走系统 `CursorWindow`，**单行**放不进窗口就抛
/// `DatabaseException(Row too big to fit into CursorWindow requiredPos=…,
/// totalRows=…)`；桌面端 `sqflite_common_ffi` 没有这个限制，于是同一份数据
/// 会出现「手机读崩溃、电脑一切正常」。
///
/// 云同步共基的 `rounds_fp` 是一本书**全部轮次的完整文本**，长书能到数 MB，
/// 所以 `SyncStateDao` 这类表禁止 `SELECT *`。本函数把大列拆开读：
/// 先用 `length()` 取字符数，再按 [chunkChars] 用 `substr()` 分片，
/// 最后拼回与「整列一次读出」**逐字符一致**的字符串
/// （因为 `substr()` 不会劈开 emoji 等代理对）。
///
/// 语义与 `SELECT *` 对齐：
/// - 返回行数、行序与首查一致（不排序）；
/// - `NULL` 保持 `null`（该列该行不做分片查询），`''` 保持 `''`；
/// - 只返回 [plainColumns] + [largeTextColumns] + [keyColumn]，不含内部长度别名。
///
/// [keyColumn] 必须是唯一键（本项目里就是主键 `uuid`）。多列分片读要保证读到
/// 同一份快照，调用方应把整次读取放进一个事务（见 `SyncStateDao`）。
///
/// 只支持 TEXT 列；列里若是 BLOB 会抛类型错误，与直接整列读一致。
Future<List<Map<String, Object?>>> readRowsWithLargeText(
  DatabaseExecutor db, {
  required String table,
  required String keyColumn,
  required List<String> plainColumns,
  required List<String> largeTextColumns,
  int chunkChars = kLargeTextChunkChars,
}) async {
  if (chunkChars <= 0) {
    throw ArgumentError.value(chunkChars, 'chunkChars', '分片长度必须大于 0');
  }
  // 键列单独读，避免和普通列重复查出两同名列。
  final plain = [
    for (final c in plainColumns)
      if (c != keyColumn) c,
  ];
  final large = [
    for (final c in largeTextColumns)
      if (c != keyColumn) c,
  ];

  final keySql = _quote(keyColumn);
  final selectParts = <String>[
    keySql,
    for (final c in plain) _quote(c),
    for (final c in large) 'length(${_quote(c)}) AS ${_quote(_lengthAlias(c))}',
  ];
  final rows = await db.rawQuery(
    'SELECT ${selectParts.join(', ')} FROM ${_quote(table)}',
  );

  final result = <Map<String, Object?>>[
    for (final row in rows)
      <String, Object?>{
        keyColumn: row[keyColumn],
        for (final c in plain) c: row[c],
        // 大列先占位 null：NULL 值保持 null，非 NULL 值在下面拼回。
        for (final c in large) c: null,
      },
  ];
  if (rows.isEmpty || large.isEmpty) return result;

  // 键 → 结果行下标（块查询按行返回，靠键回填）。
  final indexByKey = <Object?, int>{};
  for (var i = 0; i < rows.length; i++) {
    final key = rows[i][keyColumn];
    if (key != null) indexByKey[key] = i;
  }

  for (final column in large) {
    final chunkBuffers = List<StringBuffer?>.filled(rows.length, null);
    var maxLength = 0;
    for (var i = 0; i < rows.length; i++) {
      final raw = rows[i][_lengthAlias(column)];
      final length = raw is int ? raw : (raw is num ? raw.toInt() : null);
      if (length == null) continue; // NULL → 不拼（结果保持 null）。
      chunkBuffers[i] = StringBuffer();
      if (length > maxLength) maxLength = length;
    }
    for (var offset = 0; offset < maxLength; offset += chunkChars) {
      // substr 的起点是 1 基；每片一次查询，单行最多 chunkChars 个字符。
      final chunks = await db.rawQuery(
        'SELECT $keySql AS ${_quote('k')}, '
        'substr(${_quote(column)}, ?, ?) AS ${_quote('v')} '
        'FROM ${_quote(table)}',
        [offset + 1, chunkChars],
      );
      for (final chunk in chunks) {
        final value = chunk['v'];
        final index = indexByKey[chunk['k']];
        if (index == null) continue;
        final buffer = chunkBuffers[index];
        if (buffer == null) continue; // 该行此列为 NULL（没有分片缓冲区）。
        if (value is! String) {
          // 非 TEXT 列（如 BLOB）不能按字符分片，宁可直接报错也别拼出残缺值。
          throw StateError('列 "$column" 不是 TEXT，无法分片读取');
        }
        buffer.write(value);
      }
    }
    for (var i = 0; i < rows.length; i++) {
      final buffer = chunkBuffers[i];
      if (buffer != null) result[i][column] = buffer.toString();
    }
  }
  return result;
}

/// 内部长度别名（前缀避免撞上真实列名；不会出现在返回结果里）。
String _lengthAlias(String column) => '__len_$column';

/// SQL 标识符加双引号（内嵌双引号转义）。
String _quote(String identifier) => '"${identifier.replaceAll('"', '""')}"';
