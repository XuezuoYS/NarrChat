import '../../models/book.dart';
import '../../models/book_creation_draft.dart';
import '../../models/mod.dart';
import '../../models/role_category.dart';
import '../../models/world_book_entry.dart';
import '../mods_bundle_builder.dart';
import '../prompt_interface.dart';
import '../world_book_scanner.dart';

/// 「一句话创建新书」的两层检查：
///
/// - [completenessProblems]：AI 内容完整性（决定是否发起补充轮 / 询问用户）；
/// - [verifyPersisted]：落库回读 + 提示词生效校验（失败按数据库错误回滚）。
class BookCreationVerifier {
  const BookCreationVerifier({
    this.prompt = promptInterface,
    this.scanner = const WorldBookScanner(),
    this.bundleBuilder = const ModsBundleBuilder(),
  });

  /// 叙事提示词接口（生产用全局绑定；测试可注入空实现验证「生效校验」）。
  final PromptInterface prompt;

  /// 世界书关键词扫描器。
  final WorldBookScanner scanner;

  /// Mod 束拼装器。
  final ModsBundleBuilder bundleBuilder;

  /// AI 内容完整性：只检查「必须有内容」的字段，不评判文采与篇幅。
  ///
  /// 返回人类可读的中文问题清单（空 = 完整）。保持顺序稳定，便于测试与展示。
  static List<String> completenessProblems(BookCreationDraft draft) {
    final problems = <String>[];
    if (draft.title.trim().isEmpty) problems.add('书名缺失');
    if (draft.category.trim().isEmpty) problems.add('分类缺失');
    if (draft.baseSetting.trim().isEmpty) problems.add('基础设定缺失');

    if (draft.worldBook.isEmpty) {
      problems.add('世界书为空');
    } else {
      for (var i = 0; i < draft.worldBook.length; i++) {
        final entry = draft.worldBook[i];
        final keyword = entry.keyword.trim();
        final content = entry.content.trim();
        if (keyword.isEmpty) problems.add('第 ${i + 1} 条世界书缺少关键词');
        if (content.isEmpty) problems.add('第 ${i + 1} 条世界书内容为空');
      }
    }

    if (draft.globalPrePrompt.trim().isEmpty) problems.add('前置词缺失');
    if (draft.globalPostPrompt.trim().isEmpty) problems.add('后置词缺失');
    if (draft.writingRequirements.trim().isEmpty) problems.add('文笔要求缺失');

    if (draft.roleCategories.isEmpty) {
      problems.add('角色类别缺失');
    } else {
      final seen = <String>{};
      for (final category in draft.roleCategories) {
        final name = category.name.trim();
        if (name.isEmpty) {
          problems.add('有角色类别缺少名称');
          continue;
        }
        if (!seen.add(name)) problems.add('角色类别「$name」重复');
        if (category.format.trim().isEmpty) {
          problems.add('角色类别「$name」的描述格式为空');
        }
      }
    }

    return _dedupe(problems);
  }

  /// 落库回读 + 提示词生效校验。
  ///
  /// 输入全部来自**写库之后重新读取**的数据（不是内存草稿）：
  /// - 字段 / 世界书 / 启用 Mod 是否与期望一致；
  /// - 用回读出的 `Book` + 世界书 + Mod 重新拼装一次叙事提示词，
  ///   确认每个非空内容都真实出现在 system / user 文本里（「每处都生效」）。
  List<String> verifyPersisted({
    required Book expectedBook,
    required Book savedBook,
    required List<WorldBookEntry> expectedEntries,
    required List<WorldBookEntry> savedEntries,
    required List<String> expectedStorageModRefs,
    required List<String> savedStorageModRefs,
    required List<Mod> persistedMods,
  }) {
    final problems = <String>[];

    _compareText(problems, '书名', expectedBook.title, savedBook.title);
    _compareText(problems, '分类', expectedBook.category, savedBook.category);
    _compareText(
      problems,
      '基础设定',
      expectedBook.baseSetting,
      savedBook.baseSetting,
    );
    _compareText(
      problems,
      '文笔要求',
      expectedBook.writingRequirements,
      savedBook.writingRequirements,
    );
    _compareText(
      problems,
      '全局前置词',
      expectedBook.globalPrePrompt,
      savedBook.globalPrePrompt,
    );
    _compareText(
      problems,
      '全局后置词',
      expectedBook.globalPostPrompt,
      savedBook.globalPostPrompt,
    );
    _compareText(
      problems,
      '角色层级',
      expectedBook.roleHierarchy,
      savedBook.roleHierarchy,
    );
    _compareRoleCategories(
      problems,
      expectedBook.roleCategories,
      savedBook.roleCategories,
    );
    _compareWorldBook(problems, expectedEntries, savedEntries);
    _compareModRefs(
      problems,
      expectedStorageModRefs,
      savedStorageModRefs,
    );

    _checkPromptInjection(
      problems,
      expectedBook: expectedBook,
      savedBook: savedBook,
      expectedEntries: expectedEntries,
      savedEntries: savedEntries,
      persistedMods: persistedMods,
    );

    return _dedupe(problems);
  }

  // ---------------------------------------------------------------------------
  // 字段比对
  // ---------------------------------------------------------------------------

  static void _compareText(
    List<String> problems,
    String label,
    String expected,
    String actual,
  ) {
    if (expected.trim() != actual.trim()) {
      problems.add('$label 未正确写入');
    }
  }

  static void _compareRoleCategories(
    List<String> problems,
    List<RoleCategory> expected,
    List<RoleCategory> actual,
  ) {
    if (expected.length != actual.length) {
      problems.add('角色类别数量不一致');
      return;
    }
    for (var i = 0; i < expected.length; i++) {
      if (expected[i].name.trim() != actual[i].name.trim() ||
          expected[i].format.trim() != actual[i].format.trim()) {
        problems.add('角色类别「${expected[i].name.trim()}」未正确写入');
      }
    }
  }

  static void _compareWorldBook(
    List<String> problems,
    List<WorldBookEntry> expected,
    List<WorldBookEntry> actual,
  ) {
    final expectedCounts = _worldBookCounts(expected);
    final actualCounts = _worldBookCounts(actual);

    for (final entry in expectedCounts.entries) {
      final have = actualCounts[entry.key] ?? 0;
      if (have < entry.value) {
        problems.add('世界书条目「${_worldBookLabel(entry.key)}」未写入');
      }
    }
    for (final entry in actualCounts.entries) {
      final want = expectedCounts[entry.key] ?? 0;
      if (entry.value > want) {
        problems.add('世界书多出条目「${_worldBookLabel(entry.key)}」');
      }
    }
  }

  static Map<String, int> _worldBookCounts(List<WorldBookEntry> entries) {
    final counts = <String, int>{};
    for (final entry in entries) {
      final key = '${entry.keyword.trim()}\u0000${entry.content.trim()}\u0000'
          '${entry.isActive ? 1 : 0}';
      counts[key] = (counts[key] ?? 0) + 1;
    }
    return counts;
  }

  static String _worldBookLabel(String key) {
    final keyword = key.split('\u0000').first;
    if (keyword.isEmpty) return '第 1 条（无关键词）';
    return keyword.length <= 20 ? keyword : '${keyword.substring(0, 20)}…';
  }

  static void _compareModRefs(
    List<String> problems,
    List<String> expected,
    List<String> actual,
  ) {
    if (expected.length != actual.length) {
      problems.add('启用 Mod 数量不一致');
      return;
    }
    for (var i = 0; i < expected.length; i++) {
      if (expected[i] != actual[i]) {
        problems.add('第 ${i + 1} 个启用 Mod 未正确写入');
        return;
      }
    }
  }

  // ---------------------------------------------------------------------------
  // 提示词生效校验
  // ---------------------------------------------------------------------------

  void _checkPromptInjection(
    List<String> problems, {
    required Book expectedBook,
    required Book savedBook,
    required List<WorldBookEntry> expectedEntries,
    required List<WorldBookEntry> savedEntries,
    required List<Mod> persistedMods,
  }) {
    final probe = _probeInput(expectedEntries, persistedMods);
    final scanned = scanner.scan(
      userInput: probe,
      historyRounds: const [],
      entries: savedEntries,
    );
    final bundle = bundleBuilder.build(
      mods: persistedMods,
      userInput: probe,
      historyRounds: const [],
    );
    final request = PromptRequest(
      book: savedBook,
      mode: PromptMode.chat,
      userInput: '',
      worldBookEntries: scanned,
      mods: bundle,
    );
    final system = prompt.system(request);
    final user = prompt.user(request);

    _expectContains(problems, system, '书名', expectedBook.title);
    _expectContains(problems, system, '分类', expectedBook.category);
    _expectContains(problems, system, '基础设定', expectedBook.baseSetting);
    _expectContains(
      problems,
      system,
      '文笔要求',
      expectedBook.writingRequirements,
    );
    _expectContains(problems, user, '全局前置词', expectedBook.globalPrePrompt);
    _expectContains(problems, user, '全局后置词', expectedBook.globalPostPrompt);
    _expectContains(
      problems,
      system,
      '角色层级',
      expectedBook.roleHierarchy,
    );

    for (final category in expectedBook.roleCategories) {
      final name = category.name.trim();
      final format = category.format.trim();
      if (name.isNotEmpty) {
        _expectContains(problems, system, '角色类别「$name」', '【$name】');
      }
      _expectContains(
        problems,
        system,
        '角色类别「$name」的描述格式',
        format,
      );
    }

    for (final entry in expectedEntries) {
      _expectContains(
        problems,
        system,
        '世界书条目「${_worldBookLabel(entry.keyword)}」',
        entry.content,
      );
    }

    _expectContains(problems, system, '所选 Mod 的系统提示词', bundle.systemPrompts);
    _expectContains(problems, system, '所选 Mod 的世界书', bundle.worldBooks);
    _expectContains(problems, user, '所选 Mod 的前置词', bundle.prePrompts);
    _expectContains(problems, user, '所选 Mod 的后置词', bundle.postPrompts);

    for (final mod in persistedMods) {
      for (final entry in mod.worldBookEntries) {
        if (entry.content.trim().isEmpty) continue;
        _expectContains(
          problems,
          system,
          'Mod「${mod.name.trim()}」的世界书条目',
          entry.content,
        );
      }
    }
  }

  static String _probeInput(
    List<WorldBookEntry> entries,
    List<Mod> mods,
  ) {
    final keywords = <String>[
      for (final entry in entries) entry.keyword,
      for (final mod in mods)
        for (final entry in mod.worldBookEntries) entry.keyword,
    ];
    return keywords.join('\n');
  }

  static void _expectContains(
    List<String> problems,
    String haystack,
    String label,
    String value,
  ) {
    final needle = value.trim();
    if (needle.isEmpty) return;
    if (!haystack.contains(needle)) {
      problems.add('$label 没有出现在拼装后的提示词里');
    }
  }

  static List<String> _dedupe(List<String> values) {
    final seen = <String>{};
    return [
      for (final value in values)
        if (seen.add(value)) value,
    ];
  }
}
