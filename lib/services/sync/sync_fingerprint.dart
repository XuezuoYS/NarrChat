import 'dart:convert';

/// 云同步用内容指纹工具。
///
/// 三向部件级合并需要**与行 id 无关、与内容强相关**的指纹：
/// - 同一内容 → 同一指纹（跨设备一致，用于对齐 base / local / remote）；
/// - 任一字段变化 → 指纹变化（用于判定"哪一侧改过"）。
///
/// 指纹**只由内容字段计算，任何时间戳都不参与**（created_at / updated_at /
/// settings_updated_at 等一律排除——时间戳会随保存刷新，纳入即造成
/// "内容未变也判定变更"的假同步）。时间戳仅保留在库与 manifest 中供展示建议。
///
/// 部件拆分（配合 `sync_book_base`）：**书籍设置**、**轮次（含失败条目）**、
/// 世界书、书‑Mod 各算一个：
/// - 设置部件含全部设置字段——任一侧改任一设置字段、另一侧也改过 → 真冲突，
///   由冲突解决页分别对「设置部件 / 内容部件」选择导入或本地；
/// - 失败条目（失败输入/错误/图片）与生成内容同生命周期，**并入轮次部件**：
///   一次成功生成会"新增轮次 + 清空失败条目"，作为同一部件变化同步。
class SyncFingerprint {
  SyncFingerprint._();

  /// 「书籍设置部件」指纹：书名、分类、各类设定、前后置词、历史轮数、
  /// 角色层级与描述格式（失败条目不在此列——随轮次部件）。
  static String bookSettings(Map<String, Object?> row) {
    return jsonEncode([
      row['title'],
      row['category'],
      row['base_setting'],
      row['writing_requirements'],
      row['writing_style'],
      row['global_pre_prompt'],
      row['global_post_prompt'],
      row['history_rounds'],
      row['role_hierarchy'],
      row['role_hierarchy_detail'],
    ]);
  }

  /// 单条轮次指纹（按 [roundIndex] 对齐比较）。
  static String round(Map<String, Object?> row) {
    return jsonEncode([
      row['round_index'],
      row['user_input'],
      row['ai_narrative'],
      row['world_state'],
      row['character_state'],
      row['memory_summary'],
      row['current_time'],
      row['recommended_action'],
      row['tokens_in'],
      row['tokens_out'],
      row['model_name'],
      row['user_images'],
      row['ai_images'],
    ]);
  }

  /// 「轮次部件」聚合指纹：与顺序无关地汇总全部轮次（按 round_index 排序后逐条哈希），
  /// 并**附带失败条目**（生成内容的同生命周期状态，随轮次同步）。
  static String roundsWithFailed(
    List<Map<String, Object?>> rows,
    Map<String, Object?> bookRow,
  ) {
    final sorted = [...rows]
      ..sort((a, b) => _asInt(a['round_index']).compareTo(_asInt(b['round_index'])));
    return jsonEncode({
      'rounds': sorted.map(round).toList(),
      'failed': [
        bookRow['failed_user_input'],
        bookRow['failed_error_message'],
        bookRow['failed_user_images'],
      ],
    });
  }

  /// 解析「轮次部件」聚合串的行内容列表（`roundsWithFailed` 的输出格式：按
  /// round_index 升序的 `round()` 行串）。不可解析（旧格式 / 损坏）→ null，
  /// 调用方按整串语义处理。
  static List<String>? roundRows(String fp) {
    try {
      final decoded = jsonDecode(fp);
      if (decoded is! Map || decoded['rounds'] is! List) return null;
      final rows = decoded['rounds'] as List;
      if (rows.any((r) => r is! String)) return null;
      return rows.cast<String>();
    } catch (_) {
      return null;
    }
  }

  /// 「世界书部件」指纹：按 keyword 排序后逐条哈希（顺序无关；不含 created_at）。
  static String worldBooks(List<Map<String, Object?>> rows) {
    final sorted = [...rows]..sort((a, b) {
        final ak = a['keyword'] as String? ?? '';
        final bk = b['keyword'] as String? ?? '';
        return ak.compareTo(bk);
      });
    return jsonEncode(
      sorted
          .map((w) => [
                w['keyword'],
                w['content'],
                w['is_active'],
              ])
          .toList(),
    );
  }

  /// 「书‑Mod 部件」指纹：按 （预置/用户类型, 名称, preset_key, uuid）稳定排序后逐条哈希。
  ///
  /// - [modNameById]：mod_id → mod 名（用于把 mod_id 归一化，避免 id 不同导致指纹漂移）；
  /// - [modUuidById]：mod_id → uuid（同名 Mod 的稳定定序键，跨设备一致）。
  /// 排序 + 内容（名称 / preset_key / sort_order / is_enabled）共同构成指纹。
  static String bookMods(
    List<Map<String, Object?>> rows,
    Map<int, String> modNameById,
    Map<int, String> modUuidById,
  ) {
    final sorted = [...rows]..sort((a, b) {
        final an = _modName(a, modNameById);
        final bn = _modName(b, modNameById);
        final byName = an.compareTo(bn);
        if (byName != 0) return byName;
        final ap = a['preset_key'] as String? ?? '';
        final bp = b['preset_key'] as String? ?? '';
        if (ap != bp) return ap.compareTo(bp);
        // 同名且同类型（如两个同名用户 Mod）：以 uuid 稳定定序，跨设备一致。
        final au = _modRef(a, modUuidById);
        final bu = _modRef(b, modUuidById);
        if (au != bu) return au.compareTo(bu);
        return (a['sort_order'] as int? ?? 0)
            .compareTo(b['sort_order'] as int? ?? 0);
      });
    return jsonEncode(
      sorted
          .map((bm) => [
                _modName(bm, modNameById),
                bm['preset_key'],
                bm['sort_order'],
                bm['is_enabled'],
              ])
          .toList(),
    );
  }

  /// 单个 Mod 指纹（名称归一化去首尾空白；**不含 created_at / updated_at**）。
  ///
  /// 时间戳每次保存都会刷新（`updateMod` 写 `updated_at = now`），纳入指纹会造成
  /// "内容未变也判定变更"而反复推送（代数 +1）。身份由 uuid 承担，内容仅看字段。
  static String mod(Map<String, Object?> row) {
    return jsonEncode([
      (row['name'] as String? ?? '').trim(),
      row['description'],
      row['pre_prompt'],
      row['post_prompt'],
      row['system_prompt'],
      row['world_book'],
    ]);
  }

  static String _modName(
    Map<String, Object?> bm,
    Map<int, String> modNameById,
  ) {
    final id = bm['mod_id'] as int?;
    if (id == null) return '';
    return modNameById[id] ?? '';
  }

  /// 稳定定序键：预置用 `preset:<key>`，用户 Mod 用 `user:<uuid>`。
  static String _modRef(
    Map<String, Object?> bm,
    Map<int, String> modUuidById,
  ) {
    final presetKey = bm['preset_key'] as String?;
    if (presetKey != null && presetKey.isNotEmpty) return 'preset:$presetKey';
    final id = bm['mod_id'] as int?;
    if (id == null) return 'user:';
    return 'user:${modUuidById[id] ?? ''}';
  }

  static int _asInt(Object? v) => (v is int) ? v : (v is num) ? v.toInt() : 0;
}
