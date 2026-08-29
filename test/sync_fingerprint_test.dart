import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/sync/sync_fingerprint.dart';

/// 内容指纹与身份列（uuid）/ 时间戳无关，且任一内容字段变化都会改变指纹。
///
/// 行内引用一律是 uuid（`book_uuid` / `mod_uuid`），没有需要归一化的 int id；
/// `bookMods` 的第二参数是 Mod 的 uuid → 名称映射。
void main() {
  Map<String, Object?> bookRow({
    String uuid = 'u-1',
    String title = '书A',
    String category = '玄幻',
    String postPrompt = '后置',
    int settingsAt = 1000,
    int roundsAt = 2000,
  }) {
    return {
      'uuid': uuid,
      'title': title,
      'category': category,
      'base_setting': '',
      'writing_style': '',
      'writing_requirements': '',
      'global_pre_prompt': '',
      'global_post_prompt': postPrompt,
      'history_rounds': 1,
      'role_hierarchy': '',
      'settings_updated_at': settingsAt,
      'rounds_updated_at': roundsAt,
    };
  }

  Map<String, Object?> modRow({
    String uuid = 'u-mod-1',
    String name = '风格',
    String prePrompt = 'pre',
    String createdAt = '2026-01-01T00:00:00.000',
    String updatedAt = '2026-01-02T00:00:00.000',
  }) {
    return {
      'uuid': uuid,
      'name': name,
      'pre_prompt': prePrompt,
      'post_prompt': 'post',
      'system_prompt': 'sys',
      'description': '',
      'world_book': '[]',
      'created_at': createdAt,
      'updated_at': updatedAt,
    };
  }

  group('Mod 部件（按 uuid 定名）', () {
    test('created_at 不同 / uuid 不同 → 指纹相同（跨设备一致）', () {
      final a = SyncFingerprint.mod(modRow(updatedAt: '2026-01-02T00:00:00.000'));
      final b = SyncFingerprint.mod(modRow(updatedAt: '2026-03-04T05:06:07.000'));
      expect(a, b);
      expect(
        SyncFingerprint.mod(modRow(createdAt: '2026-02-02T00:00:00.000')),
        a,
        reason: '时间戳每次保存都刷新，纳入会造成假变更',
      );
      expect(
        SyncFingerprint.mod(modRow(uuid: 'u-mod-other')),
        a,
        reason: 'uuid 是身份、不入内容指纹（实体分组只按 uuid）',
      );
    });

    test('内容字段变化 → 指纹变化', () {
      final base = SyncFingerprint.mod(modRow());
      expect(SyncFingerprint.mod(modRow(prePrompt: 'pre2')), isNot(base));
      expect(SyncFingerprint.mod(modRow(name: '风格2')), isNot(base));
    });
  });

  group('书-Mod 部件', () {
    // Mod 的 uuid → 名称：身份是 uuid，名称是内容。
    const modNames = {'u-mod-1': '风格', 'u-mod-2': '润色'};

    test('相同配置（行顺序不同）→ 相同指纹（跨设备一致）', () {
      final a = SyncFingerprint.bookMods(
        [
          {
            'mod_uuid': 'u-mod-1',
            'preset_key': null,
            'sort_order': 0,
            'is_enabled': 1
          },
          {
            'mod_uuid': 'u-mod-2',
            'preset_key': null,
            'sort_order': 1,
            'is_enabled': 0
          },
        ],
        modNames,
      );
      // 另一台设备：行内容一致，只是读出的先后顺序不同。
      final b = SyncFingerprint.bookMods(
        [
          {
            'mod_uuid': 'u-mod-2',
            'preset_key': null,
            'sort_order': 1,
            'is_enabled': 0
          },
          {
            'mod_uuid': 'u-mod-1',
            'preset_key': null,
            'sort_order': 0,
            'is_enabled': 1
          },
        ],
        modNames,
      );
      expect(a, b);
    });

    test('置入顺序变化 → 指纹变化（顺序是内容）', () {
      final a = SyncFingerprint.bookMods(
        [
          {
            'mod_uuid': 'u-mod-1',
            'preset_key': null,
            'sort_order': 0,
            'is_enabled': 1
          },
          {
            'mod_uuid': 'u-mod-2',
            'preset_key': null,
            'sort_order': 1,
            'is_enabled': 1
          },
        ],
        modNames,
      );
      final b = SyncFingerprint.bookMods(
        [
          {
            'mod_uuid': 'u-mod-1',
            'preset_key': null,
            'sort_order': 1,
            'is_enabled': 1
          },
          {
            'mod_uuid': 'u-mod-2',
            'preset_key': null,
            'sort_order': 0,
            'is_enabled': 1
          },
        ],
        modNames,
      );
      expect(a, isNot(b));
    });

    test('同名 Mod 以 uuid 稳定定序（行顺序不同也不漂移）', () {
      final a = SyncFingerprint.bookMods(
        [
          {
            'mod_uuid': 'u-a',
            'preset_key': null,
            'sort_order': 0,
            'is_enabled': 1
          },
          {
            'mod_uuid': 'u-b',
            'preset_key': null,
            'sort_order': 1,
            'is_enabled': 1
          },
        ],
        const {'u-a': '同名', 'u-b': '同名'},
      );
      // 另一台设备读出顺序相反，但 uuid/内容一致 → 排序结果一致。
      final b = SyncFingerprint.bookMods(
        [
          {
            'mod_uuid': 'u-b',
            'preset_key': null,
            'sort_order': 1,
            'is_enabled': 1
          },
          {
            'mod_uuid': 'u-a',
            'preset_key': null,
            'sort_order': 0,
            'is_enabled': 1
          },
        ],
        const {'u-a': '同名', 'u-b': '同名'},
      );
      expect(a, b);
    });

    test('名称按 mod_uuid 查表：映射键必须是 uuid', () {
      final rows = [
        {
          'mod_uuid': 'u-mod-1',
          'preset_key': null,
          'sort_order': 0,
          'is_enabled': 1
        },
      ];
      expect(
        SyncFingerprint.bookMods(rows, const {'u-mod-1': '风格'}),
        isNot(SyncFingerprint.bookMods(rows, const {'u-mod-1': '风格2'})),
        reason: 'Mod 名称是内容，改名改变书-Mod 部件指纹',
      );
      expect(
        SyncFingerprint.bookMods(rows, const {'风格': '风格'}),
        isNot(SyncFingerprint.bookMods(rows, const {'u-mod-1': '风格'})),
        reason: '按非 uuid 键查不到名称 → 退化为空串',
      );
      expect(
        SyncFingerprint.bookMods(rows, const {}),
        SyncFingerprint.bookMods(
          [
            {
              'preset_key': null,
              'sort_order': 0,
              'is_enabled': 1
            }, // 预置行：无 mod_uuid
          ],
          const {},
        ),
        reason: '无 mod_uuid 的行名称恒为空串，与查不到同一口径',
      );
    });
  });

  group('设置部件（单部件）与轮次部件（含失败条目）', () {
    test('uuid / 写时间戳不参与设置指纹；任一设置字段变化即变', () {
      final a = SyncFingerprint.bookSettings(bookRow(uuid: 'u-1'));
      final b = SyncFingerprint.bookSettings(bookRow(uuid: 'u-999'));
      expect(a, b, reason: '身份与时间戳不算内容');
      expect(
        SyncFingerprint.bookSettings(
            bookRow(uuid: 'u-999', settingsAt: 123, roundsAt: 456)),
        a,
        reason: '时间戳每次保存都刷新，纳入即造成假变更',
      );
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

  group('轮次部件', () {
    test('与顺序无关：同内容乱序 → 相同指纹', () {
      final a = [
        {'round_index': 1, 'user_input': 'x', 'ai_narrative': 'y'},
        {'round_index': 2, 'user_input': 'x2', 'ai_narrative': 'y2'},
      ];
      final b = [
        {'round_index': 2, 'user_input': 'x2', 'ai_narrative': 'y2'},
        {'round_index': 1, 'user_input': 'x', 'ai_narrative': 'y'},
      ];
      final book = bookRow();
      expect(
        SyncFingerprint.roundsWithFailed(a, book),
        SyncFingerprint.roundsWithFailed(b, book),
      );
    });

    test('内容不同 → 指纹不同', () {
      final book = bookRow();
      expect(
        SyncFingerprint.roundsWithFailed(
          [
            {'round_index': 1, 'user_input': 'x', 'ai_narrative': '改后'},
          ],
          book,
        ),
        isNot(SyncFingerprint.roundsWithFailed(
          [
            {'round_index': 1, 'user_input': 'x', 'ai_narrative': '原'},
          ],
          book,
        )),
      );
    });
  });

  group('世界书部件', () {
    test('按 keyword 排序，与写入顺序无关；内容变化则变', () {
      final a = [
        {'keyword': 'b', 'content': '1', 'is_active': 1},
        {'keyword': 'a', 'content': '2', 'is_active': 1},
      ];
      final b = [
        {'keyword': 'a', 'content': '2', 'is_active': 1},
        {'keyword': 'b', 'content': '1', 'is_active': 1},
      ];
      expect(SyncFingerprint.worldBooks(a), SyncFingerprint.worldBooks(b));
      final c = [
        {'keyword': 'a', 'content': '改', 'is_active': 1},
        {'keyword': 'b', 'content': '1', 'is_active': 1},
      ];
      expect(SyncFingerprint.worldBooks(a), isNot(SyncFingerprint.worldBooks(c)));
    });
  });
}
