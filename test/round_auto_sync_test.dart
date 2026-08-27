import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/providers/cloud_sync_provider.dart';
import 'package:narrchat/providers/round_provider.dart';

import 'helpers/fakes.dart';

/// `RoundProvider` 生成结束自动同步触发测试：
/// - 成功落库后触发一次自动同步；
/// - 失败（红框报错条目）后同样触发；
/// - 触发发生在数据落库之后（成功路径轮次已入库）。
class _RecordingSyncProvider extends CloudSyncProvider {
  int triggers = 0;

  @override
  void triggerAutoSync({bool silent = false}) {
    triggers++;
  }
}

void main() {
  const book = Book(id: 1, title: '测试书');

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
    await rp.loadRounds(1);
    return (rp, cloud);
  }

  test('生成成功 → 触发一次自动同步（轮次已落库）', () async {
    final (rp, cloud) = await build();
    expect(cloud.triggers, 0);

    final ok = await rp.sendRound(userInput: '第一轮', book: book);

    expect(ok, isTrue);
    expect(rp.rounds, hasLength(2), reason: '第零轮 + 成功一轮');
    expect(cloud.triggers, 1, reason: '成功落库后触发一次性自动同步');
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
    await rp.loadRounds(1);

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
    await rp.loadRounds(1);

    final future = rp.sendRound(userInput: '中断轮', book: book);
    rp.cancelGeneration(bookId: 1);
    final ok = await future;

    expect(ok, isFalse);
    expect(cloud.triggers, 1, reason: '用户中断后（失败条目）同样触发自动同步');
  });
}
