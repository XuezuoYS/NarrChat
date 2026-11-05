import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/branch.dart';
import 'package:narrchat/models/branch_father_snapshot.dart';
import 'package:narrchat/models/round_generation.dart';
import 'package:narrchat/services/round_tree.dart';

/// 活动链解析与跨分支上溯的纯函数测试。
void main() {
  final epoch = DateTime.utc(2026, 1, 1);

  RoundMeta meta(
    String uuid, {
    String? father,
    String branch = '',
    int index = 1,
    int serial = 1,
    bool using = false,
    String status = '',
  }) {
    return RoundMeta(
      uuid: uuid,
      fatherUuid: father,
      branchUuid: branch,
      roundIndex: index,
      roundSerialNum: serial,
      isUsing: using,
      operatedAt: epoch,
      messageStatus: status,
    );
  }

  RoundGeneration generation(RoundMeta m, {String narrative = ''}) =>
      RoundGeneration(meta: m, aiNarrative: narrative);

  group('planChain', () {
    test('单链：跟着父指针从链首走到链尾', () {
      final all = [
        meta('g1', index: 1, using: true),
        meta('g2', father: 'g1', index: 2, using: true),
        meta('g3', father: 'g2', index: 3, using: true),
      ];
      expect(
        RoundTree.planChain(all, '').map((e) => e.uuid),
        ['g1', 'g2', 'g3'],
      );
    });

    test('组内多代：is_using 优先，其余代不出现', () {
      final all = [
        meta('g1', index: 1, serial: 1, using: true),
        meta('g2', index: 1, serial: 2, using: false),
        meta('g3', index: 1, serial: 3, using: false),
      ];
      expect(RoundTree.planChain(all, '').map((e) => e.uuid), ['g1']);
    });

    test('组内没有 is_using：取序号最大者', () {
      final all = [
        meta('g1', index: 1, serial: 1),
        meta('g2', index: 1, serial: 5),
        meta('g3', index: 1, serial: 3),
      ];
      expect(RoundTree.planChain(all, '').map((e) => e.uuid), ['g2']);
    });

    test('链尾没有子代就结束，后面的轮次不算进来', () {
      final all = [
        meta('g1', index: 1, using: true),
        meta('g2', father: 'g1', index: 2, using: true),
        // g3 挂在 g2 的另一个版本下，当前链看不到。
        meta('g2b', index: 2, serial: 2),
        meta('g3', father: 'g2b', index: 3, using: true),
      ];
      expect(
        RoundTree.planChain(all, '').map((e) => e.uuid),
        ['g1', 'g2'],
      );
    });

    test('轮号断裂也按父指针接上', () {
      final all = [
        meta('g1', index: 1, using: true),
        meta('g2', father: 'g1', index: 2, using: true),
        meta('g50', father: 'g2', index: 50, using: true),
      ];
      final chain = RoundTree.planChain(all, '');
      expect(chain.map((e) => e.uuid), ['g1', 'g2', 'g50']);
      expect(chain.last.roundIndex, 50);
      expect(RoundTree.nextRoundIndex(chain), 51);
    });

    test('分支隔离：别的分支的根不会被带进来', () {
      final all = [
        meta('m1', index: 1, using: true),
        meta('m2', father: 'm1', index: 2, using: true),
        meta('b1', branch: 'br1', index: 4, using: true),
        meta('b2', branch: 'br1', father: 'b1', index: 5, using: true),
      ];
      expect(RoundTree.planChain(all, '').map((e) => e.uuid), ['m1', 'm2']);
      expect(RoundTree.planChain(all, 'br1').map((e) => e.uuid), ['b1', 'b2']);
    });

    test('空分支返回空链', () {
      expect(RoundTree.planChain([meta('m1', using: true)], 'br1'), isEmpty);
    });

    test('脏数据成环也能停下来', () {
      final all = [
        meta('a', index: 1, using: true),
        meta('b', father: 'a', index: 2, using: true),
        // 把 a 的父指向 b —— 正常不会出现，但不能死循环。
        meta('a2', father: 'b', index: 3, using: true),
        meta('b2', father: 'a2', index: 4, using: true),
      ];
      final chain = RoundTree.planChain(all, '');
      expect(chain.length, lessThanOrEqualTo(4));
      expect(chain.first.uuid, 'a');
    });
  });

  group('usingConflicts', () {
    test('同组多个 is_using 会被检出，保留序号最大者', () {
      final all = [
        meta('g1', index: 1, serial: 1, using: true),
        meta('g2', index: 1, serial: 2, using: true),
        meta('g3', father: 'g1', index: 2, using: true),
      ];
      final conflicts = RoundTree.usingConflicts(all);
      expect(conflicts.length, 1);
      expect(conflicts.single.first.uuid, 'g2');
      expect(conflicts.single.skip(1).map((e) => e.uuid), ['g1']);
    });

    test('正常数据没有冲突', () {
      final all = [
        meta('g1', index: 1, using: true),
        meta('g2', index: 1, serial: 2),
      ];
      expect(RoundTree.usingConflicts(all), isEmpty);
    });
  });

  group('buildContext', () {
    const branchMain = Branch.defaultBranchName;

    test('默认分支：只有链，没有上游', () {
      final all = [
        meta('m1', index: 1, using: true),
        meta('m2', father: 'm1', index: 2, using: true),
      ];
      final walk = RoundTree.buildContext(all: all, branches: const [], branchUuid: '');
      expect(walk.chain.map((e) => e.uuid), ['m1', 'm2']);
      expect(walk.upstream, isEmpty);
      expect(walk.fallback, isNull);
      expect(walk.truncated, isFalse);
      expect(walk.fullOldestFirst.map((e) => e.uuid), ['m1', 'm2']);
      expect(branchMain, '主线');
    });

    test('分支：到链首后跳到父分支的那一代继续往上', () {
      final all = [
        meta('m1', index: 1, using: true),
        meta('m2', father: 'm1', index: 2, using: true),
        meta('m3', father: 'm2', index: 3, using: true),
        meta('b1', branch: 'br1', index: 3, using: true),
      ];
      final branches = [
        Branch(
          branchUuid: 'br1',
          fatherRow: 'm2',
          fatherRowIndex: 2,
          branchName: '如果',
          createdAt: epoch,
          updatedAt: epoch,
        ),
      ];
      final walk = RoundTree.buildContext(
        all: all,
        branches: branches,
        branchUuid: 'br1',
      );
      expect(walk.chain.map((e) => e.uuid), ['b1']);
      expect(walk.upstream.map((e) => e.uuid), ['m1', 'm2']);
      expect(walk.fullOldestFirst.map((e) => e.uuid), ['m1', 'm2', 'b1']);
    });

    test('多级分支：一层层跳到根', () {
      final all = [
        meta('m1', index: 1, using: true),
        meta('b1', branch: 'b', index: 2, using: true),
        meta('c1', branch: 'c', index: 3, using: true),
      ];
      final branches = [
        Branch(
          branchUuid: 'b',
          fatherRow: 'm1',
          fatherRowIndex: 1,
          branchName: 'B',
          createdAt: epoch,
          updatedAt: epoch,
        ),
        Branch(
          branchUuid: 'c',
          fatherRow: 'b1',
          fatherRowIndex: 2,
          branchName: 'C',
          createdAt: epoch,
          updatedAt: epoch,
        ),
      ];
      final walk =
          RoundTree.buildContext(all: all, branches: branches, branchUuid: 'c');
      expect(walk.fullOldestFirst.map((e) => e.uuid), ['m1', 'b1', 'c1']);
    });

    test('父代被删：用快照兜底一轮并停止', () {
      final all = [
        meta('b1', branch: 'br1', index: 4, using: true),
      ];
      final snapshot = BranchFatherSnapshot.encode(
        generation(
          meta('gone', index: 3, using: true),
          narrative: '父代正文',
        ),
      );
      final branches = [
        Branch(
          branchUuid: 'br1',
          fatherRow: 'gone',
          fatherRowIndex: 3,
          branchName: '如果',
          fatherRowShot: snapshot,
          createdAt: epoch,
          updatedAt: epoch,
        ),
      ];
      final walk =
          RoundTree.buildContext(all: all, branches: branches, branchUuid: 'br1');
      expect(walk.chain.map((e) => e.uuid), ['b1']);
      expect(walk.upstream, isEmpty);
      expect(walk.fallback, isNotNull);
      expect(walk.fallback!.aiNarrative, '父代正文');
      expect(walk.fallback!.roundIndex, 3);
      expect(walk.truncated, isFalse);
    });

    test('父代被删且没有快照：标记上文不完整', () {
      final all = [meta('b1', branch: 'br1', index: 4, using: true)];
      final branches = [
        Branch(
          branchUuid: 'br1',
          fatherRow: 'gone',
          fatherRowIndex: 3,
          branchName: '如果',
          createdAt: epoch,
          updatedAt: epoch,
        ),
      ];
      final walk =
          RoundTree.buildContext(all: all, branches: branches, branchUuid: 'br1');
      expect(walk.fallback, isNull);
      expect(walk.truncated, isTrue);
    });

    test('空分支没有上下文', () {
      final walk = RoundTree.buildContext(
        all: [meta('m1', using: true)],
        branches: const [],
        branchUuid: 'missing',
      );
      expect(walk.isEmpty, isTrue);
      expect(walk.fullOldestFirst, isEmpty);
    });
  });
}
