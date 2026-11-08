import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/book_creation_draft.dart';
import 'package:narrchat/models/mod.dart';
import 'package:narrchat/models/role_category.dart';
import 'package:narrchat/models/world_book_entry.dart';
import 'package:narrchat/services/book_creation/book_creation_prompts.dart';

/// 创建流程提示词：阶段契约、上下文、Mod 目录与补充轮。
void main() {
  const prompts = BookCreationPrompts();
  const idea = '一个现代都市里隐藏的妖灵事务所';

  const modA = Mod(
    presetKey: 'web_novel_style',
    name: '默认网文语感强化',
    description: '强化中文网文的语感与节奏',
    prePrompt: '用网文语感写。',
  );
  const modB = Mod(
    uuid: 'user-1',
    name: '我的修仙设定包',
    description: '修仙世界观补充',
    systemPrompt: '补充宗门与境界设定。',
    worldBookEntries: [
      ModWorldBookEntry(keyword: '宗门', content: '宗门设定内容'),
    ],
  );

  const draft = BookCreationDraft(
    title: '妖灵事务所',
    category: '都市奇幻',
    baseSetting: '- 世界：现代都市\n- 妖灵不可见',
    worldBook: [
      WorldBookEntry(
        bookUuid: '',
        keyword: '事务所',
        content: '旧城区的妖灵事务所。',
      ),
    ],
    globalPrePrompt: '遵守设定。',
    globalPostPrompt: '不要 OOC。',
    writingRequirements: '多用短句。',
    roleCategories: [
      RoleCategory(name: '主角', format: '- 姓名：\n- 当前状态：'),
    ],
    modRefs: ['preset:web_novel_style'],
  );

  test('系统提示词：只输出标签、禁止 #/##、不自称 AI', () {
    expect(BookCreationPrompts.system, contains('只输出当前步骤要求的内容'));
    expect(BookCreationPrompts.system, contains('禁止使用 # 或 ## 标题'));
    expect(BookCreationPrompts.system, contains('不要提到 AI'));
  });

  test('阶段 1：带创意与标题 / 分类标签', () {
    final prompt = prompts.titleCategory(idea: idea);
    expect(prompt, contains(idea));
    expect(prompt, contains('<title>书名</title>'));
    expect(prompt, contains('<category>分类</category>'));
  });

  test('阶段 2：带标题分类上下文与 Mod 目录，要求只能填 ref', () {
    final prompt = prompts.mods(
      idea: idea,
      draft: draft,
      availableMods: const [modA, modB],
    );
    expect(prompt, contains('标题：妖灵事务所'));
    expect(prompt, contains('分类：都市奇幻'));
    expect(prompt, contains('ref：preset:web_novel_style'));
    expect(prompt, contains('ref：user:user-1'));
    expect(prompt, contains('默认网文语感强化'));
    expect(prompt, contains('只能填写列表中给出的 ref'));
    expect(prompt, contains('<mods>'));
  });

  test('阶段 3：带已选 Mod 简介与基础设定 / 世界书标签', () {
    final prompt = prompts.baseSettingWorldBook(
      idea: idea,
      draft: draft,
      selectedMods: const [modA],
    );
    expect(prompt, contains('已选 Mod'));
    expect(prompt, contains(modA.name));
    expect(prompt, contains('基础设定内容'));
    expect(prompt, contains('<keyword>'));
    expect(prompt, contains('不能为空'));
  });

  test('阶段 4：带基础设定与世界书关键词摘要，要求三块非空', () {
    final prompt = prompts.prePostWriting(
      idea: idea,
      draft: draft,
      selectedMods: const [modA],
    );
    expect(prompt, contains('世界书关键词：事务所'));
    expect(prompt, contains('基础设定'));
    expect(prompt, contains('<prePrompt>'));
    expect(prompt, contains('<postPrompt>'));
    expect(prompt, contains('<writingRequirements>'));
    expect(prompt, contains('三块都不能为空'));
  });

  test('阶段 5：带基础设定与角色类别输出契约', () {
    final prompt = prompts.roleCategories(
      idea: idea,
      draft: draft,
      selectedMods: const [modA],
    );
    expect(prompt, contains('基础设定'));
    expect(prompt, contains('<roleCategories>'));
    expect(prompt, contains('<name>'));
    expect(prompt, contains('<format>'));
    expect(prompt, contains('名称与格式都不能为空'));
  });

  test('补充轮：带问题清单、当前内容与「只输出需要补充的标签」', () {
    final prompt = prompts.supplement(
      idea: idea,
      draft: draft,
      selectedMods: const [modA],
      problems: const ['书名缺失', '世界书为空'],
      attempt: 2,
      maxAttempts: 2,
    );
    expect(prompt, contains('第 2/2 次补充'));
    expect(prompt, contains('- 书名缺失'));
    expect(prompt, contains('- 世界书为空'));
    expect(prompt, contains('只输出需要补充 / 修正的标签'));
    expect(prompt, contains('完整'));
    expect(prompt, contains('角色类别：'));
    expect(prompt, contains('前置词：'));
  });

  test('Mod 目录：截断预览 / 最多列出数量 / 空目录提示', () {
    final longMod = Mod(
      presetKey: 'long',
      name: '超长内容 Mod',
      systemPrompt: '很长的系统提示词' * 20,
    );
    final catalog = BookCreationPrompts.modCatalog(
      [longMod],
      previewChars: 12,
    );
    expect(catalog, contains('内容预览：'));
    expect(catalog, contains('…'));

    final many = [
      for (var i = 0; i < 5; i++)
        Mod(presetKey: 'p$i', name: 'Mod$i'),
    ];
    final limited = BookCreationPrompts.modCatalog(many, maxMods: 2);
    expect(limited, contains('Mod0'));
    expect(limited, contains('Mod1'));
    expect(limited, isNot(contains('Mod2')));
    expect(limited, contains('还有 3 个 Mod 未列出'));

    expect(
      BookCreationPrompts.modCatalog(const []),
      contains('没有任何可用 Mod'),
    );
  });
}
