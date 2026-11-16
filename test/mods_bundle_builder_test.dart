import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/models/mod.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/services/mods_bundle_builder.dart';

/// `ModsBundleBuilder`：七列 → 七段内容的映射、顺序与空块口径。
///
/// 设计真源：`docs/mods.md` §二（列 → 注入位）与 §三（拼合规则）。
/// 这里只测「拼合」；各段最终落到提示词的哪个位置由
/// `test/prompt_v3_modules_test.dart` 与 `test/prompt_interface_test.dart` 断言。
void main() {
  const builder = ModsBundleBuilder();

  Mod modOf(
    String name, {
    String pre = '',
    String post = '',
    String must = '',
    String system = '',
    String setting = '',
    String writing = '',
    List<ModWorldBookEntry> worldBook = const [],
  }) => Mod(
    name: name,
    prePrompt: pre,
    postPrompt: post,
    systemMust: must,
    systemPrompt: system,
    systemSetting: setting,
    systemWritingStyle: writing,
    worldBookEntries: worldBook,
  );

  test('五列各归各段，不串位', () {
    final bundle = builder.build(
      mods: [
        modOf(
          '甲',
          pre: 'PRE',
          post: 'POST',
          must: 'MUST',
          system: 'SYS',
          setting: 'SETTING',
          writing: 'WRITING',
        ),
      ],
      userInput: '',
    );
    expect(bundle.prePrompts, 'PRE');
    expect(bundle.postPrompts, 'POST');
    expect(bundle.mustPrompts, 'MUST');
    expect(bundle.systemPrompts, 'SYS');
    expect(bundle.settingPrompts, 'SETTING');
    expect(bundle.writingStylePrompts, 'WRITING');
    expect(bundle.mustSegments, ['MUST']);
    expect(bundle.isEmpty, isFalse);
  });

  test('同列多个 Mod 按置入顺序、块间一个空行', () {
    final bundle = builder.build(
      mods: [
        modOf('甲', must: 'M1', system: 'S1', setting: 'T1', writing: 'W1'),
        modOf('乙', must: 'M2', system: 'S2', setting: 'T2', writing: 'W2'),
      ],
      userInput: '',
    );
    expect(bundle.mustPrompts, 'M1\n\nM2');
    expect(bundle.systemPrompts, 'S1\n\nS2');
    expect(bundle.settingPrompts, 'T1\n\nT2');
    expect(bundle.writingStylePrompts, 'W1\n\nW2');
    // 强指令的逐块形态与拼合结果同源（mustReverse 要按块反转）。
    expect(bundle.mustSegments, ['M1', 'M2']);
  });

  test('每块先归一化：去行尾空白、3 个以上空行折成一个', () {
    final bundle = builder.build(
      mods: [
        modOf('甲', system: '  第一行  \n\n\n\n第二行  '),
        modOf('乙', system: '乙的正文'),
      ],
      userInput: '',
    );
    expect(bundle.systemPrompts, '第一行\n\n第二行\n\n乙的正文');
  });

  test('空列不接：全空 Mod 不往任何一段里塞空串', () {
    final bundle = builder.build(mods: [modOf('空 Mod')], userInput: '');
    expect(bundle.isEmpty, isTrue);
    expect(bundle.mustSegments, isEmpty);
  });

  test('没有 Mod → 固定的空 bundle', () {
    expect(builder.build(mods: const [], userInput: ''), isA<ModsBundle>());
    expect(builder.build(mods: const [], userInput: '').isEmpty, isTrue);
  });

  test('世界书：恒定生效条目恒在，关键词命中才注入', () {
    final bundle = builder.build(
      mods: [
        modOf(
          '甲',
          worldBook: const [
            ModWorldBookEntry(content: '恒定内容'),
            ModWorldBookEntry(keyword: '宗门', content: '宗门内容'),
          ],
        ),
      ],
      userInput: '我走进宗门',
    );
    expect(bundle.worldBooks, contains('恒定内容'));
    expect(bundle.worldBooks, contains('宗门内容'));
    expect(
      bundle.worldBooks.indexOf('恒定内容'),
      lessThan(bundle.worldBooks.indexOf('宗门内容')),
      reason: '恒定生效条目排在命中条目之前',
    );
  });

  test('世界书：关键词没命中就不注入；命中来源可来自历史轮次', () {
    final missed = builder.build(
      mods: [
        modOf(
          '甲',
          worldBook: const [ModWorldBookEntry(keyword: '雷劫', content: '渡劫设定')],
        ),
      ],
      userInput: '我走进宗门',
    );
    expect(missed.worldBooks, isEmpty);

    final fromHistory = builder.build(
      mods: [
        modOf(
          '甲',
          worldBook: const [ModWorldBookEntry(keyword: '雷劫', content: '渡劫设定')],
        ),
      ],
      userInput: '我继续走',
      historyRounds: const [
        Round(id: 1, bookUuid: 'b1', roundIndex: 1, aiNarrative: '天边雷劫将至。'),
      ],
    );
    expect(fromHistory.worldBooks, contains('渡劫设定'));
  });

  test('空世界书内容条目被忽略（不产生空段）', () {
    final bundle = builder.build(
      mods: [
        modOf(
          '甲',
          worldBook: const [ModWorldBookEntry(keyword: '宗门', content: '   ')],
        ),
      ],
      userInput: '宗门',
    );
    expect(bundle.worldBooks, isEmpty);
  });
}
