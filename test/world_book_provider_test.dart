import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/world_book_entry.dart';
import 'package:narrchat/providers/world_book_provider.dart';

import 'helpers/fakes.dart';

/// 世界书 Provider：书籍设置保存时一次整体替换条目。
void main() {
  late TestStack stack;
  late WorldBookProvider provider;
  late FakeCloudSyncProvider cloud;

  setUp(() async {
    stack = await TestStack.create();
    await stack.seedBook(uuid: 'b1', title: '书');
    cloud = FakeCloudSyncProvider();
    provider = WorldBookProvider(
      repository: stack.repos.worldBook,
      cloudSyncProvider: cloud,
    );
  });

  tearDown(() async {
    await stack.dispose();
  });

  WorldBookEntry entry({
    String uuid = '',
    String keyword = '',
    String content = '',
    bool isActive = true,
  }) {
    return WorldBookEntry(
      uuid: uuid,
      bookUuid: 'b1',
      keyword: keyword,
      content: content,
      isActive: isActive,
      createdAt: DateTime.utc(2026, 1, 1),
    );
  }

  test('saveEntries：整体替换、新条目补 uuid、刷新内存条目', () async {
    final keepUuid = await stack.seedWorldBookEntry(
      'b1',
      keyword: '保留',
      content: '旧内容',
    );
    await stack.seedWorldBookEntry('b1', keyword: '删除');

    final ok = await provider.saveEntries('b1', [
      entry(uuid: keepUuid, keyword: '保留', content: '新内容', isActive: false),
      entry(keyword: '新增', content: '新增内容'),
    ], triggerSync: false);

    expect(ok, isTrue);
    expect(cloud.triggers, 0, reason: '由书籍设置页统一触发同步');

    final saved = await stack.repos.worldBook.list('b1');
    expect(saved.map((e) => e.keyword).toSet(), {'保留', '新增'});
    final kept = saved.firstWhere((e) => e.keyword == '保留');
    final added = saved.firstWhere((e) => e.keyword == '新增');
    expect(kept.uuid, keepUuid, reason: '老条目保留身份');
    expect(kept.content, '新内容');
    expect(kept.isActive, isFalse);
    expect(added.uuid, isNotEmpty, reason: '新条目由仓储生成 uuid');
    expect(added.isActive, isTrue);

    expect(provider.error, isNull);
    expect(provider.entries.map((e) => e.keyword).toSet(), {'保留', '新增'});
  });

  test('saveEntries：默认触发一次同步', () async {
    await provider.saveEntries('b1', [entry(keyword: '条目')]);

    expect(cloud.triggers, 1);
    expect(provider.entries.single.keyword, '条目');
  });
}
