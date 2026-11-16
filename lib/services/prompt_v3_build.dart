/// **v3 system 拼合**：模块顺序、空模块删除、`{system_must-}` 逆序、空行 join。
///
/// 职责边界：
/// - 本文件只管**顺序与拼接**，文案一律来自 `prompt_v3_sections.dart`；
/// - 模块顺序只在这里有一份（`systemSections()` 是唯一排法），文案层不许自己排；
/// - 空模块在 `systemSections()` 就丢掉，`system()` 不再做第二轮过滤，避免两处
///   判断不一致；
/// - **`must-` 是算出来的**：把 must 的块序列（段1 + 各 Mod 段）整体反转，块内
///   文案原样、不加标题，文案层没有它的手写稿；
/// - 纯 Dart 依赖：可被 `tool/preview_prompt.dart` 一类脚本直接引用。
library;

import 'prompt_text.dart';
import 'prompt_v3_sections.dart';

/// v3 **system** 取用实现：8 个模块的有序拼合 + 逆序复现。
///
/// 上下文（`user()` / `stage*()`）在 `prompt_v3_context.dart`，工具清单在
/// `prompt_v3_tools.dart`；三者由 `PromptV3`（`prompt_interface.dart`）聚合成
/// 唯一入口。
class PromptV3Build implements SystemPromptSource, SystemSectionSource {
  const PromptV3Build();

  @override
  List<PromptSection> systemSections(PromptRequest request) {
    final book = request.book;
    final mods = request.mods;
    // must 的块序列先算出来：正文用正序、末尾用逆序，块内文案完全一致。
    final mustBlocks = PromptV3Sections.mustBlocks(mods);
    final sections = <PromptSection>[
      PromptSection(name: 'must', text: mustBlocks.join('\n\n')),
      PromptSection(
        name: 'accord',
        text: PromptV3Sections.accord(request.mode, book.memorySummaryRounds),
      ),
      PromptSection(name: 'extra', text: PromptV3Sections.extra(mods)),
      PromptSection(name: 'about', text: PromptV3Sections.about(book)),
      PromptSection(
        name: 'setting',
        text: PromptV3Sections.setting(
          book: book,
          worldBookEntries: request.worldBookEntries,
          mods: mods,
        ),
      ),
      PromptSection(
        name: 'writingStyle',
        text: PromptV3Sections.writingStyle(book: book, mods: mods),
      ),
      PromptSection(
        name: 'accordEnding',
        text: PromptV3Sections.accordEnding(request.toolNames),
      ),
      // 全部块反转：末尾最先读到的是最后一个 Mod 段，段1 最后（硬指令前置优先）。
      PromptSection(
        name: 'mustReverse',
        text: mustBlocks.reversed.join('\n\n'),
      ),
    ];
    // 「空块删除只认去空白后为空」：绝不产出「（无）」「未设置」占位。
    return [
      for (final section in sections)
        if (section.text.trim().isNotEmpty) section,
    ];
  }

  @override
  String system(PromptRequest request) => systemSections(
    request,
  ).map((section) => section.text).join('\n\n');
}
