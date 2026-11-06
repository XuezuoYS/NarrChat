import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/branch.dart';
import 'package:narrchat/models/branch_father_snapshot.dart';
import 'package:narrchat/models/round_generation.dart';
import 'package:narrchat/services/branch_rules.dart';

/// 分支与代数操作的纯规则测试（建分支 / 删代 / 删轮次 / 孤儿清理）。
void main() {
  final epoch = DateTime.utc(2026, 1, 1);

  RoundMeta meta(
    String uuid, {
    String? father,
    String branch = '',
    int index = 1,
    int serial = 1,
    bool using = false,
  }) {
    return RoundMeta(
      uuid: uuid,
      fatherUuid: father,
      branchUuid: branch,
      roundIndex: index,
      roundSerialNum: serial,
      isUsing: using,
      operatedAt: epoch,
    );
  }

  group('nextRoundIndex', () {
    test('有链尾时取链尾 +1', () {
      final chain = [
        meta('a', index: 3, using: true),
        meta('b', father: 'a', index: 4, using: true),
      ];
      expect(BranchRules.nextRoundIndex(chain: chain), 5);
    });

    test('空分支：分叉点轮号 +1', () {
      final branch = Branch(
        branchUuid: 'br1',
        fatherRow: 'm2',
        fatherRowIndex: 2,
        branchName: '如果',
        createdAt: epoch,
        updatedAt: epoch,
      );
      expect(BranchRules.nextRoundIndex(chain: const [], branch: branch), 3);
    });

    test('默认分支空链从第 1 轮开始', () {
      expect(BranchRules.nextRoundIndex(chain: const []), 1);
    });
  });

  group('forkPointOf', () {
    Branch branch({
      String fatherRow = 'm2',
      int fatherRowIndex = 2,
      String shot = '',
    }) {
      return Branch(
        branchUuid: 'br1',
        fatherRow: fatherRow,
        fatherRowIndex: fatherRowIndex,
        branchName: '如果',
        fatherRowShot: shot,
        createdAt: epoch,
        updatedAt: epoch,
      );
    }

    test('父代还在：序号取库里的 round_serial_num', () {
      final point = BranchRules.forkPointOf(
        branch(),
        [meta('m2', index: 2, serial: 3, using: false)],
      );
      expect(point, isNotNull);
      expect(point!.fatherUuid, 'm2');
      expect(point.roundIndex, 2);
      expect(point.generationSerial, 3);
      expect(point.alive, isTrue);
    });

    test('父代已删：序号回落到 father_row_shot 快照', () {
      final from = RoundGeneration(
        meta: meta('m2', index: 2, serial: 5),
        userInput: '问',
        aiNarrative: '答',
      );
      final point = BranchRules.forkPointOf(
        branch(shot: BranchFatherSnapshot.encode(from)),
        const [],
      );
      expect(point, isNotNull);
      expect(point!.fatherUuid, 'm2');
      expect(point.roundIndex, 2);
      expect(point.generationSerial, 5);
      expect(point.alive, isFalse);
    });

    test('父代已删且快照无效：仍给出轮号与 uuid，序号为 null', () {
      final point = BranchRules.forkPointOf(branch(shot: 'not-json'), const []);
      expect(point, isNotNull);
      expect(point!.alive, isFalse);
      expect(point.generationSerial, isNull);
      expect(point.roundIndex, 2);
    });

    test('默认分支 / 缺父代数据返回 null', () {
      expect(BranchRules.forkPointOf(Branch.defaultBranch(), const []), isNull);
      expect(BranchRules.forkPointOf(branch(fatherRow: ''), const []), isNull);
    });
  });

  group('planFork', () {
    test('记录分叉点与父代快照，快照可还原一轮', () {
      final from = RoundGeneration(
        meta: meta('m2', index: 2, using: true),
        userInput: '问',
        aiNarrative: '答',
        userImages: const ['img/a.png'],
      );
      final branch = BranchRules.planFork(
        from: from,
        branchUuid: 'br1',
        branchName: '如果',
        now: epoch,
      );

      expect(branch.branchUuid, 'br1');
      expect(branch.fatherRow, 'm2');
      expect(branch.fatherRowIndex, 2);
      expect(branch.fatherBranch, '');
      expect(branch.branchWorking, isTrue);

      final restored = BranchFatherSnapshot.decode(branch.fatherRowShot)!;
      expect(restored.uuid, 'm2');
      expect(restored.roundIndex, 2);
      expect(restored.userInput, '问');
      expect(restored.aiNarrative, '答');
      expect(restored.userImages, ['img/a.png']);
    });

    test('空 uuid 直接拒绝', () {
      expect(
        () => BranchRules.planFork(
          from: RoundGeneration(meta: meta('m1')),
          branchUuid: '',
          branchName: 'x',
          now: epoch,
        ),
        throwsArgumentError,
      );
    });
  });

  group('planVersionOf', () {
    test('同组序号取最大 +1，沿用父代与轮号', () {
      final all = [
        meta('g1', index: 2, serial: 1),
        meta('g2', index: 2, serial: 4),
        meta('g3', index: 2, serial: 2),
      ];
      final plan = BranchRules.planVersionOf(
        target: all.first,
        all: all,
        uuid: 'g5',
        now: epoch,
      );
      expect(plan.uuid, 'g5');
      expect(plan.roundIndex, 2);
      expect(plan.roundSerialNum, 5);
      expect(plan.isUsing, isTrue);
      expect(plan.fatherUuid, isNull);
    });
  });

  group('planDeleteGeneration', () {
    test('删中间一代：后代子树一起删，回落到前一代', () {
      final all = [
        meta('g1', index: 1, serial: 1),
        meta('g2', index: 1, serial: 2, using: true),
        meta('g3', index: 1, serial: 3),
        meta('n1', father: 'g2', index: 2, using: true),
        meta('n2', father: 'n1', index: 3, using: true),
        meta('x1', father: 'g3', index: 2, using: true),
      ];
      final plan =
          BranchRules.planDeleteGeneration(target: all[1], all: all);
      expect(plan.isRefused, isFalse);
      expect(
        plan.uuidsToDelete.toSet(),
        {'g2', 'n1', 'n2'},
        reason: '只带走 g2 的后代，g3 那条线不受影响',
      );
      expect(plan.fallbackUuid, 'g1');
    });

    test('删第一代：前面没有代，回落到后一代', () {
      final all = [
        meta('g1', index: 1, serial: 1, using: true),
        meta('g2', index: 1, serial: 2),
      ];
      final plan = BranchRules.planDeleteGeneration(target: all[0], all: all);
      expect(plan.fallbackUuid, 'g2');
    });

    test('唯一一代：拒绝删除并提示改用删除本轮', () {
      final all = [meta('g1', index: 1, serial: 1, using: true)];
      final plan = BranchRules.planDeleteGeneration(target: all[0], all: all);
      expect(plan.isRefused, isTrue);
      expect(plan.uuidsToDelete, isEmpty);
      expect(plan.refusal, contains('删除本轮'));
    });

    test('只影响同组，不碰同轮号但父代不同的代', () {
      final all = [
        meta('a1', index: 2, serial: 1, using: true),
        meta('a2', index: 2, serial: 2),
        meta('b1', father: 'other', index: 2, serial: 1, using: true),
      ];
      final plan = BranchRules.planDeleteGeneration(target: all[0], all: all);
      expect(plan.uuidsToDelete, ['a1']);
      expect(plan.fallbackUuid, 'a2');
    });
  });

  group('planDeleteRound', () {
    test('删该轮及之后全部代，并带走由此不可达的行', () {
      final all = [
        meta('r1', index: 1, using: true),
        meta('r2', father: 'r1', index: 2, using: true),
        meta('r2b', father: 'r1', index: 2, serial: 2),
        meta('r3', father: 'r2', index: 3, using: true),
        meta('b1', branch: 'br1', index: 3, using: true),
      ];
      final doomed =
          BranchRules.planDeleteRound(all: all, branchUuid: '', fromRoundIndex: 2);
      expect(doomed.toSet(), {'r2', 'r2b', 'r3'});
      expect(doomed.contains('b1'), isFalse, reason: '别的分支不动');
    });

    test('从第一轮删：整条链清空', () {
      final all = [
        meta('r1', index: 1, using: true),
        meta('r2', father: 'r1', index: 2, using: true),
      ];
      expect(
        BranchRules.planDeleteRound(all: all, branchUuid: '', fromRoundIndex: 1)
            .toSet(),
        {'r1', 'r2'},
      );
    });

    test('没有命中返回空', () {
      final all = [meta('r1', index: 1, using: true)];
      expect(
        BranchRules.planDeleteRound(
          all: all,
          branchUuid: 'nope',
          fromRoundIndex: 1,
        ),
        isEmpty,
      );
    });
  });

  group('planDeleteBranch', () {
    test('只删该分支的轮次行', () {
      final all = [
        meta('m1', index: 1, using: true),
        meta('b1', branch: 'br1', index: 2, using: true),
        meta('b2', branch: 'br1', father: 'b1', index: 3, using: true),
      ];
      expect(
        BranchRules.planDeleteBranch(all: all, branchUuid: 'br1').toSet(),
        {'b1', 'b2'},
      );
    });

    test('默认分支不可删', () {
      expect(
        () => BranchRules.planDeleteBranch(all: const [], branchUuid: ''),
        throwsArgumentError,
      );
    });
  });

  group('planPurgeOrphans', () {
    test('父代不存在的行被找出，根不受影响', () {
      final all = [
        meta('root', index: 1, using: true),
        meta('ok', father: 'root', index: 2, using: true),
        meta('lost', father: 'ghost', index: 5, using: true),
      ];
      expect(BranchRules.planPurgeOrphans(all), ['lost']);
    });

    test('干净数据没有孤儿', () {
      final all = [
        meta('root', index: 1, using: true),
        meta('ok', father: 'root', index: 2, using: true),
      ];
      expect(BranchRules.planPurgeOrphans(all), isEmpty);
    });
  });

  group('subtreeOf', () {
    test('包含自身与全部后代', () {
      final all = [
        meta('a', index: 1, using: true),
        meta('b', father: 'a', index: 2, using: true),
        meta('c', father: 'b', index: 3, using: true),
        meta('d', index: 1, serial: 2),
      ];
      expect(BranchRules.subtreeOf(all[0], all).toSet(), {'a', 'b', 'c'});
      expect(BranchRules.subtreeOf(all[3], all), ['d']);
    });
  });
}
