import '../utils/constants.dart';
import 'book.dart';
import 'role_category.dart';
import 'world_book_entry.dart';

/// 「一句话创建新书」流程中的书籍草稿。
///
/// - 只存在于内存，不落库；落库前由 `BookCreationWriter` 转成真实数据；
/// - [modRefs] 使用界面引用（`preset:<key>` / `user:<uuid>`，与 `Mod.ref` 一致）；
/// - 世界书 / 角色类别保留 AI 的**原始产出**（可能含空字段），完整性检查用它
///   报告问题；真正写库时用 [effectiveWorldBook] / [effectiveRoleCategories]
///   过滤掉无效项（「保留此书」时缺失项按默认值兜底）。
class BookCreationDraft {
  /// 书名（AI 产出，未 trim；`toBook` 时统一处理）。
  final String title;

  /// 分类（AI 产出）。
  final String category;

  /// 基础设定（Markdown 文本）。
  final String baseSetting;

  /// 世界书条目（AI 原始产出，可能含空关键词 / 空内容）。
  final List<WorldBookEntry> worldBook;

  /// 全局前置词。
  final String globalPrePrompt;

  /// 全局后置词。
  final String globalPostPrompt;

  /// 文笔要求描述（不是「文笔参考段落」，后者不由 AI 生成）。
  final String writingRequirements;

  /// 角色类别与描述格式（AI 原始产出，可能含空名称 / 空格式 / 重名）。
  final List<RoleCategory> roleCategories;

  /// 选中的 Mod（界面引用，顺序即置入顺序）。
  final List<String> modRefs;

  const BookCreationDraft({
    this.title = '',
    this.category = '',
    this.baseSetting = '',
    this.worldBook = const [],
    this.globalPrePrompt = '',
    this.globalPostPrompt = '',
    this.writingRequirements = '',
    this.roleCategories = const [],
    this.modRefs = const [],
  });

  /// 空草稿（流程起点）。
  static const BookCreationDraft empty = BookCreationDraft();

  /// 真正可写库的世界书条目：关键词与内容都非空，按「关键词 + 内容」去重。
  ///
  /// 书籍世界书只有命中关键词才会注入，所以空关键词条目没有意义；
  /// 空内容条目不写库。原始草稿仍保留它们，供完整性检查与补充轮使用。
  List<WorldBookEntry> get effectiveWorldBook {
    final seen = <String>{};
    final result = <WorldBookEntry>[];
    for (final entry in worldBook) {
      final keyword = entry.keyword.trim();
      final content = entry.content.trim();
      if (keyword.isEmpty || content.isEmpty) continue;
      if (!seen.add('$keyword\u0000$content')) continue;
      result.add(
        entry.copyWith(
          bookUuid: '',
          keyword: keyword,
          content: content,
          isActive: true,
        ),
      );
    }
    return result;
  }

  /// 真正可写库的角色类别：名称与格式都非空、按名称去重；全无有效项时回退默认。
  List<RoleCategory> get effectiveRoleCategories {
    final seen = <String>{};
    final result = <RoleCategory>[];
    for (final category in roleCategories) {
      final name = category.name.trim();
      final format = category.format.trim();
      if (name.isEmpty || format.isEmpty) continue;
      if (!seen.add(name)) continue;
      result.add(RoleCategory(name: name, format: format));
    }
    return result.isEmpty
        ? List.of(Constants.defaultRoleCategories)
        : result;
  }

  /// 有效角色类别拼接出的层级排序字符串（与书籍设置页的保存口径一致）。
  String get roleHierarchy => Constants.joinRoleHierarchy([
        for (final category in effectiveRoleCategories) category.name,
      ]);

  /// 转成落库用的 [Book]。
  ///
  /// - [fallbackTitle] 只在标题为空时使用（「保留此书」用「未命名书籍」）；
  /// - 文笔参考段落固定为空（不由 AI 编辑）、封面为空、历史轮数 / 记忆档位用默认值；
  /// - 角色类别使用 [effectiveRoleCategories]（空 / 无效时回退默认）。
  Book toBook({String fallbackTitle = ''}) {
    final trimmedTitle = title.trim();
    return Book(
      title: trimmedTitle.isEmpty ? fallbackTitle : trimmedTitle,
      category: category.trim(),
      baseSetting: baseSetting.trim(),
      writingRequirements: writingRequirements.trim(),
      writingStyle: '',
      globalPrePrompt: globalPrePrompt.trim(),
      globalPostPrompt: globalPostPrompt.trim(),
      historyRounds: 1,
      memorySummaryRounds: 0,
      roleHierarchy: roleHierarchy,
      roleCategories: effectiveRoleCategories,
    );
  }

  BookCreationDraft copyWith({
    String? title,
    String? category,
    String? baseSetting,
    List<WorldBookEntry>? worldBook,
    String? globalPrePrompt,
    String? globalPostPrompt,
    String? writingRequirements,
    List<RoleCategory>? roleCategories,
    List<String>? modRefs,
  }) {
    return BookCreationDraft(
      title: title ?? this.title,
      category: category ?? this.category,
      baseSetting: baseSetting ?? this.baseSetting,
      worldBook: worldBook ?? this.worldBook,
      globalPrePrompt: globalPrePrompt ?? this.globalPrePrompt,
      globalPostPrompt: globalPostPrompt ?? this.globalPostPrompt,
      writingRequirements: writingRequirements ?? this.writingRequirements,
      roleCategories: roleCategories ?? this.roleCategories,
      modRefs: modRefs ?? this.modRefs,
    );
  }
}
