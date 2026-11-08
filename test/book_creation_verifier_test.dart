import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/book_creation_draft.dart';
import 'package:narrchat/models/preset_mods.dart';
import 'package:narrchat/models/role_category.dart';
import 'package:narrchat/models/world_book_entry.dart';
import 'package:narrchat/services/agent/narr_agent_tool.dart';
import 'package:narrchat/services/book_creation/book_creation_verifier.dart';
import 'package:narrchat/services/prompt_interface.dart';

/// 创建流程校验器：完整性检查 + 落库回读 + 提示词生效校验。
void main() {
  BookCreationDraft completeDraft() {
    return const BookCreationDraft(
      title: '妖灵事务所',
      category: '都市奇幻',
      baseSetting: '- 世界：现代都市\n- 妖灵不可被普通人看见',
      worldBook: [
        WorldBookEntry(
          bookUuid: '',
          keyword: '事务所, 委托',
          content: '旧城区的妖灵事务所，只接待妖怪委托。',
        ),
      ],
      globalPrePrompt: '遵守设定，不要 OOC。',
      globalPostPrompt: '不要写现代网络流行语。',
      writingRequirements: '多用短句，少用排比。',
      roleCategories: [
        RoleCategory(name: '主角', format: '- 姓名：\n- 当前状态：'),
        RoleCategory(name: 'NPC', format: '- 姓名：\n- 所属组织：'),
      ],
      modRefs: ['preset:web_novel_style'],
    );
  }

  List<String> verifyWith(
    BookCreationDraft draft, {
    Book? savedBook,
    List<WorldBookEntry>? savedEntries,
    List<String>? savedStorageRefs,
    BookCreationVerifier verifier = const BookCreationVerifier(),
  }) {
    final expectedBook = draft.toBook();
    final expectedEntries = draft.effectiveWorldBook;
    return verifier.verifyPersisted(
      expectedBook: expectedBook,
      savedBook: savedBook ?? expectedBook,
      expectedEntries: expectedEntries,
      savedEntries: savedEntries ?? expectedEntries,
      expectedStorageModRefs: const ['preset::web_novel_style'],
      savedStorageModRefs: savedStorageRefs ?? const ['preset::web_novel_style'],
      persistedMods: [PresetMods.byKey('web_novel_style')!],
    );
  }

  group('完整性检查', () {
    test('空草稿逐项报缺', () {
      final problems = BookCreationVerifier.completenessProblems(
        BookCreationDraft.empty,
      );
      expect(problems, contains('书名缺失'));
      expect(problems, contains('分类缺失'));
      expect(problems, contains('基础设定缺失'));
      expect(problems, contains('世界书为空'));
      expect(problems, contains('前置词缺失'));
      expect(problems, contains('后置词缺失'));
      expect(problems, contains('文笔要求缺失'));
      expect(problems, contains('角色类别缺失'));
    });

    test('完整草稿没有问题', () {
      expect(
        BookCreationVerifier.completenessProblems(completeDraft()),
        isEmpty,
      );
    });

    test('世界书条目缺关键词 / 内容逐条点名', () {
      final problems = BookCreationVerifier.completenessProblems(
        completeDraft().copyWith(
          worldBook: const [
            WorldBookEntry(
              bookUuid: '',
              keyword: '',
              content: '有内容没关键词',
            ),
            WorldBookEntry(
              bookUuid: '',
              keyword: '有词',
              content: '',
            ),
          ],
        ),
      );
      expect(problems, contains('第 1 条世界书缺少关键词'));
      expect(problems, contains('第 2 条世界书内容为空'));
    });

    test('角色类别重名 / 空格式 / 空名称逐项报出', () {
      final problems = BookCreationVerifier.completenessProblems(
        completeDraft().copyWith(
          roleCategories: const [
            RoleCategory(name: '主角', format: '- 姓名：'),
            RoleCategory(name: '主角', format: '- 姓名：'),
            RoleCategory(name: '', format: '- 姓名：'),
            RoleCategory(name: 'NPC', format: ''),
          ],
        ),
      );
      expect(problems, contains('角色类别「主角」重复'));
      expect(problems, contains('有角色类别缺少名称'));
      expect(problems, contains('角色类别「NPC」的描述格式为空'));
    });
  });

  group('落库回读 + 提示词生效校验', () {
    test('完全一致时通过（字段 / 世界书 / Mod / 提示词都生效）', () {
      expect(verifyWith(completeDraft()), isEmpty);
    });

    test('字段被改写 -> 报字段未正确写入', () {
      final draft = completeDraft();
      final tampered = draft.toBook().copyWith(baseSetting: '被篡改的设定');
      final problems = verifyWith(draft, savedBook: tampered);
      expect(problems, contains('基础设定 未正确写入'));
    });

    test('世界书条目缺失 -> 报未写入', () {
      final problems = verifyWith(
        completeDraft(),
        savedEntries: const [],
      );
      expect(
        problems.any((problem) => problem.contains('世界书条目')),
        isTrue,
      );
    });

    test('Mod 顺序 / 数量不符 -> 报启用 Mod 数量不一致', () {
      final problems = verifyWith(
        completeDraft(),
        savedStorageRefs: const [],
      );
      expect(problems, contains('启用 Mod 数量不一致'));
    });

    test('角色类别格式不符 -> 报该类别未正确写入', () {
      final draft = completeDraft();
      final tampered = draft.toBook().copyWith(
        roleCategories: const [
          RoleCategory(name: '主角', format: '被改掉的格式'),
          RoleCategory(name: 'NPC', format: '- 姓名：\n- 所属组织：'),
        ],
      );
      final problems = verifyWith(draft, savedBook: tampered);
      expect(problems, contains('角色类别「主角」未正确写入'));
    });

    test('提示词拼装缺内容时能报「没有出现在拼装后的提示词里」', () {
      final problems = verifyWith(
        completeDraft(),
        verifier: const BookCreationVerifier(prompt: _EmptyPromptInterface()),
      );
      expect(
        problems.any(
          (problem) => problem.contains('没有出现在拼装后的提示词里'),
        ),
        isTrue,
      );
    });
  });
}

/// 空提示词实现：用于验证「生效校验」确实在检查拼装结果。
class _EmptyPromptInterface implements PromptInterface {
  const _EmptyPromptInterface();

  @override
  String system(PromptRequest request) => '';

  @override
  String user(PromptRequest request) => '';

  @override
  String stagePrepare(AgentStageRequest request) => '';

  @override
  String stageMemory(AgentStageRequest request) => '';

  @override
  String stageStory(AgentStageRequest request) => '';

  @override
  String stageState(AgentStageRequest request) => '';

  @override
  List<NarrAgentTool> tools(AgentToolsRequest request) => const [];
}
