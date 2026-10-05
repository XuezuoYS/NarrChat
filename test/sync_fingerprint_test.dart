import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/sync/sync_fingerprint.dart';

/// 内容指纹与身份列（uuid）/ 时间戳无关，且任一内容字段变化都会改变指纹。
///
/// 行内引用一律是 uuid（`book_uuid` / `mod_uuid`），没有需要归一化的 int id；
/// `bookMods` 的第二参数是 Mod 的 uuid → 名称映射。
void main() {
  /// 版本树（`round_stack`）一行；内容列与 `rounds` 同形，另有
  /// `father_uuid` / `round_serial_num` / `round_state` / `round_created_at`。
  Map<String, Object?> stackRow({
    String uuid = 'g-1',
    String bookUuid = 'u-1',
    String? fatherUuid,
    int roundIndex = 1,
    int roundSerialNum = 1,
    String? roundState,
    int roundCreatedAt = 1000,
    String userInput = '输入',
    String aiNarrative = '正文',
    String worldState = '',
    String characterState = '',
    String memorySummary = '',
    String currentTime = '',
    String recommendedAction = '',
    int? tokensIn,
    int? tokensOut,
    int? cachedTokensIn,
    String modelName = '',
    String userImages = '[]',
    String aiImages = '[]',
  }) {
    return {
      'uuid': uuid,
      'book_uuid': bookUuid,
      'father_uuid': fatherUuid,
      'round_index': roundIndex,
      'round_serial_num': roundSerialNum,
      'round_state': roundState,
      'round_created_at': roundCreatedAt,
      'user_input': userInput,
      'ai_narrative': aiNarrative,
      'world_state': worldState,
      'character_state': characterState,
      'memory_summary': memorySummary,
      'current_time': currentTime,
      'recommended_action': recommendedAction,
      'tokens_in': tokensIn,
      'tokens_out': tokensOut,
      'cached_tokens_in': cachedTokensIn,
      'model_name': modelName,
      'user_images': userImages,
      'ai_images': aiImages,
    };
  }
  Map<String, Object?> bookRow({
    String uuid = 'u-1',
    String title = '书A',
    String category = '玄幻',
    String postPrompt = '后置',
    int historyRounds = 1,
    int memorySummaryRounds = 0,
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
      'history_rounds': historyRounds,
      'memory_summary_rounds': memorySummaryRounds,
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
      expect(
        SyncFingerprint.bookSettings(bookRow(memorySummaryRounds: 10)),
        isNot(a),
        reason: '记忆总结压缩轮次属于设置部件，改档位必须被检出',
      );
      expect(
        SyncFingerprint.bookSettings(
            bookRow(historyRounds: 1, memorySummaryRounds: 5)),
        isNot(SyncFingerprint.bookSettings(
            bookRow(historyRounds: 1, memorySummaryRounds: 10))),
        reason: '5 / 10 两个档位互不相同',
      );
      expect(
        SyncFingerprint.bookSettings(bookRow(memorySummaryRounds: 7)),
        SyncFingerprint.bookSettings(bookRow(memorySummaryRounds: 0)),
        reason: '越界档位按 0 的执行语义比对，不制造假冲突',
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

  group('版本树摘要（stackDigest）', () {
    test('空表 → 空串（与「无版本树」同一口径）', () {
      expect(SyncFingerprint.stackDigest(const []), '');
    });

    test('行集合 / 内容 / 状态变化 → 摘要变化', () {
      final base = [stackRow()];
      final digest = SyncFingerprint.stackDigest(base);

      expect(
        SyncFingerprint.stackDigest([...base, stackRow(uuid: 'g-2', roundSerialNum: 2)]),
        isNot(digest),
        reason: '新增一代 = 版本树内容变化',
      );
      expect(SyncFingerprint.stackDigest(const []), isNot(digest));
      expect(
        SyncFingerprint.stackDigest([stackRow(userInput: '改后输入')]),
        isNot(digest),
        reason: '内容列（user_input）在摘要内',
      );
      expect(
        SyncFingerprint.stackDigest([stackRow(aiNarrative: '改后正文')]),
        isNot(digest),
      );
      expect(
        SyncFingerprint.stackDigest([
          stackRow(tokensIn: 9, tokensOut: 8, cachedTokensIn: 7, modelName: 'm2'),
        ]),
        isNot(digest),
        reason: 'token / 模型列在摘要内',
      );
      expect(
        SyncFingerprint.stackDigest([stackRow(aiImages: '["img/a.png"]')]),
        isNot(digest),
        reason: '图片列在摘要内（图片同步与版本树一致）',
      );
      expect(
        SyncFingerprint.stackDigest([stackRow(roundState: 'use')]),
        isNot(digest),
        reason: 'round_state 是分组内选中记忆，属内容',
      );
      expect(
        SyncFingerprint.stackDigest([
          stackRow(uuid: 'g-9', roundIndex: 2, roundSerialNum: 3),
        ]),
        isNot(digest),
        reason: '身份 / 分组列（uuid、代数、轮号）参与摘要',
      );
    });

    test('仅 round_created_at 变化 → 摘要不变（时间戳不参与）', () {
      expect(
        SyncFingerprint.stackDigest([stackRow(roundCreatedAt: 1000)]),
        SyncFingerprint.stackDigest([stackRow(roundCreatedAt: 987654321)]),
        reason: '创建时间会随保存刷新，纳入即造成「内容未变也判定变更」的假同步',
      );
    });

    test('与输入顺序无关：乱序 → 相同摘要（按轮号 / 父 / 序号 / uuid 稳定定序）', () {
      final ordered = [
        stackRow(uuid: 'g-1', roundIndex: 1, roundSerialNum: 1, aiNarrative: '一'),
        stackRow(
          uuid: 'g-2',
          fatherUuid: 'g-1',
          roundIndex: 2,
          roundSerialNum: 1,
          aiNarrative: '二',
        ),
        stackRow(uuid: 'g-3', roundIndex: 2, roundSerialNum: 2, aiNarrative: '三'),
      ];
      final shuffled = [ordered[2], ordered[0], ordered[1]];

      expect(
        SyncFingerprint.stackDigest(shuffled),
        SyncFingerprint.stackDigest(ordered),
        reason: '两台设备读出顺序不同（或 INSERT OR REPLACE 改写顺序）不应造成摘要漂移',
      );
      expect(
        SyncFingerprint.stackDigest([...ordered.reversed]),
        SyncFingerprint.stackDigest(ordered),
      );
    });
  });

  group('轮次部件折入版本树（SY-2 / SY-9）', () {
    test('stackRows 变化 → 轮次部件聚合串变化', () {
      final rounds = [
        {'round_index': 1, 'user_input': 'x', 'ai_narrative': 'y'},
      ];
      final book = bookRow();
      final none = SyncFingerprint.roundsWithFailed(rounds, book);
      final withStack = SyncFingerprint.roundsWithFailed(
        rounds,
        book,
        stackRows: [stackRow()],
      );

      expect(withStack, isNot(none), reason: '版本树折进「轮次部件」，不另立同步部件');
      expect(
        SyncFingerprint.roundsWithFailed(
          rounds,
          book,
          stackRows: [stackRow(aiNarrative: '另一代')],
        ),
        isNot(withStack),
      );
      expect(
        SyncFingerprint.roundsWithFailed(rounds, book, stackRows: const []),
        none,
        reason: '空版本树与缺省同口径（空表 → 空摘要）',
      );
    });

    test('带 stack 键的聚合串仍能被 roundRows 解析出轮次行序列（新老客户端相容）', () {
      final rows = [
        {'round_index': 2, 'user_input': '第二', 'ai_narrative': '正文二'},
        {'round_index': 1, 'user_input': '第一', 'ai_narrative': '正文一'},
      ];
      final fp = SyncFingerprint.roundsWithFailed(
        rows,
        bookRow(),
        stackRows: [stackRow()],
      );

      final decoded = jsonDecode(fp) as Map<String, Object?>;
      expect(decoded.keys.toSet(), {'rounds', 'failed', 'stack'},
          reason: '聚合串新增 stack 键，rounds / failed 原样保留');

      final parsed = SyncFingerprint.roundRows(fp);
      expect(parsed, isNotNull, reason: '新增键不得影响解析');
      // 生产侧按 round_index 升序排列后再写入 → 解析出的行序列必然升序
      //（乱序写入的输入在此被规范化，两台设备因此得到同一串）。
      final expected = [
        (1, '第一', '正文一'),
        (2, '第二', '正文二'),
      ].map((e) => _roundRowString(e.$1, e.$2, e.$3)).toList();
      expect(parsed, expected, reason: '解析结果 = 按 round_index 升序的轮次行串序列');
    });

    test('旧格式（无 stack 键）解析结果与今天一致', () {
      final fp = jsonEncode({
        'rounds': [_roundRowString(1, 'x', 'y')],
        'failed': ['', '', '[]'],
      });

      expect(
        SyncFingerprint.roundRows(fp),
        [_roundRowString(1, 'x', 'y')],
        reason: '老格式（历史同步数据）必须原样解析',
      );
      expect(
        SyncFingerprint.roundRows(_roundRowString(1, 'x', 'y')),
        isNull,
        reason: '整串不是对象 → 不可解析（调用方按整串语义处理）',
      );
      expect(
        SyncFingerprint.roundRows('{"rounds": [1, 2]}'),
        isNull,
        reason: '行内容非字符串 → 不可解析',
      );
    });
  });
}

/// 单条轮次行串（与 [SyncFingerprint.round] 同形）：供 `roundRows` 断言比对。
///
/// 用 jsonEncode 复刻而非调用 `round`，使「解析出的行内容」与「写入时的行内容」
/// 分别独立成立（避免用例自证）。
String _roundRowString(int roundIndex, String userInput, String aiNarrative) {
  return jsonEncode([
    roundIndex,
    userInput,
    aiNarrative,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
  ]);
}
