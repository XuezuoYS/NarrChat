import 'dart:math';

/// 由书籍 uuid 推导 Android 通知槽 id（FNV-1a 32 位哈希，取低 31 位保证非负）。
///
/// 纯函数：同一 uuid 恒定得到同一 id（可 cancel），不同 uuid 落在
/// `0..0x7fffffff`；无任何内存/持久状态，模块重启后仍可 cancel 旧通知。
/// uuid 为空串返回 0（正常流程不会出现：uuid 即主键，必非空）。
int notificationIdForUuid(String uuid) {
  if (uuid.isEmpty) return 0;
  var h = 0x811c9dc5;
  for (final c in uuid.codeUnits) {
    h ^= c;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h & 0x7FFFFFFF;
}

/// UUID v4 生成工具（RFC 4122，无需外部依赖）。
///
/// 书籍 / Mod 的跨设备同步身份：本地生成、全球唯一，服务器不参与分配。
/// 仅用于稳定性验证（版本位 / 变体位 / 格式），不做加密用途。
class UuidUtils {
  UuidUtils._();

  static final Random _random = Random.secure();

  /// 生成标准小写 UUID v4（8-4-4-4-12）。
  static String generateUuidV4() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version = 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant = 10xx
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}
