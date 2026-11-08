import 'fakes.dart';

/// 一句话创建流程的测试脚本数据（runner 与页面测试共用，避免复制）。
const String kBookCreationIdea = '一个现代都市里隐藏的妖灵事务所';
const String kBookCreationTitle = '妖灵事务所';
const String kBookCreationCategory = '都市奇幻';

const String kBookTitleScript =
    '<title>$kBookCreationTitle</title>\n<category>$kBookCreationCategory</category>';

const String kBookModsScript =
    '<mods><mod>preset:web_novel_style</mod></mods>';

const String kBookBaseScript = '''
<baseSetting>
- 世界：现代都市
- 妖灵不可被普通人看见
</baseSetting>
<worldBook>
<entry>
<keyword>事务所, 委托</keyword>
<content>旧城区的妖灵事务所，只接待妖怪委托。</content>
</entry>
</worldBook>
''';

const String kBookPromptsScript = '''
<prePrompt>遵守设定，不要 OOC。</prePrompt>
<postPrompt>不要写现代网络流行语。</postPrompt>
<writingRequirements>多用短句，少用排比。</writingRequirements>
''';

/// 缺少文笔要求（用于「不完整 -> 补充轮」用例）。
const String kBookIncompletePromptsScript = '''
<prePrompt>遵守设定，不要 OOC。</prePrompt>
<postPrompt>不要写现代网络流行语。</postPrompt>
''';

const String kBookRolesScript = '''
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
''';

/// 完整内容的 5 段脚本（每次 10 输入 / 20 输出 / 5 缓存命中）。
List<ScriptedAiResponse> completeBookCreationResponses() => const [
      ScriptedAiResponse(kBookTitleScript, cachedTokensIn: 5),
      ScriptedAiResponse(kBookModsScript, cachedTokensIn: 5),
      ScriptedAiResponse(kBookBaseScript, cachedTokensIn: 5),
      ScriptedAiResponse(kBookPromptsScript, cachedTokensIn: 5),
      ScriptedAiResponse(kBookRolesScript, cachedTokensIn: 5),
    ];

/// 缺少书名与文笔要求的两处不完整内容（用于「补充轮仍不完整」用例）。
List<ScriptedAiResponse> incompleteBookCreationResponses() => const [
      ScriptedAiResponse(
        '<category>$kBookCreationCategory</category>',
      ),
      ScriptedAiResponse(kBookModsScript),
      ScriptedAiResponse(kBookBaseScript),
      ScriptedAiResponse(kBookIncompletePromptsScript),
      ScriptedAiResponse(kBookRolesScript),
      ScriptedAiResponse(''),
      ScriptedAiResponse(''),
    ];
