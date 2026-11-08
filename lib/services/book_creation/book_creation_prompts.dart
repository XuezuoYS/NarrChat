import '../../models/book_creation_draft.dart';
import '../../models/mod.dart';

/// 一句话创建新书各阶段的提示词（纯拼接，不依赖 Flutter）。
///
/// 与叙事提示词（`prompt_interface`）完全独立：这里只负责「按步骤生成一本书
/// 的设定」，不引入正文区块契约，避免两套语义互相污染。
class BookCreationPrompts {
  const BookCreationPrompts();

  /// 所有阶段共用的系统提示词。
  static const String system = '''
你是一名资深的中文网文策划与世界观设计师，正在帮助用户从一个简短创意搭建一本用于 AI 角色扮演与小说创作的书。
你的工作会分几个步骤进行，用户每次只要求你完成其中一步。

硬性要求：
- 只输出当前步骤要求的内容，严格使用给定的标签；不要寒暄、解释、复述要求、输出步骤标题或额外总结。
- 所有内容使用简体中文；书名与分类保持简短。
- 文本字段内部可以使用 Markdown 的列表、加粗、引用等，但禁止使用 # 或 ## 标题（会与正文区块冲突）。
- 内容必须具体、自洽、能直接用于后续创作；与用户创意和已给出的内容保持一致，不要自相矛盾。
- 不要提到 AI、模型、用户或"根据要求"之类的话。
- 不要复制所选 Mod 已经负责的内容（例如 Mod 已经规定了文笔风格，就不要再写一遍）。
''';

  /// 阶段 1：标题与类别。
  String titleCategory({required String idea}) {
    return '''
【用户创意】
$idea

【本步骤任务】
为这本书起一个书名，并给出一个分类。
- 书名要具体、有辨识度，能体现创意的核心，不要写成一句话梗概。
- 分类用一个短语概括题材（例如：都市奇幻、仙侠、悬疑、科幻末日）。
- 不要写简介、人物、剧情。

【输出格式】
<title>书名</title>
<category>分类</category>

【硬性要求】
- 只输出上面两个标签，不要输出其它内容。
- 每个标签内的内容占一行，不要换行。
''';
  }

  /// 阶段 2：从可用 Mod 中选择。
  String mods({
    required String idea,
    required BookCreationDraft draft,
    required List<Mod> availableMods,
  }) {
    return '''
【用户创意】
$idea

【已确定内容】
${_contextBlock(draft)}

【可选的 Mod】
${modCatalog(availableMods)}

【本步骤任务】
根据创意与已有标题 / 分类，从上面的可用 Mod 中挑选真正有帮助的 Mod（0~8 个）。
- 宁缺毋滥：与本书题材无关、或会明显破坏本书设定的 Mod 不要选。
- 只能填写列表中给出的 ref 原文（以 `preset:` 或 `user:` 开头），不要编造。
- 没有合适的 Mod 就输出空的 `<mods>` 块。

【输出格式】
<mods>
<mod>ref</mod>
</mods>

没有选中任何 Mod 时输出：
<mods></mods>
''';
  }

  /// 阶段 3：基础设定 + 世界书。
  String baseSettingWorldBook({
    required String idea,
    required BookCreationDraft draft,
    required List<Mod> selectedMods,
  }) {
    return '''
【用户创意】
$idea

【已确定内容】
${_contextBlock(draft, selectedMods: selectedMods)}

【本步骤任务】
1. 写「基础设定」：世界观、时代、地点、核心规则、主要势力、开局局势等不会随剧情改变的内容。用 Markdown 列表 / 加粗组织，要具体、能直接用于创作。
2. 写「世界书」条目：2~6 条。每条包含触发关键词与命中后注入的内容。
   - 关键词用逗号或顿号分隔，不能为空（书籍世界书只有命中关键词才会注入）；
   - 关键词要覆盖本书最常出现的地点、组织、人物、物品或核心设定；
   - 条目内容短小具体，不要写成大段设定。

【输出格式】
<baseSetting>
基础设定内容
</baseSetting>
<worldBook>
<entry>
<keyword>关键词1, 关键词2</keyword>
<content>命中后注入的内容</content>
</entry>
</worldBook>

【硬性要求】
- 禁止使用 # / ## 标题；用列表与加粗组织内容。
- 世界书每条都要有关键词与内容，不能留空。
- 不要与所选 Mod 已有的要求重复。
''';
  }

  /// 阶段 4：前置词、后置词、文笔要求。
  String prePostWriting({
    required String idea,
    required BookCreationDraft draft,
    required List<Mod> selectedMods,
  }) {
    return '''
【用户创意】
$idea

【已确定内容】
${_contextBlock(draft, selectedMods: selectedMods, includeWorldBookSummary: true)}

【本步骤任务】
写三块可以直接注入提示词的要求：
1. 前置词：在用户输入之前追加的创作要求——要做什么、必须遵循哪些设定与规则。
2. 后置词：在用户输入之后追加的约束——不要做什么、如何收尾、哪些内容禁止出现。
3. 文笔描述要求：对文风、句式、节奏、描写重点的要求。只写要求，不要写范文。
以上三块都要与本书题材、基础设定、已选 Mod 自洽，不要复制 Mod 内容。

【输出格式】
<prePrompt>前置词内容</prePrompt>
<postPrompt>后置词内容</postPrompt>
<writingRequirements>文笔要求内容</writingRequirements>

【硬性要求】
- 禁止使用 # / ## 标题；每块 1~2 段，简洁、可执行。
- 三块都不能为空。
''';
  }

  /// 阶段 5：角色类别与描述格式。
  String roleCategories({
    required String idea,
    required BookCreationDraft draft,
    required List<Mod> selectedMods,
  }) {
    return '''
【用户创意】
$idea

【已确定内容】
${_contextBlock(draft, selectedMods: selectedMods)}

【本步骤任务】
设计这本书的「角色类别」与每类的「描述格式」。
- 角色类别按重要性排序（例如：主角、女主角、NPC），2~6 个，名称不重复。
- 描述格式是 AI 写「角色状态」时使用的属性行模板，用 `- 属性：` 的形式，占位内容留空。
- 格式要适合本书题材（例如都市异能可以加入「能力」「所属组织」，仙侠可以加入「境界」「宗门」）。

【输出格式】
<roleCategories>
<category>
<name>主角</name>
<format>- 姓名：
- 当前状态：</format>
</category>
</roleCategories>

【硬性要求】
- 禁止使用 # / ## 标题。
- 每个类别的名称与格式都不能为空。
''';
  }

  /// 补充轮：只要求模型补 / 修缺失项。
  String supplement({
    required String idea,
    required BookCreationDraft draft,
    required List<Mod> selectedMods,
    required List<String> problems,
    required int attempt,
    required int maxAttempts,
  }) {
    final problemLines = problems.map((problem) => '- $problem').join('\n');
    return '''
【用户创意】
$idea

【当前已生成内容】
${_contextBlock(
      draft,
      selectedMods: selectedMods,
      includeWorldBook: true,
      includePrompts: true,
      includeRoleCategories: true,
    )}

【需要补充或修正的地方（第 $attempt/$maxAttempts 次补充）】
$problemLines

【本步骤任务】
只针对上面的问题补充或修正：
- 只输出需要补充 / 修正的标签；已经合格的内容不要重发。
- 如果某项无法补全，就不要输出对应标签（不要编造、不要输出空标签）。
- 如果问题是世界书或角色类别，请重新输出完整的 `<worldBook>` / `<roleCategories>` 块（整体替换旧内容）。
- 补充内容必须与已有内容自洽，不要推翻已合格的部分。

【可用的标签】
<title>…</title>、<category>…</category>、<mods>…</mods>、<baseSetting>…</baseSetting>、
<worldBook>…</worldBook>、<prePrompt>…</prePrompt>、<postPrompt>…</postPrompt>、
<writingRequirements>…</writingRequirements>、<roleCategories>…</roleCategories>

【硬性要求】
- 禁止使用 # / ## 标题。
''';
  }

  // ---------------------------------------------------------------------------
  // 拼接工具
  // ---------------------------------------------------------------------------

  /// 兼容旧调用名（历史设计文档里写作 `modCatalog`）。
  static String modCatalog(
    List<Mod> mods, {
    int maxMods = 40,
    int previewChars = 120,
  }) {
    if (mods.isEmpty) return '（当前没有任何可用 Mod，请输出 <mods></mods>）';
    final buf = StringBuffer();
    for (final mod in mods.take(maxMods)) {
      final areas = <String>[];
      if (mod.prePrompt.trim().isNotEmpty) areas.add('前置词');
      if (mod.postPrompt.trim().isNotEmpty) areas.add('后置词');
      if (mod.systemPrompt.trim().isNotEmpty) areas.add('系统提示词');
      if (mod.worldBookEntries.isNotEmpty) {
        areas.add('世界书 ${mod.worldBookEntries.length} 条');
      }

      final previewSource = [
        mod.prePrompt,
        mod.postPrompt,
        mod.systemPrompt,
        for (final entry in mod.worldBookEntries) entry.content,
      ]
          .where((text) => text.trim().isNotEmpty)
          .join('\n')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      final preview = previewSource.length > previewChars
          ? '${previewSource.substring(0, previewChars)}…'
          : previewSource;

      buf.writeln('- ref：${mod.ref} ｜ 名称：${mod.name.trim()}');
      final description = mod.description.trim();
      if (description.isNotEmpty) buf.writeln('  简介：$description');
      if (areas.isNotEmpty) buf.writeln('  作用区域：${areas.join('、')}');
      if (preview.isNotEmpty) buf.writeln('  内容预览：$preview');
    }
    if (mods.length > maxMods) {
      buf.writeln('\n（还有 ${mods.length - maxMods} 个 Mod 未列出，请勿选择未列出的 Mod）');
    }
    return buf.toString().trim();
  }

  /// 把草稿转成模型可读的上下文块（补充轮可要求更完整的内容）。
  static String _contextBlock(
    BookCreationDraft draft, {
    List<Mod> selectedMods = const [],
    bool includeWorldBookSummary = false,
    bool includeWorldBook = false,
    bool includePrompts = false,
    bool includeRoleCategories = false,
  }) {
    final lines = <String>[];
    final title = draft.title.trim();
    final category = draft.category.trim();
    if (title.isNotEmpty) lines.add('标题：$title');
    if (category.isNotEmpty) lines.add('分类：$category');
    if (selectedMods.isNotEmpty) {
      final modLines = [
        for (final mod in selectedMods)
          '- ${mod.name.trim()}：${mod.description.trim()}',
      ];
      lines.add('已选 Mod：\n${modLines.join('\n')}');
    }

    final baseSetting = draft.baseSetting.trim();
    if (baseSetting.isNotEmpty) lines.add('基础设定：\n$baseSetting');

    final worldBook = draft.effectiveWorldBook;
    if (includeWorldBook && worldBook.isNotEmpty) {
      final entries = [
        for (final entry in worldBook)
          '- 关键词：${entry.keyword}\n  内容：${entry.content}',
      ];
      lines.add('世界书：\n${entries.join('\n')}');
    } else if (includeWorldBookSummary && worldBook.isNotEmpty) {
      final keywords = [
        for (final entry in worldBook)
          if (entry.keyword.trim().isNotEmpty) entry.keyword,
      ];
      if (keywords.isNotEmpty) {
        lines.add('世界书关键词：${keywords.join('；')}');
      }
    }

    if (includePrompts) {
      if (draft.globalPrePrompt.trim().isNotEmpty) {
        lines.add('前置词：\n${draft.globalPrePrompt.trim()}');
      }
      if (draft.globalPostPrompt.trim().isNotEmpty) {
        lines.add('后置词：\n${draft.globalPostPrompt.trim()}');
      }
      if (draft.writingRequirements.trim().isNotEmpty) {
        lines.add('文笔要求：\n${draft.writingRequirements.trim()}');
      }
    }

    if (includeRoleCategories && draft.effectiveRoleCategories.isNotEmpty) {
      final categories = [
        for (final category in draft.effectiveRoleCategories)
          '- ${category.name}：\n${category.format}',
      ];
      lines.add('角色类别：\n${categories.join('\n')}');
    }

    return lines.isEmpty ? '（暂无）' : lines.join('\n\n');
  }
}
