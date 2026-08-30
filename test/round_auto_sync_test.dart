import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/providers/cloud_sync_provider.dart';
import 'package:narrchat/providers/round_provider.dart';
import 'package:narrchat/services/sync/sync_models.dart';

import 'helpers/fakes.dart';

/// `RoundProvider` 生成结束自动同步触发测试：
/// - 成功落库后触发一次自动同步；
/// - 失败（红框报错条目）后同样触发；
/// - 触发发生在数据落库之后（成功路径轮次已入库）；
/// - 触发种类为 both（轮次含图片引用：数据推送 + 图片补跑一起排队）。
class _RecordingSyncProvider extends CloudSyncProvider {
  int triggers = 0;
  SyncKind? lastKind;

  @override
  void triggerSync({SyncKind kind = SyncKind.both, bool silent = false}) {
    triggers++;
    lastKind = kind;
  }
}

void main() {
  const book = Book(uuid: 'b1', title: '测试书');

  Future<(RoundProvider, _RecordingSyncProvider)> build() async {
    final dao = FakeRoundDao();
    final bookDao = FakeBookDao();
    final cloud = _RecordingSyncProvider();
    final rp = RoundProvider(
      dao: dao,
      bookDao: bookDao,
      aiService: ToggleAiService(),
      cloudSyncProvider: cloud,
      retryDelay: Duration.zero,
    );
    await rp.loadRounds('b1');
    return (rp, cloud);
  }

  test('生成成功 → 触发一次自动同步（轮次已落库）', () async {
    final (rp, cloud) = await build();
    expect(cloud.triggers, 0);

    final ok = await rp.sendRound(userInput: '第一轮', book: book);

    expect(ok, isTrue);
    expect(rp.rounds, hasLength(2), reason: '第零轮 + 成功一轮');
    expect(cloud.triggers, 1, reason: '成功落库后触发一次性自动同步');
    expect(cloud.lastKind, SyncKind.both, reason: '轮次可能带图：数据 + 图片补跑');
  });

  test('生成失败（红框报错条目）→ 同样触发自动同步', () async {
    final dao = FakeRoundDao();
    final bookDao = FakeBookDao();
    final cloud = _RecordingSyncProvider();
    final rp = RoundProvider(
      dao: dao,
      bookDao: bookDao,
      aiService: ToggleAiService()..fail = true,
      cloudSyncProvider: cloud,
      retryDelay: Duration.zero,
    );
    await rp.loadRounds('b1');

    final ok = await rp.sendRound(userInput: '失败轮', book: book);

    expect(ok, isFalse);
    expect(rp.hasFailureEntry, isTrue, reason: '失败条目已落库（红框）');
    expect(cloud.triggers, 1, reason: '失败条目落库后同样触发自动同步');
  });

  test('生成取消（中断）→ 同样触发自动同步', () async {
    final dao = FakeRoundDao();
    final bookDao = FakeBookDao();
    final cloud = _RecordingSyncProvider();
    final rp = RoundProvider(
      dao: dao,
      bookDao: bookDao,
      aiService: ToggleAiService(),
      cloudSyncProvider: cloud,
      retryDelay: Duration.zero,
    );
    await rp.loadRounds('b1');

    final future = rp.sendRound(userInput: '中断轮', book: book);
    rp.cancelGeneration(bookUuid: 'b1');
    final ok = await future;

    expect(ok, isFalse);
    expect(cloud.triggers, 1, reason: '用户中断后（失败条目）同样触发自动同步');
  });

  test('侧边栏字段保存（updateRoundField）→ 触发一次自动同步', () async {
    final (rp, cloud) = await build();
    final roundId = rp.rounds.single.id!;
    expect(cloud.triggers, 0);

    final ok = await rp.updateRoundField(
      roundId,
      RoundField.worldState,
      '新的世界状态',
    );

    expect(ok, isTrue);
    expect(rp.rounds.single.worldState, '新的世界状态');
    expect(cloud.triggers, 1, reason: '侧边栏保存后应触发一次自动同步');
    expect(cloud.lastKind, SyncKind.both, reason: '与生成结束触发种类一致');
  });

  test('AI 正文保存（updateNarrative）→ 触发一次自动同步', () async {
    final (rp, cloud) = await build();
    final roundId = rp.rounds.single.id!;
    expect(cloud.triggers, 0);

    await rp.updateNarrative(roundId, '修改后的正文');

    expect(rp.rounds.single.aiNarrative, '修改后的正文');
    expect(cloud.triggers, 1, reason: '编辑 AI 正文保存后应触发一次自动同步');
  });

  test('用户输入保存（updateUserInput）→ 触发一次自动同步', () async {
    final (rp, cloud) = await build();
    final roundId = rp.rounds.single.id!;
    expect(cloud.triggers, 0);

    await rp.updateUserInput(roundId, '修改后的输入');

    expect(rp.rounds.single.userInput, '修改后的输入');
    expect(cloud.triggers, 1, reason: '编辑用户输入保存后应触发一次自动同步');
  });

  test('非法字段保存被拒 → 不触发同步', () async {
    final (rp, cloud) = await build();
    final roundId = rp.rounds.single.id!;

    final ok = await rp.updateRoundField(roundId, 'not_a_field', 'x');

    expect(ok, isFalse);
    expect(cloud.triggers, 0, reason: '未落库的编辑不应触发同步');
  });
}
