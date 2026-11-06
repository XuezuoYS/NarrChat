import 'package:flutter_test/flutter_test.dart';

import 'helpers/fakes.dart';

/// TestStack 自检：后续所有测试文件都依赖它，必须保证它真的能建库、能播种、能清理。
void main() {
  test('建库 / 播种 / 读取 / 清理 一条龙', () async {
    final stack = await TestStack.create();
    try {
      // 目录是这次用例独有的
      expect(stack.rootDir.existsSync(), isTrue);
      expect(stack.paths.userDataDir, startsWith(stack.rootDir.path));

      // 书
      final bookUuid = await stack.seedBook(uuid: 'book-1', title: '测试书');
      expect(bookUuid, 'book-1');
      final books = await stack.repos.books.listBooks();
      expect(books.single.uuid, 'book-1');
      expect(books.single.title, '测试书');

      // 轮：自动接父代、自动排组内序号
      final first = await stack.seedRound(
        bookUuid,
        roundIndex: 1,
        userInput: '问一',
        aiNarrative: '答一',
      );
      final second = await stack.seedRound(
        bookUuid,
        roundIndex: 2,
        aiNarrative: '答二',
      );
      expect(first.fatherUuid, isNull);
      expect(second.fatherUuid, first.uuid);

      final chain = await stack.repos.rounds.loadChain(bookUuid);
      expect(chain.rounds.map((r) => r.roundIndex), [1, 2]);
      expect(chain.rounds.first.aiNarrative, '答一');

      // 同组再造一代：序号 +1、前一代被取消选中
      final other = await stack.seedRound(
        bookUuid,
        roundIndex: 1,
        aiNarrative: '答一（另一版）',
      );
      expect(other.roundSerialNum, 2);
      final afterSwitch = await stack.repos.rounds.loadChain(bookUuid);
      expect(afterSwitch.rounds.first.uuid, other.uuid);

      // 世界书与 Mod
      final worldUuid = await stack.seedWorldBookEntry(
        bookUuid,
        keyword: '龙、蛇',
        content: '爬行类',
      );
      expect(worldUuid, isNotEmpty);
      final worldRows = await stack.repos.worldBook.list(bookUuid);
      expect(worldRows.single.keywords, ['龙', '蛇']);

      final modUuid = await stack.seedMod(name: '润色', prePrompt: '前置');
      expect(modUuid, isNotEmpty);
      await stack.repos.mod.setUseModUuids(bookUuid, [modUuid]);
      expect(await stack.repos.mod.useModUuids(bookUuid), [modUuid]);

      // 最近对话时间走缓存副本
      await stack.setLastRoundAt(bookUuid, DateTime.utc(2026, 5, 1));
      final times = await stack.repos.books.lastRoundTimes();
      expect(times[bookUuid], DateTime.utc(2026, 5, 1));
    } finally {
      await stack.dispose();
    }

    // dispose 之后临时目录必须消失（否则会在 CI 上堆积）
    expect(stack.rootDir.existsSync(), isFalse);
  });

  test('两套 TestStack 互不干扰（不是共享静态库）', () async {
    final a = await TestStack.create();
    final b = await TestStack.create();
    try {
      await a.seedBook(uuid: 'same-uuid', title: 'A 的书');
      await b.seedBook(uuid: 'same-uuid', title: 'B 的书');

      expect((await a.repos.books.listBooks()).single.title, 'A 的书');
      expect((await b.repos.books.listBooks()).single.title, 'B 的书');
      expect(a.rootDir.path, isNot(b.rootDir.path));
    } finally {
      await a.dispose();
      await b.dispose();
    }
  });

  test('dispose 幂等：重复调用不抛', () async {
    final stack = await TestStack.create();
    await stack.dispose();
    await stack.dispose();
  });
}
