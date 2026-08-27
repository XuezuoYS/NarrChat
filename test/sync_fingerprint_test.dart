import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/sync/sync_fingerprint.dart';

/// 同步内容指纹测试：纯内容（时间戳不参与）、幂等（同内容同指纹）、
/// 区分性（任一内容字段变化 → 指纹变化）、跨设备一致性（id/时间戳无关）。
void main() {
  Map<String, Object?> bookRow({
    String title = '书A',
    String category = '玄幻',
    String postPrompt = '请继续',
    int historyRounds = 3,
    String uuid = 'u-1',
  }) => {
        'id': 1,
        'uuid': uuid,
        'title': title,
        'category': category,
        'base_setting': '',
        'writing_requirements': '',
        'writing_style': '',
        'global_pre_prompt': '',
        'global_post_prompt': postPrompt,
        'history_rounds': historyRounds,
        'role_hierarchy': '',
        'role_hierarchy_detail': '',
        'failed_user_input': '',
        'failed_error_message': '',
        'failed_user_images': '[]',
        'settings_updated_at': 100,
        'rounds_updated_at': 200,
      };

  Map<String, Object?> modRow({
    String name = '风格',
    String prePrompt = 'pre',
    String? createdAt = '2026-01-01T00:00:00.000',
    String? updatedAt = '2026-01-02T00:00:00.000',
    String uuid = 'm-1',
  }) => {
        'id': 1,
        'uuid': uuid,
        'name': name,
        'description': '',
        'pre_prompt': prePrompt,
        'post_prompt': '',
        'system_prompt': '',
        'world_book': '',
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  group('mod 指纹', () {
    test('内容相同但 updated_at 不同 → 指纹相同（时间戳不参与）', () {
      final a = SyncFingerprint.mod(modRow(updatedAt: '2026-01-02T00:00:00.000'));
      final b = SyncFingerprint.mod(modRow(updatedAt: '2026-03-04T05:06:07.000'));
      expect(a, b, reason: '保存刷新 updated_at 不应改变指纹');
    });

    test('created_at 不同 / 行 id 不同 → 指纹相同（跨设备一致）', () {
      final a = SyncFingerprint.mod(modRow(createdAt: '2026-01-01T00:00:00.000'));
      final b = SyncFingerprint.mod(
        modRow(createdAt: '2026-02-02T02:02:02.000'),
      );
      expect(a, b);
    });

    test('任一内容字段变化 → 指纹变化', () {
      final base = SyncFingerprint.mod(modRow());
      expect(SyncFingerprint.mod(modRow(prePrompt: 'pre2')), isNot(base));
      expect(SyncFingerprint.mod(modRow(name: '风格2')), isNot(base));
    });
  });

  group('worldBooks 指纹', () {
    test('内容相同但 created_at 不同 → 指纹相同', () {
      final a = SyncFingerprint.worldBooks([
        {'keyword': '主角', 'content': '内容', 'is_active': 1, 'created_at': '2026-01-01'},
        {'keyword': '反派', 'content': '反派内容', 'is_active': 0, 'created_at': '2026-01-02'},
      ]);
      final b = SyncFingerprint.worldBooks([
        {'keyword': '主角', 'content': '内容', 'is_active': 1, 'created_at': '2026-05-01'},
        {'keyword': '反派', 'content': '反派内容', 'is_active': 0, 'created_at': '2026-05-02'},
      ]);
      expect(a, b);
    });

    test('条目顺序无关（按 keyword 排序）', () {
      final a = SyncFingerprint.worldBooks([
        {'keyword': '主角', 'content': '内容', 'is_active': 1},
        {'keyword': '反派', 'content': '反派内容', 'is_active': 1},
      ]);
      final b = SyncFingerprint.worldBooks([
        {'keyword': '反派', 'content': '反派内容', 'is_active': 1},
        {'keyword': '主角', 'content': '内容', 'is_active': 1},
      ]);
      expect(a, b);
    });
  });

  group('书-Mod 指纹', () {
    const modNames = {1: '风格', 2: '润色'};
    const modUuids = {1: 'u-mod-1', 2: 'u-mod-2'};

    test('相同配置（不同行 id）→ 相同指纹（跨设备一致）', () {
      final a = SyncFingerprint.bookMods(
        [
          {'mod_id': 1, 'preset_key': null, 'sort_order': 0, 'is_enabled': 1},
          {'mod_id': 2, 'preset_key': null, 'sort_order': 1, 'is_enabled': 0},
        ],
        modNames,
        modUuids,
      );
      final b = SyncFingerprint.bookMods(
        [
          {'mod_id': 21, 'preset_key': null, 'sort_order': 0, 'is_enabled': 1},
          {'mod_id': 22, 'preset_key': null, 'sort_order': 1, 'is_enabled': 0},
        ],
        {21: '风格', 22: '润色'},
        {21: 'u-mod-1', 22: 'u-mod-2'},
      );
      expect(a, b);
    });

    test('置入顺序变化 → 指纹变化（顺序是内容）', () {
      final a = SyncFingerprint.bookMods(
        [
          {'mod_id': 1, 'preset_key': null, 'sort_order': 0, 'is_enabled': 1},
          {'mod_id': 2, 'preset_key': null, 'sort_order': 1, 'is_enabled': 1},
        ],
        modNames,
        modUuids,
      );
      final b = SyncFingerprint.bookMods(
        [
          {'mod_id': 2, 'preset_key': null, 'sort_order': 0, 'is_enabled': 1},
          {'mod_id': 1, 'preset_key': null, 'sort_order': 1, 'is_enabled': 1},
        ],
        modNames,
        modUuids,
      );
      expect(a, isNot(b));
    });

    test('同名 Mod 以 uuid 稳定定序（跨设备行 id 不同不漂移）', () {
      final a = SyncFingerprint.bookMods(
        [
          {'mod_id': 1, 'preset_key': null, 'sort_order': 0, 'is_enabled': 1},
          {'mod_id': 2, 'preset_key': null, 'sort_order': 1, 'is_enabled': 1},
        ],
        {1: '同名', 2: '同名'},
        {1: 'u-a', 2: 'u-b'},
      );
      // 另一台设备行 id 不同、插入顺序相反，但 uuid/内容一致 → 排序结果一致。
      final b = SyncFingerprint.bookMods(
        [
          {'mod_id': 32, 'preset_key': null, 'sort_order': 1, 'is_enabled': 1},
          {'mod_id': 31, 'preset_key': null, 'sort_order': 0, 'is_enabled': 1},
        ],
        {31: '同名', 32: '同名'},
        {31: 'u-a', 32: 'u-b'},
      );
      expect(a, b);
    });
  });

  group('设置部件（单部件）与轮次部件（含失败条目）', () {
    test('uuid / 写时间戳不参与设置指纹；任一设置字段变化即变', () {
      final a = SyncFingerprint.bookSettings(bookRow(uuid: 'u-1'));
      final b = SyncFingerprint.bookSettings(bookRow(uuid: 'u-999'));
      expect(a, b, reason: '身份与时间戳不算内容');
      expect(
        SyncFingerprint.bookSettings(bookRow(postPrompt: '改后')),
        isNot(a),
        reason: '后置词变化应改变设置部件指纹',
      );
      expect(
        SyncFingerprint.bookSettings(bookRow(category: '都市')),
        isNot(a),
        reason: '分类变化应改变设置部件指纹（单部件）',
      );
    });

    test('失败条目不属于设置部件，属于轮次部件（随生成内容同步）', () {
      final row = bookRow();
      final failedRow = bookRow()
        ..['failed_user_input'] = '失败输入'
        ..['failed_error_message'] = '失败信息'
        ..['failed_user_images'] = '[]';
      // 失败条目变化不改变设置指纹。
      expect(
        SyncFingerprint.bookSettings(failedRow),
        SyncFingerprint.bookSettings(row),
      );
      // 失败条目变化改变轮次部件指纹。
      final rounds = [
        {'round_index': 1, 'user_input': 'x', 'ai_narrative': 'y'},
      ];
      expect(
        SyncFingerprint.roundsWithFailed(rounds, failedRow),
        isNot(SyncFingerprint.roundsWithFailed(rounds, row)),
      );
      // 轮次新增同样改变轮次部件指纹。
      final roundsMore = [
        {'round_index': 1, 'user_input': 'x', 'ai_narrative': 'y'},
        {'round_index': 2, 'user_input': 'x2', 'ai_narrative': 'y2'},
      ];
      expect(
        SyncFingerprint.roundsWithFailed(roundsMore, row),
        isNot(SyncFingerprint.roundsWithFailed(rounds, row)),
      );
    });

    test('书名变化改变设置部件指纹（改名=设置变更）', () {
      final row = bookRow();
      expect(
        SyncFingerprint.bookSettings(bookRow(title: '书B')),
        isNot(SyncFingerprint.bookSettings(row)),
      );
    });
  });
}
