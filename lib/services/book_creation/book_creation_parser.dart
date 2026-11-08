import '../../models/mod.dart';
import '../../models/role_category.dart';
import '../../models/world_book_entry.dart';

/// 单个阶段（或补充轮）的解析结果。
///
/// 所有字段都是「有就带上、没有就是 null」：调用方据此判断某一块是否真的
/// 在本次输出里出现，避免用空值覆盖已有内容。
class BookCreationParseResult {
  const BookCreationParseResult({
    this.title,
    this.category,
    this.modRefs,
    this.baseSetting,
    this.worldBook,
    this.prePrompt,
    this.postPrompt,
    this.writingRequirements,
    this.roleCategories,
    this.warnings = const [],
  });

  final String? title;
  final String? category;

  /// null = 输出里没有 `<mods>` 块；空列表 = 明确表示不选 Mod。
  final List<String>? modRefs;

  final String? baseSetting;

  /// null = 输出里没有 `<worldBook>` 块；空列表 = 块存在但没有条目。
  final List<WorldBookEntry>? worldBook;

  final String? prePrompt;
  final String? postPrompt;
  final String? writingRequirements;

  /// null = 输出里没有 `<roleCategories>` 块。
  final List<RoleCategory>? roleCategories;

  /// 解析提醒（不阻断流程：不完整与否由 `BookCreationVerifier` 判定）。
  final List<String> warnings;
}

/// 把模型输出按「标签协议」解析成草稿片段。
///
/// 设计口径：
/// - 标签名大小写不敏感、标签内允许空白；整体包裹的 ``` 围栏先剥离；
/// - 每块（标题 / Mod / 世界书 / 前后置词 / 角色类别）**独立解析**：
///   解析出多少算多少，坏的一块只丢它自己并记 warning，绝不整段抛异常；
/// - 字段缺失用 null 表达，交给「完整性检查 + 补充轮」兜底；
/// - 世界书 / 角色类别保留含空字段的原始项，让完整性检查能点名到具体条目。
class BookCreationParser {
  const BookCreationParser();

  /// 解析「标题与类别」阶段。
  BookCreationParseResult parseTitleCategory(
    String raw, {
    bool allowMissing = false,
  }) {
    final text = _clean(raw);
    final warnings = <String>[];
    final title = _singleLine(_tag(text, 'title'));
    final category = _singleLine(_tag(text, 'category'));
    if (!allowMissing) {
      if (title == null) warnings.add('没有找到 <title> 标签');
      if (category == null) warnings.add('没有找到 <category> 标签');
    }
    return BookCreationParseResult(
      title: title,
      category: category,
      warnings: warnings,
    );
  }

  /// 解析「选择 Mod」阶段；目录里没有的引用会被忽略并记 warning。
  BookCreationParseResult parseMods(
    String raw,
    List<Mod> catalog, {
    bool allowMissing = false,
    int maxMods = 8,
  }) {
    final text = _clean(raw);
    final warnings = <String>[];
    final block = _block(text, 'mods');
    if (block == null) {
      if (!allowMissing) warnings.add('没有找到 <mods> 标签');
      return BookCreationParseResult(modRefs: null, warnings: warnings);
    }
    final refs = _parseModRefs(block, catalog, warnings, maxMods);
    return BookCreationParseResult(modRefs: refs, warnings: warnings);
  }

  /// 解析「基础设定与世界书」阶段。
  BookCreationParseResult parseBaseSettingWorldBook(
    String raw, {
    bool allowMissing = false,
  }) {
    final text = _clean(raw);
    final warnings = <String>[];
    final baseSetting = _tag(text, 'baseSetting');
    if (baseSetting == null && !allowMissing) {
      warnings.add('没有找到 <baseSetting> 标签');
    }
    final worldBlock = _block(text, 'worldBook');
    if (worldBlock == null && !allowMissing) {
      warnings.add('没有找到 <worldBook> 标签');
    }
    final entries = worldBlock == null
        ? null
        : _parseWorldBookEntries(worldBlock, warnings);
    return BookCreationParseResult(
      baseSetting: baseSetting,
      worldBook: entries,
      warnings: warnings,
    );
  }

  /// 解析「前置词 / 后置词 / 文笔要求」阶段。
  BookCreationParseResult parsePrompts(
    String raw, {
    bool allowMissing = false,
  }) {
    final text = _clean(raw);
    final warnings = <String>[];
    final prePrompt = _tag(text, 'prePrompt');
    final postPrompt = _tag(text, 'postPrompt');
    final writingRequirements = _tag(text, 'writingRequirements');
    if (!allowMissing) {
      if (prePrompt == null) warnings.add('没有找到 <prePrompt> 标签');
      if (postPrompt == null) warnings.add('没有找到 <postPrompt> 标签');
      if (writingRequirements == null) {
        warnings.add('没有找到 <writingRequirements> 标签');
      }
    }
    return BookCreationParseResult(
      prePrompt: prePrompt,
      postPrompt: postPrompt,
      writingRequirements: writingRequirements,
      warnings: warnings,
    );
  }

  /// 解析「角色类别与描述格式」阶段。
  BookCreationParseResult parseRoleCategories(
    String raw, {
    bool allowMissing = false,
  }) {
    final text = _clean(raw);
    final warnings = <String>[];
    final block = _block(text, 'roleCategories');
    if (block == null) {
      if (!allowMissing) warnings.add('没有找到 <roleCategories> 标签');
      return BookCreationParseResult(roleCategories: null, warnings: warnings);
    }
    final categories = _parseRoleCategoryEntries(block, warnings);
    return BookCreationParseResult(
      roleCategories: categories,
      warnings: warnings,
    );
  }

  /// 一次解析全部标签（补充轮用：模型只输出需要补的那几块）。
  BookCreationParseResult parseAll(
    String raw,
    List<Mod> catalog, {
    int maxMods = 8,
  }) {
    final text = _clean(raw);
    final parts = <BookCreationParseResult>[
      parseTitleCategory(text, allowMissing: true),
      parseMods(text, catalog, allowMissing: true, maxMods: maxMods),
      parseBaseSettingWorldBook(text, allowMissing: true),
      parsePrompts(text, allowMissing: true),
      parseRoleCategories(text, allowMissing: true),
    ];
    return BookCreationParseResult(
      title: parts[0].title,
      category: parts[0].category,
      modRefs: parts[1].modRefs,
      baseSetting: parts[2].baseSetting,
      worldBook: parts[2].worldBook,
      prePrompt: parts[3].prePrompt,
      postPrompt: parts[3].postPrompt,
      writingRequirements: parts[3].writingRequirements,
      roleCategories: parts[4].roleCategories,
      warnings: [for (final part in parts) ...part.warnings],
    );
  }

  /// 流式展示用：去掉标签与围栏后的可读文本（只用于 UI，不参与解析）。
  static String visibleTextOf(String raw) {
    final text = _clean(raw)
        .replaceAll(RegExp(r'</?[A-Za-z][^>\n]*>'), ' ')
        .replaceAll(RegExp(r'[ \t]+\n'), '\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
    return text;
  }

  // ---------------------------------------------------------------------------
  // 解析小工具
  // ---------------------------------------------------------------------------

  /// 去掉整体 / 行内代码围栏，统一换行后 trim。
  static String _clean(String raw) {
    var text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    text = text.replaceAll(RegExp(r'^[ \t]*```[^\n]*$', multiLine: true), '');
    return text.trim();
  }

  /// 取「标签块」的内部文本；标签不存在返回 null。
  static String? _block(String raw, String tag) {
    final pattern = RegExp(
      '<\\s*$tag\\s*>([\\s\\S]*?)<\\s*/\\s*$tag\\s*>',
      caseSensitive: false,
    );
    final match = pattern.firstMatch(raw);
    if (match == null) return null;
    return _normalizeMultiline(match.group(1) ?? '');
  }

  /// 同 [_block]，但用于「单个值」标签（返回内容不做额外压缩）。
  static String? _tag(String raw, String tag) => _block(raw, tag);

  /// 多行文本：保留内部换行，折叠行尾空白与 3 个以上连续空行。
  static String _normalizeMultiline(String raw) {
    var text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    text = text.replaceAll(RegExp(r'[ \t]+\n'), '\n');
    text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return text.trim();
  }

  /// 单行字段：折叠内部换行（书名 / 分类 / 关键词这类只能占一行的值）。
  static String? _singleLine(String? raw) {
    if (raw == null) return null;
    return raw.replaceAll(RegExp(r'\s*\n\s*'), ' ').trim();
  }

  /// Mod 引用：ref 原文 / 存储形态 / 名称都能识别；未知项忽略并记 warning。
  static List<String> _parseModRefs(
    String block,
    List<Mod> catalog,
    List<String> warnings,
    int maxMods,
  ) {
    final byToken = <String, String>{};
    final names = <String>[];
    for (final mod in catalog) {
      final ref = mod.ref;
      byToken[ref.toLowerCase()] = ref;
      final storage = Mod.storageRefOfUiRef(ref);
      if (storage != null) byToken[storage.toLowerCase()] = ref;
      final name = mod.name.trim();
      if (name.isNotEmpty) {
        byToken[name.toLowerCase()] = ref;
        names.add(name);
      }
    }
    // 名称包含匹配时优先长名，避免「默认网文」先命中「默认网文语感强化」的短前缀。
    names.sort((a, b) => b.length.compareTo(a.length));

    final refs = <String>[];
    final matches = RegExp(
      '<\\s*mod\\s*>([\\s\\S]*?)<\\s*/\\s*mod\\s*>',
      caseSensitive: false,
    ).allMatches(block);
    for (final match in matches) {
      final token = _cleanModToken(match.group(1) ?? '');
      if (token.isEmpty) continue;
      var ref = byToken[token.toLowerCase()];
      if (ref == null) {
        for (final name in names) {
          if (token.contains(name)) {
            ref = byToken[name.toLowerCase()];
            break;
          }
        }
      }
      if (ref == null) {
        final rawRef = RegExp(
          r'preset:[A-Za-z0-9_\-]+|user:[A-Za-z0-9\-]+',
          caseSensitive: false,
        ).firstMatch(token)?.group(0);
        if (rawRef != null) ref = byToken[rawRef.toLowerCase()];
      }
      if (ref == null) {
        warnings.add('无法识别的 Mod：$token（已忽略）');
        continue;
      }
      if (!refs.contains(ref)) refs.add(ref);
    }
    if (refs.length > maxMods) {
      warnings.add('Mod 超过 $maxMods 个，只保留前 $maxMods 个');
      refs.removeRange(maxMods, refs.length);
    }
    return refs;
  }

  /// 清理模型抄回来的单条 Mod 文本（列表符号 / 反引号 / 引号 / 多余说明）。
  static String _cleanModToken(String raw) {
    final firstLine = raw.split('\n').first;
    return firstLine
        .replaceAll(RegExp(r'^[-*•\s]+'), '')
        .replaceAll(RegExp(r'[`"“”]'), '')
        .trim();
  }

  /// 解析 `<worldBook>` 内的 `<entry>` 块。
  static List<WorldBookEntry> _parseWorldBookEntries(
    String block,
    List<String> warnings,
  ) {
    final entries = <WorldBookEntry>[];
    final matches = RegExp(
      '<\\s*entry\\s*>([\\s\\S]*?)<\\s*/\\s*entry\\s*>',
      caseSensitive: false,
    ).allMatches(block);
    for (final match in matches) {
      final inner = match.group(1) ?? '';
      final keyword = _singleLine(_tag(inner, 'keyword')) ?? '';
      final content = _tag(inner, 'content') ?? '';
      if (keyword.trim().isEmpty && content.trim().isEmpty) {
        warnings.add('有一条世界书条目完全为空（已忽略）');
        continue;
      }
      entries.add(
        WorldBookEntry(
          bookUuid: '',
          keyword: keyword.trim(),
          content: content.trim(),
          isActive: true,
        ),
      );
    }
    if (entries.isEmpty) warnings.add('没有解析到世界书条目');
    return entries;
  }

  /// 解析 `<roleCategories>` 内的 `<category>` 块。
  static List<RoleCategory> _parseRoleCategoryEntries(
    String block,
    List<String> warnings,
  ) {
    final categories = <RoleCategory>[];
    final matches = RegExp(
      '<\\s*category\\s*>([\\s\\S]*?)<\\s*/\\s*category\\s*>',
      caseSensitive: false,
    ).allMatches(block);
    for (final match in matches) {
      final inner = match.group(1) ?? '';
      final name = _singleLine(_tag(inner, 'name')) ?? '';
      final format = _tag(inner, 'format') ?? '';
      if (name.trim().isEmpty && format.trim().isEmpty) {
        warnings.add('有一个角色类别完全为空（已忽略）');
        continue;
      }
      categories.add(
        RoleCategory(name: name.trim(), format: format.trim()),
      );
    }
    if (categories.isEmpty) warnings.add('没有解析到角色类别');
    return categories;
  }
}
