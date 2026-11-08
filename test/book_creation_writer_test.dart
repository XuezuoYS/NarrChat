import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/book_creation_draft.dart';
import 'package:narrchat/models/role_category.dart';
import 'package:narrchat/models/world_book_entry.dart';
import 'package:narrchat/repositories/world_book_repository.dart';
import 'package:narrchat/services/book_creation/book_creation_writer.dart';
import 'package:narrchat/utils/constants.dart';

import 'helpers/fakes.dart';

/// 落库写入器：成功落库、保留不完整书、数据库错误物理回滚。
void main() {
  late TestStack stack;

  setUp(() async {
    stack = await TestStack.create();
  });

  tearDown(() async {
    await stack.dispose();
  });

  BookCreationWriter writer({WorldBookRepository? worldBooks}) {
    return BookCreationWriter(
      books: stack.repos.books,
      worldBooks: worldBooks ?? stack.repos.worldBook,
      mods: stack.repos.mod,
    );
  }

  BookCreationDraft completeDraft(List<String> modRefs) {
    return BookCreationDraft(
      title: '妖灵事务所',
      category: '都市奇幻',
      baseSetting: '- 世界：现代都市\n- 妖灵不可被普通人看见',
      worldBook: const [
        WorldBookEntry(
          bookUuid: '',
          keyword: '事务所, 委托',
          content: '旧城区的妖灵事务所，只接待妖怪委托。',
        ),
      ],
      globalPrePrompt: '遵守设定，不要 OOC。',
      globalPostPrompt: '不要写现代网络流行语。',
      writingRequirements: '多用短句，少用排比。',
      roleCategories: const [
        RoleCategory(name: '主角', format: '- 姓名：\n- 当前状态：'),
        RoleCategory(name: 'NPC', format: '- 姓名：\n- 所属组织：'),
      ],
      modRefs: modRefs,
    );
  }

  test('完整草稿写库成功：字段 / 世界书 / Mod 顺序 / 回读校验全部通过', () async {
    final userModUuid = await stack.seedMod(
      name: '我的修仙设定包',
      description: '修仙向',
      systemPrompt: '补充宗门与境界设定。',
    );
    final result = await writer().writeAndVerify(
      draft: completeDraft([
        'preset:web_novel_style',
        'user:$userModUuid',
      ]),
    );

    expect(result.ok, isTrue, reason: result.error ?? '应成功');
    final book = result.book!;
    expect(book.title, '妖灵事务所');
    expect(book.category, '都市奇幻');
    expect(book.writingStyle, isEmpty, reason: '文笔参考段落不由 AI 编辑');
    expect(book.historyRounds, 1);
    expect(book.memorySummaryRounds, 0);
    expect(book.roleHierarchy, '主角 > NPC');

    final entries = await stack.repos.worldBook.list(book.uuid);
    expect(entries, hasLength(1));
    expect(entries.single.isActive, isTrue);
    expect(entries.single.keyword, '事务所, 委托');

    final refs = await stack.repos.mod.useModUuids(book.uuid);
    expect(refs, ['preset::web_novel_style', userModUuid]);

    // 书已作为正常的书落库（目录 + 书库都能读到）。
    final books = await stack.repos.books.listBooks();
    expect(books.map((b) => b.uuid), contains(book.uuid));
  });

  test('保留此书：空标题回落「未命名书籍」，空角色类别回落默认', () async {
    const partial = BookCreationDraft();
    final result = await writer().writeAndVerify(
      draft: partial,
      fallbackTitle: '未命名书籍',
    );

    expect(result.ok, isTrue, reason: result.error ?? '应成功');
    final book = result.book!;
    expect(book.title, '未命名书籍');
    expect(book.baseSetting, isEmpty);
    expect(book.roleCategories, Constants.defaultRoleCategories);
    expect(
      book.roleHierarchy,
      Constants.joinRoleHierarchy(
        Constants.defaultRoleCategories.map((c) => c.name).toList(),
      ),
    );
    expect(await stack.repos.worldBook.list(book.uuid), isEmpty);
    expect(await stack.repos.mod.useModUuids(book.uuid), isEmpty);
  });

  test('世界书写入抛错：返回失败并物理删除刚建的书（不留墓碑）', () async {
    final failing = _FailingWorldBookRepository(books: stack.stores.books);
    final result = await writer(worldBooks: failing).writeAndVerify(
      draft: completeDraft(const []),
    );

    expect(result.ok, isFalse);
    expect(result.error, contains('数据库写入失败'));
    expect(
      result.error,
      contains('清理'),
      reason: '失败文案要说明书库已清理（或清理失败）',
    );

    // 书库文件 / 目录行 / 缓存都要清掉：列表（含墓碑）为空。
    expect(
      await stack.repos.books.listBooks(includeDeleted: true),
      isEmpty,
    );
  });
}

/// 世界书仓储替身：`replaceAll` 直接抛错（模拟磁盘 / SQLite 故障）。
class _FailingWorldBookRepository extends WorldBookRepository {
  _FailingWorldBookRepository({required super.books});

  @override
  Future<void> replaceAll(
    String bookUuid,
    List<WorldBookEntry> entries,
  ) async {
    throw StateError('模拟世界书写入失败');
  }
}
