import 'dart:convert';

import 'round_generation.dart';

/// 分支父行的内容快照（存 `branches.father_row_shot`）。
///
/// 用途只有一个：父代被删除后，给模型拼合提供**一轮**级参考（刻意的降级，
/// 上文可能不完整）。快照在创建分支时抓取，之后不随父代编辑而更新。
///
/// 存储格式直接复用 [RoundGeneration.toRow] 的行映射：
/// - 不另立一套字段清单，避免"加了个内容列却忘了改快照"；
/// - 解码走 [RoundGeneration.fromRow]，缺列有默认值，老快照不会炸。
class BranchFatherSnapshot {
  BranchFatherSnapshot._();

  /// 把一代的内容编码成快照 JSON。
  static String encode(RoundGeneration generation) =>
      jsonEncode(generation.toRow());

  /// 解码快照；空串 / 非法 JSON / 结构不符都返回 `null`（视为没有兜底）。
  static RoundGeneration? decode(String raw) {
    if (raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return RoundGeneration.fromRow(
        decoded.map((key, value) => MapEntry(key.toString(), value)),
      );
    } catch (_) {
      return null;
    }
  }
}
