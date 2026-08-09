import 'mod.dart';

/// 预置 Mod 集合（内置、仅可查看，不可修改）。
///
/// 预置 Mod 以稳定字符串 [Mod.presetKey] 标识，书籍通过 `book_mods` 表的
/// `preset_key` 列引用；预置内容随应用版本更新，不存入数据库。
class PresetMods {
  PresetMods._();

  static const List<Mod> all = [
    Mod(
      presetKey: 'web_novel_style',
      name: '网文语感强化',
      description: '强化中文网文的语感与节奏，抑制“AI 腔”，让正文更贴近网文读者的阅读习惯。',
      prePrompt: '以中文网文作者的语感与节奏推进剧情：场景转换干脆、段落短促有力、对话贴合人物身份；避免书面语腔调与模板化表达。',
      postPrompt: '收尾时自然衔接下一场景，制造期待感；不要在段落结尾强行升华或说教。',
      systemPrompt: '网文语感要求：正文必须读起来像一名熟练的中文网文作者所写——多用短句与动作细节推进，少用空泛形容词；每段聚焦一个画面；对话口语化且贴合人物性格；禁止“AI 腔”套话。',
    ),
    Mod(
      presetKey: 'character_immersion',
      name: '角色沉浸扮演',
      description: '让 AI 深度代入角色，保持视角一致、情感与人物设定连贯。',
      prePrompt: '本轮请以主要角色的视角沉浸式演绎：动作、心理、对话都从角色出发，保持人物设定与上一轮状态一致。',
      postPrompt: '在 ## 角色状态 中如实反映本轮角色情绪与关系的变化。',
      systemPrompt: '沉浸扮演要求：始终从当前剧情中登场角色的视角展开描写，心理活动、动作与对话必须符合各自的人物设定与立场；角色之间的互动要体现关系与性格差异，不得让所有角色同一腔调。',
    ),
    Mod(
      presetKey: 'plot_pacing',
      name: '剧情节奏控制',
      description: '控制剧情推进节奏，避免拖沓或跳跃，重要事件充分展开。',
      prePrompt: '把握本轮剧情节奏：重要事件与冲突要展开充分，日常过渡适当精简；信息量要匹配单轮篇幅，不要草草带过关键情节。',
      postPrompt: '在推进剧情的同时为本轮埋下合理的后续伏笔或悬念。',
      systemPrompt: '节奏控制要求：根据剧情的轻重缓急分配笔墨——高潮与转折场景用足篇幅刻画，日常与过渡一笔带过；每轮都要让剧情有实质推进，同时为后续发展保留空间。',
    ),
    Mod(
      presetKey: 'world_detail',
      name: '世界细节补全',
      description: '补充环境与世界观细节，让场景描写更具体、更有画面感。',
      prePrompt: '在剧情中自然地补全环境细节：场景的光线、声音、气味与物件等，通过具体描写增强画面感，但不要打断叙事节奏。',
      systemPrompt: '世界细节要求：在 ## 剧情演绎 中适当补充环境与世界观细节（地理、气候、人文、物品等），让读者能“看见”场景；细节必须与书籍设定一致，不得相互矛盾。',
      worldBookEntries: [
        ModWorldBookEntry(
          keyword: '宗门, 山门, 门派, 道场',
          content: '宗门类场景需补充：山门建筑风格与气势、护山阵法或灵脉、弟子日常活动与门派氛围；细节需与本书设定一致。',
        ),
        ModWorldBookEntry(
          keyword: '城池, 城镇, 皇城, 坊市',
          content: '城池类场景需补充：城墙城门、街市布局与商贩人文、往来行人的身份与装束，让场景有烟火气。',
        ),
        ModWorldBookEntry(
          keyword: '战斗, 斗法, 交手, 对战',
          content: '战斗场景需补充：交手双方的身位与距离、招式与法器/兵器的具体效果、环境对战斗的影响（地形、天气）。',
        ),
        ModWorldBookEntry(
          content: '场景描写基准：默认场景需交代环境氛围、天气/光线与主要物件；所写细节不得与书籍基础设定冲突。',
        ),
      ],
    ),
  ];

  /// 按 key 查找预置 Mod；未找到返回 null。
  static Mod? byKey(String? key) {
    if (key == null || key.isEmpty) return null;
    for (final mod in all) {
      if (mod.presetKey == key) return mod;
    }
    return null;
  }
}
