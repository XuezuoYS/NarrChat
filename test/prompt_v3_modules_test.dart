import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/mod.dart';
import 'package:narrchat/models/role_category.dart';
import 'package:narrchat/services/prompt_text.dart';
import 'package:narrchat/services/prompt_v3_build.dart';
import 'package:narrchat/services/prompt_v3_sections.dart';
import 'package:narrchat/utils/memory_entry_format.dart';

/// v3 **system 逐模块**测试（`systemSections()` 的单模块断言）。
///
/// 口径（`docs/prompt_v3_system.md`）：
/// - 8 个模块按固定顺序：must → accord → extra → about → setting →
///   writingStyle → accordEnding → mustReverse；
/// - must / mustReverse **不带标题**，块序列整体反转（Mod 段一起参与）；
/// - `extra` 是唯一带程序标题的 Mod 注入位（`# 通用约束：`）；
/// - 空模块整块消失，绝不写「（无）」「未设置」。
///
/// 接口层（绑定 / 工具 / user 衔接）在 `test/prompt_interface_test.dart`，
/// 上下文侧在 `test/prompt_v3_context_test.dart`。
void main() {
  const builder = PromptV3Build();

  const fullBook = Book(
    title: '测试书',
    category: '玄幻',
    baseSetting: '北域修仙世界。',
    writingRequirements: '多用对话推进。',
    writingStyle: '用户范文：短句为主。',
    roleHierarchy: '主角 > 女主角 > NPC',
    roleCategories: [
      RoleCategory(name: '主角', format: '姓名：\n当前状态：'),
      RoleCategory(name: '空类别', format: '   '),
    ],
  );

  const mods = ModsBundle(
    prePrompts: 'MOD 前置词',
    postPrompts: 'MOD 后置词',
    mustPrompts: 'MOD1 最高优先约束\n\nMOD2 最高优先约束',
    mustSegments: ['MOD1 最高优先约束', 'MOD2 最高优先约束'],
    systemPrompts: 'MOD 通用约束',
    settingPrompts: 'MOD 设定',
    worldBooks: 'MOD 世界书',
    writingStylePrompts: 'MOD 文笔',
  );

  PromptRequest requestOf({
    Book book = fullBook,
    PromptMode mode = PromptMode.chat,
    ModsBundle? modsBundle,
    String worldBook = '书籍世界书',
    List<String> toolNames = const [],
  }) =>
      PromptRequest(
        book: book,
        mode: mode,
        userInput: '输入',
        worldBookEntries: worldBook,
        mods: modsBundle,
        toolNames: toolNames,
      );

  Map<String, String> sectionsOf(PromptRequest request) => {
        for (final section in builder.systemSections(request))
          section.name: section.text,
      };

  test('模块顺序固定为 8 个，名字与顺序即接口契约', () {
    final names = [
      for (final section in builder.systemSections(
        requestOf(modsBundle: mods, toolNames: const ['narrchat_readHistory']),
      ))
        section.name,
    ];
    expect(names, [
      'must',
      'accord',
      'extra',
      'about',
      'setting',
      'writingStyle',
      'accordEnding',
      'mustReverse',
    ]);
  });

  test('system() 就是各模块用一个空行串起来', () {
    final request = requestOf(modsBundle: mods);
    final joined = builder.systemSections(request).map((s) => s.text).join(
      '\n\n',
    );
    expect(builder.system(request), joined);
  });

  group('must / mustReverse', () {
    test('must 无标题：开篇直接是人设段，其后按顺序接各 Mod 段', () {
      final must = sectionsOf(requestOf(modsBundle: mods))['must']!;
      expect(must, startsWith('你是一名喜爱创作，涉猎文学、艺术的作者'));
      expect(must, isNot(contains('# 必须遵循')));
      expect(must, isNot(contains('# ')), reason: 'must 里不应出现任何标题');
      final mod1 = must.indexOf('MOD1 最高优先约束');
      final mod2 = must.indexOf('MOD2 最高优先约束');
      expect(mod1, greaterThan(must.indexOf(PromptV3Sections.mustSegment1)));
      expect(mod1, lessThan(mod2), reason: '保持用户设定的 Mod 顺序');
    });

    test('mustReverse = must 的块序列整体反转（Mod 段倒序、段1 最后）', () {
      final reverse = sectionsOf(requestOf(modsBundle: mods))['mustReverse']!;
      expect(
        reverse,
        'MOD2 最高优先约束\n\nMOD1 最高优先约束\n\n${PromptV3Sections.mustSegment1}',
      );
    });

    test('无 Mod 时 must 只有段1，mustReverse 原位复现一次', () {
      final sections = sectionsOf(requestOf());
      expect(sections['must'], PromptV3Sections.mustSegment1);
      expect(sections['mustReverse'], PromptV3Sections.mustSegment1);
    });

    test('手工构造的 bundle（没有 mustSegments）退化为整段一块', () {
      const legacy = ModsBundle(mustPrompts: '只有一段');
      final sections = sectionsOf(requestOf(modsBundle: legacy));
      expect(sections['must'], '${PromptV3Sections.mustSegment1}\n\n只有一段');
      expect(sections['mustReverse'], '只有一段\n\n${PromptV3Sections.mustSegment1}');
    });
  });

  group('accord', () {
    test('Chat：7 个子模块按序，不含状态工具契约', () {
      final accord = sectionsOf(requestOf())['accord']!;
      final order = [
        '# 当前请求协议：',
        '# 通用输出契约：',
        '# 角色状态格式要求：',
        '# 角色状态完整性要求：',
        '# 记忆条目格式：',
        '# 记忆总结轮次合并：',
        '# 输出区块契约：',
      ];
      var cursor = -1;
      for (final title in order) {
        final at = accord.indexOf(title);
        expect(at, greaterThan(cursor), reason: '子模块顺序：$title');
        cursor = at;
      }
      expect(accord, isNot(contains('# 状态工具契约：')));
      expect(accord, contains('- 当前请求协议：Chat。'));
      expect(accord, contains('档位 0（关闭）'));
    });

    test('Agent：多一个状态工具契约（历史一读一写）', () {
      final accord = sectionsOf(requestOf(mode: PromptMode.agentLv1))['accord']!;
      expect(accord, contains('- 当前请求协议：Agent。'));
      expect(accord, contains('# 状态工具契约：'));
      expect(accord, contains('narrchat_readHistory'));
      expect(accord, contains('narrchat_editHistory'));
      expect(accord, isNot(contains('narrchat_readWorldState')));
      // 输出区块契约：Agent 5 区块（无记忆总结的标题链）。
      final contract = accord.substring(accord.indexOf('# 输出区块契约：'));
      expect(contract, contains('本轮采用 Agent 模式，分为先后两步，不得跳步'));
      expect(contract, isNot(contains('→ `## 记忆总结`')));
    });

    test('记忆合并档位随本书设置（0 / 5 / 10）', () {
      expect(sectionsOf(requestOf())['accord'], contains('档位 0（关闭）'));

      const tier5 = Book(title: '档 5', memorySummaryRounds: 5);
      final accord5 = sectionsOf(requestOf(book: tier5))['accord']!;
      expect(accord5, contains('档位 5：'));
      expect(accord5, contains('达到 10（= 2 × 5）条'));

      const tier10 = Book(title: '档 10', memorySummaryRounds: 10);
      final accord10 = sectionsOf(requestOf(book: tier10))['accord']!;
      expect(accord10, contains('达到 20（= 2 × 10）条'));
    });

    test('记忆条目模板走统一常量（单轮 + 合并）', () {
      final accord = sectionsOf(requestOf())['accord']!;
      expect(accord, contains(kMemoryEntryFormat));
      expect(accord, contains(kMemoryMergedEntryFormat));
    });
  });

  group('extra（唯一带程序标题的 Mod 注入位）', () {
    test('有 Mod 通用约束 → 带 # 通用约束：标题，且不含 Mod 字样', () {
      final extra = sectionsOf(requestOf(modsBundle: mods))['extra']!;
      expect(extra, startsWith('# 通用约束：'));
      expect(extra, contains('MOD 通用约束'));
      expect(extra, isNot(contains('Mod')));
    });

    test('没有 Mod 通用约束 → 整个模块消失', () {
      final sections = sectionsOf(requestOf(modsBundle: const ModsBundle()));
      expect(sections.containsKey('extra'), isFalse);
      expect(sections.containsKey('about'), isTrue);
    });
  });

  group('about（只放数据）', () {
    test('书籍信息 + 角色状态栏内容，类别名用【】包裹', () {
      final about = sectionsOf(requestOf())['about']!;
      expect(about, startsWith('# 书籍信息：\n\n- 当前书籍名：测试书'));
      expect(about, contains('- 当前书籍分类：玄幻'));
      expect(about, contains('# 角色状态栏内容：'));
      expect(about, contains('角色层级排序规则：`主角 > 女主角 > NPC`'));
      expect(about, contains('【主角】'));
      expect(about, contains('姓名：\n当前状态：'));
      expect(about, isNot(contains('【空类别】')), reason: '空格式的类别不注入');
    });

    test('书名 / 分类逐行判断，全空连标题一起删', () {
      const onlyCategory = Book(title: '有名字的书');
      final about = sectionsOf(requestOf(book: onlyCategory))['about']!;
      expect(about, contains('- 当前书籍名：有名字的书'));
      expect(about, isNot(contains('当前书籍分类')));
      expect(about, isNot(contains('角色状态栏内容')), reason: '层级与类别都空');
    });

    test('书名 / 分类 / 层级 / 类别全空 → 整个 about 模块消失', () {
      final sections = sectionsOf(requestOf(book: const Book(title: '')));
      expect(sections.containsKey('about'), isFalse);
      expect(sections.containsKey('must'), isTrue, reason: 'must 永远在');
    });
  });

  group('setting（书籍 + Mod 同块合并）', () {
    test('书籍设定后紧跟 Mod 设定；书籍世界书后紧跟 Mod 世界书', () {
      final setting = sectionsOf(requestOf(modsBundle: mods))['setting']!;
      final base = setting.indexOf('北域修仙世界。');
      final modSetting = setting.indexOf('MOD 设定');
      final worldTitle = setting.indexOf('# 世界书：');
      final world = setting.indexOf('书籍世界书');
      final modWorld = setting.indexOf('MOD 世界书');
      expect(base, greaterThan(0));
      expect(modSetting, greaterThan(base));
      expect(worldTitle, greaterThan(modSetting));
      expect(world, greaterThan(worldTitle));
      expect(modWorld, greaterThan(world));
    });

    test('谁空谁删：只有书籍设定时不留空的「世界书」标题', () {
      final setting = sectionsOf(requestOf(worldBook: ''))['setting']!;
      expect(setting, contains('# 书籍设定和要求：'));
      expect(setting, isNot(contains('# 世界书：')));
    });

    test('都空 → 整个 setting 模块消失', () {
      const empty = Book(title: '空书');
      expect(
        sectionsOf(requestOf(book: empty, worldBook: '')).containsKey('setting'),
        isFalse,
      );
    });
  });

  group('writingStyle（要求 → Mod → 范文）', () {
    test('三个子模块齐全时按序排列，范文带最高优先级导语', () {
      final style = sectionsOf(requestOf(modsBundle: mods))['writingStyle']!;
      final requirements = style.indexOf(
        PromptV3Sections.writingRequirementsTitle,
      );
      final modWriting = style.indexOf('# 文笔要求与参考段落：');
      final reference = style.indexOf('# 文笔参考范文：');
      expect(requirements, 0, reason: '文笔要求排最前');
      expect(modWriting, greaterThan(requirements));
      expect(reference, greaterThan(modWriting));
      expect(style, contains(PromptV3Sections.styleReferenceLead));
      expect(style, contains('用户范文：短句为主。'));
    });

    test('Mod 文笔为空 → 连标题一起删；没有范文 → 整块删', () {
      final style = sectionsOf(requestOf())['writingStyle']!;
      expect(style, isNot(contains('# 文笔要求与参考段落：')));
      expect(style, contains('# 文笔参考范文：'));

      const noReference = Book(title: 'x', writingRequirements: '只要要求');
      final onlyRequirements = sectionsOf(requestOf(book: noReference))['writingStyle']!;
      expect(onlyRequirements, isNot(contains('# 文笔参考范文：')));
      expect(onlyRequirements, isNot(contains(PromptV3Sections.styleReferenceLead)));
    });
  });

  group('accordEnding（工具指南 + 文风口径）', () {
    test('无工具：指南连标题一起删，只剩文风口径', () {
      final ending = sectionsOf(requestOf())['accordEnding']!;
      expect(ending, isNot(contains('# 简要工具指南：')));
      expect(ending, startsWith('# 文风口径：'));
      expect(ending, contains('沿用上文 assistant 的措辞与腔调为错误行为'));
    });

    test('Chat（联网）：只有联网两条，顺序与 toolNames 一致', () {
      final ending = sectionsOf(
        requestOf(
          toolNames: const ['narrchat_webSearch', 'narrchat_webFetchPage'],
        ),
      )['accordEnding']!;
      final search = ending.indexOf('- `narrchat_webSearch`：执行联网搜索');
      final fetch = ending.indexOf('- `narrchat_webFetchPage`：打开网页并读取正文');
      expect(search, greaterThan(0));
      expect(fetch, greaterThan(search));
      expect(ending, isNot(contains('narrchat_readHistory')));
    });

    test('Agent：历史两条 + 联网两条，未知名忽略、重复名只出一次', () {
      final ending = sectionsOf(
        requestOf(
          mode: PromptMode.agentLv1,
          toolNames: const [
            'narrchat_readHistory',
            'narrchat_editHistory',
            'narrchat_webSearch',
            'narrchat_webFetchPage',
            'narrchat_unknown',
            'narrchat_readHistory',
          ],
        ),
      )['accordEnding']!;
      expect(
        ending.split('\n').where((line) => line.startsWith('- `')).length,
        4,
      );
      expect(ending, isNot(contains('narrchat_unknown')));
      expect(ending, contains('仅限维护回合使用'));
      expect(ending, contains('必须使用该工具阅读最相关的 1~3 个页面'));
    });

    test('模块内顺序：工具指南在文风口径之前', () {
      final ending = sectionsOf(
        requestOf(toolNames: const ['narrchat_readHistory']),
      )['accordEnding']!;
      expect(
        ending.indexOf('# 简要工具指南：'),
        lessThan(ending.indexOf('# 文风口径：')),
      );
    });
  });
}
