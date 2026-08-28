import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/sync/sync_action_planner.dart';
import 'package:narrchat/services/sync/sync_fingerprint.dart';
import 'package:narrchat/services/sync/sync_local_snapshot.dart';
import 'package:narrchat/services/sync/sync_merge_planner.dart';

/// 轮次部件同步策略（用户定的极简规则）：
/// - **单纯增**（一侧与共基一致、另一侧在其后追加若干轮）→ 自动推/拉，不弹页；
/// - **有冲突**（双方都改）→ 一律弹页让用户决策——**即使双方都只是后续新增**
///   （同位置各加一轮也算冲突），不做任何自动并集；
/// - 唯一例外：双方**轮次内容逐行完全一致**、只差失败条目草稿 → 视为纯增量，
///   自动推本地（对端下次同步拉取），不弹页；
/// - 设置类部件（书籍设置 / 世界书 / 书-Mod）或已有 Mod **仅云端改过** →
///   需人工确认（needsReview），与真冲突共用同一条确认通道。
void main() {
  Map<String, Object?> row(int idx, {String text = 't', String input = 'u'}) =>
      {
        'round_index': idx,
        'user_input': input,
        'ai_narrative': text,
        'world_state': '',
        'character_state': '',
        'memory_summary': '',
        'current_time': '',
        'recommended_action': '',
        'tokens_in': 0,
        'tokens_out': 0,
        'model_name': '',
        'user_images': '[]',
        'ai_images': '[]',
      };

  Map<String, Object?> bookRow({String failedInput = ''}) => {
        'failed_user_input': failedInput,
        'failed_error_message': '',
        'failed_user_images': '[]',
      };

  String fp(
    List<Map<String, Object?>> rows, {
    String failedInput = '',
  }) =>
      SyncFingerprint.roundsWithFailed(rows, bookRow(failedInput: failedInput));

  final base = fp([row(0, text: 'c0'), row(1, text: 'c1')]);

  SyncMergePlan planOf({
    required String baseRounds,
    required String localRounds,
    required String remoteRounds,
    String settingsLocal = 'S0',
    String settingsRemote = 'S0',
    String worldBookLocal = '',
    String worldBookRemote = '',
  }) =>
      SyncMergePlanner.plan(
        base: {
          'u1': SyncBookBaseParts(
            title: '书A',
            settingsFp: 'S0',
            roundsFp: baseRounds,
          ),
        },
        local: {
          'u1': SyncBookRecord(
            uuid: 'u1',
            title: '书A',
            parts: SyncBookParts(
              settingsFp: settingsLocal,
              roundsFp: localRounds,
              worldBookFp: worldBookLocal,
            ),
          ),
        },
        remote: {
          'u1': RemoteBookParts(
            uuid: 'u1',
            title: '书A',
            settingsFp: settingsRemote,
            roundsFp: remoteRounds,
            worldBookFp: worldBookRemote,
          ),
        },
        localMods: const {},
        remoteMods: const {},
        baseMods: const {},
      );

  BookSyncDecision roundsOf({
    required String baseRounds,
    required String localRounds,
    required String remoteRounds,
  }) =>
      planOf(
        baseRounds: baseRounds,
        localRounds: localRounds,
        remoteRounds: remoteRounds,
      ).books.single;

  group('轮次部件：只有单纯增自动，其余一律交用户', () {
    test('单纯增：本地与基一致、云端多 m 轮 → remoteOnly 自动拉（不确认）', () {
      final appended =
          fp([row(0, text: 'c0'), row(1, text: 'c1'), row(2, text: '新')]);
      final d = roundsOf(
          baseRounds: base, localRounds: base, remoteRounds: appended);
      expect(d.rounds, SyncPartStatus.remoteOnly);
      expect(d.hasConflict, isFalse);
      expect(d.needsReview, isFalse, reason: '轮次纯增量不进确认通道');
    });

    test('单纯增（反向）：本地多轮、云端与基一致 → localOnly 自动推', () {
      final appended =
          fp([row(0, text: 'c0'), row(1, text: 'c1'), row(2, text: '新')]);
      final d = roundsOf(
          baseRounds: base, localRounds: appended, remoteRounds: base);
      expect(d.rounds, SyncPartStatus.localOnly);
      expect(d.hasConflict, isFalse);
    });

    test('双方同位置各加一轮（都是后续新增）→ 也判冲突，用户决策', () {
      final x =
          fp([row(0, text: 'c0'), row(1, text: 'c1'), row(2, text: 'A2')]);
      final y =
          fp([row(0, text: 'c0'), row(1, text: 'c1'), row(2, text: 'B2')]);
      final d = roundsOf(baseRounds: base, localRounds: x, remoteRounds: y);
      expect(d.rounds, SyncPartStatus.conflict);
      expect(d.hasConflict, isTrue);
    });

    test('双方各加不同数量轮（前缀重合但云端更长）→ 冲突（不做并集）', () {
      final l = fp([row(0, text: 'c0'), row(1, text: 'c1'), row(2, text: 'A2')]);
      final r = fp([
        row(0, text: 'c0'),
        row(1, text: 'c1'),
        row(2, text: 'B2'),
        row(3, text: 'B3'),
      ]);
      final d = roundsOf(baseRounds: base, localRounds: l, remoteRounds: r);
      expect(d.rounds, SyncPartStatus.conflict);
    });

    test('同一轮双端改出不同内容 / 删除 vs 修改 → 冲突', () {
      final lEdit = fp([row(0, text: 'c0'), row(1, text: '本地改')]);
      final rEdit = fp([row(0, text: 'c0'), row(1, text: '云端改')]);
      expect(
          roundsOf(baseRounds: base, localRounds: lEdit, remoteRounds: rEdit)
              .rounds,
          SyncPartStatus.conflict);

      final lDel = fp([row(0, text: 'c0')]);
      expect(
          roundsOf(baseRounds: base, localRounds: lDel, remoteRounds: rEdit)
              .rounds,
          SyncPartStatus.conflict);
    });

    test('双端改出完全相同（同改 / 同增 / 同删）→ unchanged 静默', () {
      final same = fp([row(0, text: 'c0'), row(1, text: '一样改')]);
      expect(
          roundsOf(baseRounds: base, localRounds: same, remoteRounds: same)
              .rounds,
          SyncPartStatus.unchanged);
    });

    test('一侧删除、另一侧未动 → localOnly/remoteOnly 按现状传播删除', () {
      final lDel = fp([row(0, text: 'c0')]);
      expect(
          roundsOf(baseRounds: base, localRounds: lDel, remoteRounds: base)
              .rounds,
          SyncPartStatus.localOnly);
      expect(
          roundsOf(baseRounds: base, localRounds: base, remoteRounds: lDel)
              .rounds,
          SyncPartStatus.remoteOnly);
    });

    test('失败条目单侧漂移 → 现状流转；双侧漂移但轮次逐行一致 → 纯增量自动推', () {
      final rows = [row(0, text: 'c0'), row(1, text: 'c1')];
      final lFailed = fp(rows, failedInput: '坏输入');
      expect(
          roundsOf(
                  baseRounds: base, localRounds: lFailed, remoteRounds: base)
              .rounds,
          SyncPartStatus.localOnly);
      expect(
          roundsOf(
                  baseRounds: base, localRounds: base, remoteRounds: lFailed)
              .rounds,
          SyncPartStatus.remoteOnly);
      // 双端各自改失败草稿、轮次内容零差异 → 不弹页，自动推本地（对端随后拉取）。
      final rFailed = fp(rows, failedInput: '对端坏输入');
      final both =
          roundsOf(baseRounds: base, localRounds: lFailed, remoteRounds: rFailed);
      expect(both.rounds, SyncPartStatus.localOnly);
      expect(both.hasConflict, isFalse);
    });

    test('失败草稿不同且轮次也有分歧 → 仍是冲突（例外不越界）', () {
      final l = fp([row(0, text: 'c0'), row(1, text: 'c1')], failedInput: '甲');
      final r = fp([row(0, text: 'c0'), row(2, text: '多删一轮')], failedInput: '乙');
      expect(
          roundsOf(baseRounds: base, localRounds: l, remoteRounds: r).rounds,
          SyncPartStatus.conflict);
    });

    test('旧格式/损坏聚合串（不可解析）→ 维持整串冲突现状', () {
      expect(
          roundsOf(baseRounds: 'R12', localRounds: 'R12A', remoteRounds: 'R12B')
              .rounds,
          SyncPartStatus.conflict);
    });
  });

  group('设置类变更确认通道（动作路由）', () {
    test('书籍设置仅云端改 → 需人工确认：进冲突通道、不进拉取清单', () {
      final plan = planOf(
        baseRounds: base,
        localRounds: base,
        remoteRounds: base,
        settingsRemote: 'S9',
      );
      expect(plan.books.single.needsReview, isTrue);
      expect(plan.needsReview, isTrue);
      final a = SyncActionPlanner.plan(mergePlan: plan);
      expect(a.hasConflict, isTrue);
      expect(a.conflictBookUuids, contains('u1'));
      expect(a.pullBookUuids, isEmpty, reason: '不再静默应用云端设置');
    });

    test('世界书仅云端改 → 确认；轮次仅云端新增 → 仍自动拉取', () {
      final wb = planOf(
        baseRounds: base,
        localRounds: base,
        remoteRounds: base,
        worldBookRemote: 'W9',
      );
      expect(SyncActionPlanner.plan(mergePlan: wb).hasConflict, isTrue);

      final added =
          fp([row(0, text: 'c0'), row(1, text: 'c1'), row(2, text: '新')]);
      final roundsPull =
          planOf(baseRounds: base, localRounds: base, remoteRounds: added);
      final a = SyncActionPlanner.plan(mergePlan: roundsPull);
      expect(a.hasConflict, isFalse);
      expect(a.pullBookUuids, ['u1']);
    });

    test('Mod：已有仅云端改内容 → 确认；全新 Mod → 自动拉取', () {
      final existing = SyncMergePlanner.plan(
        base: const {},
        local: const {},
        remote: const {},
        localMods: const {
          'm1': SyncModRecord(uuid: 'm1', name: '风格', fingerprint: 'F1'),
        },
        remoteMods: const {
          'm1': RemoteModParts(uuid: 'm1', name: '风格', fingerprint: 'F2'),
        },
        baseMods: const {
          'm1': SyncModBaseParts(name: '风格', fingerprint: 'F1'),
        },
      );
      expect(existing.mods.single.needsReview, isTrue);
      final a = SyncActionPlanner.plan(mergePlan: existing);
      expect(a.hasConflict, isTrue);
      expect(a.pullModUuids, isEmpty);
      expect(a.conflictModUuids, contains('m1'));

      final fresh = SyncMergePlanner.plan(
        base: const {},
        local: const {},
        remote: const {},
        localMods: const {},
        remoteMods: const {
          'm9': RemoteModParts(uuid: 'm9', name: '新Mod', fingerprint: 'F9'),
        },
        baseMods: const {},
      );
      final b = SyncActionPlanner.plan(mergePlan: fresh);
      expect(b.hasConflict, isFalse);
      expect(b.pullModUuids, ['m9']);
    });

    test('轮次冲突与设置确认并存 → 同一本书进一次确认通道', () {
      final x =
          fp([row(0, text: 'c0'), row(1, text: 'c1'), row(2, text: 'A2')]);
      final y =
          fp([row(0, text: 'c0'), row(1, text: 'c1'), row(2, text: 'B2')]);
      final plan = planOf(
        baseRounds: base,
        localRounds: x,
        remoteRounds: y,
        settingsRemote: 'S9',
      );
      final a = SyncActionPlanner.plan(mergePlan: plan);
      expect(a.hasConflict, isTrue);
      expect(a.conflictBookUuids.where((u) => u == 'u1'), hasLength(1));
    });
  });
}
