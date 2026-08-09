import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/database/mod_dao.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/mod.dart';
import 'package:narrchat/models/preset_mods.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/providers/mod_provider.dart';
import 'package:narrchat/services/prompt_builder.dart';

void main() {
  group('Mod 模型', () {
    test('toJson / fromJson 往返一致', () {
      const mod = Mod(
        name: '测试 Mod',
        description: '用于测试',
        prePrompt: '前置内容',
        postPrompt: '后置内容',
        systemPrompt: '系统内容',
        worldBookEntries: [
          ModWorldBookEntry(keyword: '青云宗, 山门', content: '宗门设定'),
          ModWorldBookEntry(content: '恒定生效内容'),
        ],
      );
      final json = mod.toJson();
      expect(json['type'], 'narrchat_mod');
      expect(json['version'], 1);
      expect(json['name'], '测试 Mod');

      final restored = Mod.fromJson(json);
      expect(restored, isNotNull);
      expect(restored!.name, '测试 Mod');
      expect(restored.description, '用于测试');
      expect(restored.prePrompt, '前置内容');
      expect(restored.postPrompt, '后置内容');
      expect(restored.systemPrompt, '系统内容');
      expect(restored.worldBookEntries, hasLength(2));
      expect(restored.worldBookEntries.first.keyword, '青云宗, 山门');
      expect(restored.worldBookEntries.first.content, '宗门设定');
      expect(restored.worldBookEntries.last.keyword, '');
      expect(restored.worldBookEntries.last.content, '恒定生效内容');
      expect(restored.id, isNull);
      expect(restored.isPreset, isFalse);
    });

    test('fromJson 兼容旧版 worldBook 字符串（整体作为恒定条目）', () {
      final restored = Mod.fromJson(const {
        'name': '旧版',
        'worldBook': '旧格式世界书内容',
      });
      expect(restored, isNotNull);
      expect(restored!.worldBookEntries, hasLength(1));
      expect(restored.worldBookEntries.first.keyword, '');
      expect(restored.worldBookEntries.first.content, '旧格式世界书内容');
    });

    test('fromJson 缺失名称为空时返回 null（导入跳过）', () {
      expect(Mod.fromJson(const {'prePrompt': '内容'}), isNull);
      expect(Mod.fromJson(const {'name': ''}), isNull);
      expect(Mod.fromJson(const {'name': '   '}), isNull);
    });

    test('fromMap / toMap 数据库列映射（世界书存 JSON 数组）', () {
      const mod = Mod(
        id: 7,
        name: '映射',
        prePrompt: 'P',
        postPrompt: 'Q',
        systemPrompt: 'S',
        worldBookEntries: [ModWorldBookEntry(keyword: 'K', content: 'W')],
      );
      final map = mod.toMap();
      expect(map['id'], 7);
      expect(map['name'], '映射');
      expect(map['pre_prompt'], 'P');
      expect(map['post_prompt'], 'Q');
      expect(map['system_prompt'], 'S');
      expect(map['world_book'], contains('"keyword"'));
      expect(map['world_book'], contains('"content"'));

      final restored = Mod.fromMap(map);
      expect(restored.id, 7);
      expect(restored.name, '映射');
      expect(restored.prePrompt, 'P');
      expect(restored.worldBookEntries, hasLength(1));
      expect(restored.worldBookEntries.first.keyword, 'K');
      expect(restored.worldBookEntries.first.content, 'W');
    });

    test('ref：预置与自定义的唯一标识', () {
      expect(const Mod(presetKey: 'abc').ref, 'preset:abc');
      expect(const Mod(id: 5).ref, 'user:5');
      expect(const Mod(presetKey: 'abc').isPreset, isTrue);
      expect(const Mod(id: 5).isPreset, isFalse);
    });

    test('copyWith 只修改指定字段', () {
      const mod = Mod(name: 'a', prePrompt: 'x');
      final updated = mod.copyWith(
        name: 'b',
        worldBookEntries: const [ModWorldBookEntry(keyword: 'k', content: 'w')],
      );
      expect(updated.name, 'b');
      expect(updated.worldBookEntries, hasLength(1));
      expect(updated.prePrompt, 'x');
      expect(updated.description, '');
    });
  });

  group('ModWorldBookEntry', () {
    test('关键词拆分', () {
      const entry = ModWorldBookEntry(keyword: '青云宗, 山门、道场；古寺', content: 'x');
      expect(entry.keywords, ['青云宗', '山门', '道场', '古寺']);
      expect(const ModWorldBookEntry(keyword: '', content: 'x').keywords, isEmpty);
      expect(const ModWorldBookEntry(keyword: '   ', content: 'x').keywords, isEmpty);
    });

    test('encodeList / decodeList 往返', () {
      const entries = [
        ModWorldBookEntry(keyword: '宗门', content: '宗门内容'),
        ModWorldBookEntry(content: '恒定内容'),
      ];
      final raw = ModWorldBookEntry.encodeList(entries);
      final decoded = ModWorldBookEntry.decodeList(raw);
      expect(decoded, hasLength(2));
      expect(decoded.first.keyword, '宗门');
      expect(decoded.last.content, '恒定内容');
    });

    test('decodeList 兼容旧版纯文本（非 JSON）', () {
      final decoded = ModWorldBookEntry.decodeList('旧版纯文本内容');
      expect(decoded, hasLength(1));
      expect(decoded.first.keyword, '');
      expect(decoded.first.content, '旧版纯文本内容');
      expect(ModWorldBookEntry.decodeList(''), isEmpty);
      expect(ModWorldBookEntry.decodeList(null), isEmpty);
    });
  });

  group('ModsBundle', () {
    test('empty 判定', () {
      expect(ModsBundle.empty.isEmpty, isTrue);
      expect(const ModsBundle(prePrompts: 'x').isEmpty, isFalse);
      expect(const ModsBundle(worldBooks: 'w').isEmpty, isFalse);
    });
  });

  group('BookModConfig', () {
    test('ref 与 fromMap/toMap', () {
      const config = BookModConfig(
        bookId: 3,
        presetKey: 'web_novel_style',
        isEnabled: false,
        sortOrder: 2,
      );
      expect(config.ref, 'preset:web_novel_style');
      final map = config.toMap();
      expect(map['book_id'], 3);
      expect(map['preset_key'], 'web_novel_style');
      expect(map['is_enabled'], 0);
      expect(map['sort_order'], 2);

      final restored = BookModConfig.fromMap(map);
      expect(restored.ref, 'preset:web_novel_style');
      expect(restored.isEnabled, isFalse);
      expect(restored.sortOrder, 2);

      expect(const BookModConfig(modId: 9).ref, 'user:9');
      expect(
        const BookModConfig(modId: 9).copyWith(isEnabled: true).isEnabled,
        isTrue,
      );
    });
  });

  group('PresetMods', () {
    test('预置列表非空且可按键查找', () {
      expect(PresetMods.all, isNotEmpty);
      final first = PresetMods.all.first;
      expect(first.isPreset, isTrue);
      expect(PresetMods.byKey(first.presetKey), isNotNull);
      expect(PresetMods.byKey('not_exist'), isNull);
      expect(PresetMods.byKey(null), isNull);
    });
  });

  group('ModProvider 世界书解析', () {
    test('关键词命中才注入，恒定条目始终注入', () async {
      final provider = ModProvider(
        dao: _MockModDao(
          mods: const [
            Mod(
              id: 1,
              name: '测试 Mod',
              prePrompt: 'PRE',
              postPrompt: 'POST',
              systemPrompt: 'SYS',
              worldBookEntries: [
                ModWorldBookEntry(keyword: '青云宗, 山门', content: '宗门设定内容'),
                ModWorldBookEntry(content: '恒定生效内容'),
              ],
            ),
          ],
          configs: const [
            BookModConfig(bookId: 1, modId: 1, isEnabled: true, sortOrder: 0),
          ],
        ),
      );

      // 命中关键词：恒定条目 + 命中条目都注入
      final hit = await provider.resolveModsBundle(
        bookId: 1,
        userInput: '我踏入青云宗。',
        historyRounds: const [],
      );
      expect(hit.prePrompts, 'PRE');
      expect(hit.postPrompts, 'POST');
      expect(hit.systemPrompts, 'SYS');
      expect(hit.worldBooks, contains('宗门设定内容'));
      expect(hit.worldBooks, contains('恒定生效内容'));

      // 未命中关键词：只注入恒定条目
      final miss = await provider.resolveModsBundle(
        bookId: 1,
        userInput: '我在集市闲逛。',
        historyRounds: const [],
      );
      expect(miss.worldBooks, isNot(contains('宗门设定内容')));
      expect(miss.worldBooks, contains('恒定生效内容'));

      // 历史轮次命中关键词也注入
      final fromHistory = await provider.resolveModsBundle(
        bookId: 1,
        userInput: '继续前行。',
        historyRounds: const [
          Round(
            id: 1,
            bookId: 1,
            roundIndex: 1,
            aiNarrative: '山门巍峨，云雾缭绕。',
          ),
        ],
      );
      expect(fromHistory.worldBooks, contains('宗门设定内容'));
    });

    test('未启用或引用不存在的 Mod 被忽略', () async {
      final provider = ModProvider(
        dao: _MockModDao(
          mods: const [
            Mod(id: 1, name: 'A', worldBookEntries: [
              ModWorldBookEntry(content: 'A 恒定'),
            ]),
          ],
          configs: const [
            BookModConfig(bookId: 1, modId: 1, isEnabled: false, sortOrder: 0),
            BookModConfig(bookId: 1, modId: 999, isEnabled: true, sortOrder: 1),
          ],
        ),
      );
      final bundle = await provider.resolveModsBundle(
        bookId: 1,
        userInput: 'x',
        historyRounds: const [],
      );
      expect(bundle.isEmpty, isTrue);
    });
  });

  group('PromptBuilder Mod 注入', () {
    const book = Book(
      id: 1,
      title: '测试书',
      baseSetting: '修仙世界',
      globalPrePrompt: '用户前置',
      globalPostPrompt: '用户后置',
    );

    const lastRound = Round(id: 1, bookId: 1, roundIndex: 1);

    test('启用 Mod 时注入前置词/后置词/系统提示词/世界书', () {
      const mods = ModsBundle(
        prePrompts: 'MOD_PRE',
        postPrompts: 'MOD_POST',
        systemPrompts: 'MOD_SYS',
        worldBooks: 'MOD_WB',
      );
      final prompts = const PromptBuilder().build(
        book: book,
        lastRound: lastRound,
        userInput: '输入',
        mods: mods,
      );

      // System：Mod 系统提示词 + Mod 世界书注入
      expect(prompts.systemPrompt, contains('Mod 系统提示词：'));
      expect(prompts.systemPrompt, contains('MOD_SYS'));
      expect(prompts.systemPrompt, contains('Mod 世界书注入：'));
      expect(prompts.systemPrompt, contains('MOD_WB'));

      // User：前置词区与后置词区
      expect(prompts.userPrompt, contains('【Mod 前置词】'));
      expect(prompts.userPrompt, contains('MOD_PRE'));
      expect(prompts.userPrompt, contains('【Mod 后置词】'));
      expect(prompts.userPrompt, contains('MOD_POST'));

      // 顺序：用户自定义前置词在 Mod 前置词之前；用户自定义后置词在 Mod 后置词之前
      final userPrompt = prompts.userPrompt;
      expect(
        userPrompt.indexOf('用户前置') < userPrompt.indexOf('MOD_PRE'),
        isTrue,
      );
      expect(
        userPrompt.indexOf('用户后置') < userPrompt.indexOf('MOD_POST'),
        isTrue,
      );
    });

    test('未启用 Mod（bundle 为空）时不注入 Mod 区块', () {
      final prompts = const PromptBuilder().build(
        book: book,
        lastRound: lastRound,
        userInput: '输入',
      );
      expect(prompts.systemPrompt, isNot(contains('Mod 系统提示词')));
      expect(prompts.systemPrompt, isNot(contains('Mod 世界书注入')));
      expect(prompts.userPrompt, isNot(contains('【Mod 前置词】')));
      expect(prompts.userPrompt, isNot(contains('【Mod 后置词】')));
    });

    test('空内容的 Mod 区块不输出', () {
      const mods = ModsBundle(prePrompts: '', postPrompts: '', systemPrompts: '', worldBooks: '');
      final prompts = const PromptBuilder().build(
        book: book,
        lastRound: lastRound,
        userInput: '输入',
        mods: mods,
      );
      expect(prompts.systemPrompt, isNot(contains('Mod 系统提示词')));
      expect(prompts.systemPrompt, isNot(contains('Mod 世界书注入')));
      expect(prompts.userPrompt, isNot(contains('【Mod 前置词】')));
      expect(prompts.userPrompt, isNot(contains('【Mod 后置词】')));
    });
  });
}

/// 内存版 ModDao，避免测试依赖 sqflite。
class _MockModDao extends ModDao {
  final List<Mod> mods;
  final List<BookModConfig> configs;

  _MockModDao({required this.mods, required this.configs});

  @override
  Future<List<Mod>> getAllMods() async => mods;

  @override
  Future<List<BookModConfig>> getBookMods(int bookId) async =>
      configs.where((c) => c.bookId == bookId).toList();
}
