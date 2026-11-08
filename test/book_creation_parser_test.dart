import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/mod.dart';
import 'package:narrchat/services/book_creation/book_creation_parser.dart';

/// 创建流程标签解析器：宽容解析、坏块只丢自己、未知 Mod 只警告。
void main() {
  const parser = BookCreationParser();
  const catalog = [
    Mod(
      presetKey: 'web_novel_style',
      name: '默认网文语感强化',
      description: '强化网文语感',
    ),
    Mod(
      uuid: 'user-1',
      name: '我的修仙 Mod',
      description: '修仙向',
    ),
  ];

  group('标题与类别', () {
    test('解析基本标签并清理围栏 / 换行', () {
      final result = parser.parseTitleCategory('''
```text
<title>
  妖灵事务所
</title>
<category>都市奇幻</category>
```
''');
      expect(result.title, '妖灵事务所');
      expect(result.category, '都市奇幻');
      expect(result.warnings, isEmpty);
    });

    test('缺标签时只给出提醒，不抛异常', () {
      final result = parser.parseTitleCategory('<title>只有标题</title>');
      expect(result.title, '只有标题');
      expect(result.category, isNull);
      expect(result.warnings, contains('没有找到 <category> 标签'));
    });

    test('单行字段折叠内部换行', () {
      final result = parser.parseTitleCategory(
        '<title>第一行\n第二行</title><category> 分类 </category>',
      );
      expect(result.title, '第一行 第二行');
      expect(result.category, '分类');
    });
  });

  group('Mod 选择', () {
    test('ref / 存储形态 / 名称都能识别，重复项去重', () {
      final result = parser.parseMods(
        '''
<mods>
<mod>preset:web_novel_style</mod>
<mod>preset::web_novel_style</mod>
<mod>我的修仙 Mod</mod>
<mod>user-1</mod>
</mods>
''',
        catalog,
      );
      expect(result.modRefs, ['preset:web_novel_style', 'user:user-1']);
      expect(result.warnings, isEmpty);
    });

    test('未知 Mod 忽略并警告；空 mods 块表示不选', () {
      final unknown = parser.parseMods(
        '<mods><mod>不存在的 Mod</mod></mods>',
        catalog,
      );
      expect(unknown.modRefs, isEmpty);
      expect(unknown.warnings.single, contains('无法识别的 Mod'));

      final empty = parser.parseMods('<mods></mods>', catalog);
      expect(empty.modRefs, isEmpty);
      expect(empty.warnings, isEmpty);
    });

    test('超过上限截断并警告', () {
      final many = [
        for (var i = 0; i < 12; i++)
          Mod(uuid: 'u$i', name: 'Mod$i'),
      ];
      final tags = [
        for (var i = 0; i < 12; i++) '<mod>user:u$i</mod>',
      ].join();
      final result = parser.parseMods('<mods>$tags</mods>', many);
      expect(result.modRefs!.length, 8);
      expect(result.warnings.single, contains('超过 8 个'));
    });

    test('没有 mods 标签时给出提醒（补充轮模式不提醒）', () {
      expect(
        parser.parseMods('没有任何标签', catalog).warnings,
        contains('没有找到 <mods> 标签'),
      );
      expect(
        parser.parseMods(
          '没有任何标签',
          catalog,
          allowMissing: true,
        ).warnings,
        isEmpty,
      );
    });
  });

  group('基础设定与世界书', () {
    test('解析多行内容与多条世界书条目', () {
      final result = parser.parseBaseSettingWorldBook('''
<baseSetting>
- 世界：现代都市
- 规则：妖灵不可被普通人看见
</baseSetting>
<worldBook>
<entry>
<keyword>事务所, 委托</keyword>
<content>事务所位于旧城区，只接待妖怪委托。</content>
</entry>
<entry>
<keyword>妖灵</keyword>
<content>妖灵由人的执念化成。</content>
</entry>
</worldBook>
''');
      expect(result.baseSetting, contains('现代都市'));
      expect(result.worldBook, hasLength(2));
      expect(result.worldBook!.first.keyword, '事务所, 委托');
      expect(result.worldBook!.first.content, contains('旧城区'));
      expect(result.worldBook!.first.isActive, isTrue);
    });

    test('关键词 / 内容为空的条目保留（交给完整性检查点名）', () {
      final result = parser.parseBaseSettingWorldBook('''
<baseSetting>x</baseSetting>
<worldBook>
<entry>
<keyword></keyword>
<content>有内容没关键词</content>
</entry>
<entry>
<keyword>有词</keyword>
<content></content>
</entry>
<entry>
</entry>
</worldBook>
''');
      expect(result.worldBook, hasLength(2));
      expect(result.worldBook![0].keyword, isEmpty);
      expect(result.worldBook![0].content, '有内容没关键词');
      expect(result.worldBook![1].content, isEmpty);
      expect(result.warnings.single, contains('完全为空'));
    });

    test('缺 worldBook 标签时 worldBook 为 null（不是空列表）', () {
      final result = parser.parseBaseSettingWorldBook(
        '<baseSetting>只有设定</baseSetting>',
      );
      expect(result.baseSetting, '只有设定');
      expect(result.worldBook, isNull);
      expect(result.warnings, contains('没有找到 <worldBook> 标签'));
    });
  });

  group('前后置词与文笔要求', () {
    test('三块都解析，保留内部换行', () {
      final result = parser.parsePrompts('''
<prePrompt>
遵守设定。
不要 OOC。
</prePrompt>
<postPrompt>不要写现代网络流行语。</postPrompt>
<writingRequirements>多用短句，少用排比。</writingRequirements>
''');
      expect(result.prePrompt, '遵守设定。\n不要 OOC。');
      expect(result.postPrompt, '不要写现代网络流行语。');
      expect(result.writingRequirements, '多用短句，少用排比。');
    });

    test('缺标签给出提醒，补充轮模式不提醒', () {
      expect(
        parser.parsePrompts('<prePrompt>x</prePrompt>').warnings,
        contains('没有找到 <postPrompt> 标签'),
      );
      expect(
        parser.parsePrompts(
          '<prePrompt>x</prePrompt>',
          allowMissing: true,
        ).warnings,
        isEmpty,
      );
    });
  });

  group('角色类别与描述格式', () {
    test('解析多类别与多行格式', () {
      final result = parser.parseRoleCategories('''
<roleCategories>
<category>
<name>主角</name>
<format>- 姓名：
- 当前状态：</format>
</category>
<category>
<name>NPC</name>
<format>- 姓名：
- 所属组织：</format>
</category>
</roleCategories>
''');
      expect(result.roleCategories, hasLength(2));
      expect(result.roleCategories![0].name, '主角');
      expect(result.roleCategories![0].format, contains('当前状态'));
      expect(result.roleCategories![1].name, 'NPC');
    });

    test('重名与空字段保留，完整性问题由校验器报告', () {
      final result = parser.parseRoleCategories('''
<roleCategories>
<category><name>主角</name><format>a</format></category>
<category><name>主角</name><format>b</format></category>
<category><name></name><format>c</format></category>
</roleCategories>
''');
      expect(result.roleCategories, hasLength(3));
      expect(result.roleCategories![0].name, '主角');
      expect(result.roleCategories![1].name, '主角');
      expect(result.roleCategories![2].name, isEmpty);
    });

    test('缺标签 -> null；块内无条目 -> 空列表 + 提醒', () {
      expect(
        parser.parseRoleCategories('无').roleCategories,
        isNull,
      );
      final empty = parser.parseRoleCategories(
        '<roleCategories></roleCategories>',
      );
      expect(empty.roleCategories, isEmpty);
      expect(empty.warnings, contains('没有解析到角色类别'));
    });
  });

  group('补充轮全量解析与可见文本', () {
    test('parseAll 只返回实际出现的标签', () {
      final result = parser.parseAll(
        '<title>补的标题</title><worldBook><entry>'
        '<keyword>关键词</keyword><content>内容</content></entry>'
        '</worldBook>',
        catalog,
      );
      expect(result.title, '补的标题');
      expect(result.category, isNull);
      expect(result.worldBook, hasLength(1));
      expect(result.roleCategories, isNull);
    });

    test('visibleTextOf 去掉标签与围栏，保留正文', () {
      final visible = BookCreationParser.visibleTextOf(
        '```\n<title>书名</title>\n<category>分类</category>\n正文内容\n```',
      );
      expect(visible, contains('书名'));
      expect(visible, contains('分类'));
      expect(visible, contains('正文内容'));
      expect(visible, isNot(contains('<title>')));
      expect(visible, isNot(contains('```')));
    });
  });
}
