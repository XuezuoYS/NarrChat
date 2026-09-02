import 'agent_state_working_copy.dart';
import 'state_tools.dart';

/// 状态维护缺口：正文轮结束后判断「要不要发起状态轮」，以及状态轮要修什么。
///
/// 判定完全基于应用侧工作副本（谁被编辑过 / 谁被声明过无变化 / 角色块是否
/// 逐字节没动），**不依赖模型自述**——模型说「已更新」不算更新。
/// 当前时间属于**正文**（`## 当前时间` 小节由模型输出、应用解析写入），
/// 故不在此判定范围内；时间缺失时正文沿用上一轮时间（不算缺口）。
enum StateGapKind {
  /// 栏目本轮完全没被处理（既没编辑，也没 `op=noChange` 声明）。
  sectionUntouched,

  /// 栏目本轮与上一轮逐字节相同（含只声明 noChange 的情形）。
  sectionUnchanged,

  /// 本轮剧情里出现的具名角色，其 `## 角色名` 块与上一轮逐字节相同。
  lazyCharacters,
}

/// 单个缺口：同时给出面向模型的指令行 [modelText] 与面向用户的提示行 [uiText]。
class StateGap {
  const StateGap({required this.kind, this.section, this.names = const []});

  final StateGapKind kind;

  /// 缺口所属栏目（[StateGapKind.lazyCharacters] 时为 null）。
  final AgentStateSection? section;

  /// 涉及的角色名（仅 [StateGapKind.lazyCharacters]）。
  final List<String> names;

  String get sectionLabel => section?.label ?? '';

  /// 角色名展示文本（最多 6 个，避免提示过长）。
  String get namesText => names.take(6).join('、');

  /// 面向模型：英文指令在前（遵循度更高）+ 中文一行摘要。
  String get modelText => switch (kind) {
        StateGapKind.sectionUntouched =>
          'Section "${section!.tag}" was neither edited nor declared unchanged '
              'this round. Call $kEditSectionToolName for it once (op=noChange '
              '+ reason if truly nothing changed). '
              '【中】$sectionLabel栏目本轮既未编辑也未声明无变化，'
              '请对该栏目调用一次 $kEditSectionToolName（确无变化用 op=noChange + reason）。',
        StateGapKind.sectionUnchanged =>
          'Section "${section!.tag}" is byte-identical to last round although '
              'the story moved on. Edit it now with $kEditSectionToolName, '
              'anchored on lines copied from the latest snapshot. '
              '【中】$sectionLabel栏目与上一轮逐字节相同（剧情已推进），'
              '请用 $kEditSectionToolName 按最新快照原文锚点做实际编辑。',
        StateGapKind.lazyCharacters =>
          'These characters appear in this round but their blocks are '
              'byte-identical to last round: $namesText. The story moved '
              'them, so edit each block NOW: one op=set per line the story '
              'changed (当前心理 / 当前状态 / 当前位置 / 好感度 / 伤势 / 物品 / '
              '关系…), all packed into ONE $kEditSectionToolName call on '
              'characterState. op=noChange is allowed ONLY for a character the '
              'story merely mentions with no new information at all — never '
              'for all of them together, and always with a per-character '
              'reason; a noChange that dodges a visible move is a lazy edit '
              'and will be re-flagged. '
              '【中】本轮出场角色 $namesText 的角色块与上一轮逐字节相同，'
              '但正文里他们确有动向：现在必须逐个 `## 角色名` 块实际编辑——'
              '正文改动了几行，就补几条 op=set（当前心理/当前状态/当前位置/'
              '好感度/伤势/物品/关系…，全部合并到同一次 characterState 调用）。'
              '只有当某角色在正文里「只是被提及、完全没有新信息」时才允许对其声明 '
              'op=noChange 并附逐条 reason；拿 noChange 回避可见变化会被再次点名，'
              '属懒修改。',
      };

  /// 面向用户：状态轮用尽后仍存在的缺项（常驻提示）。
  String get uiText => switch (kind) {
        StateGapKind.sectionUntouched => '$sectionLabel本轮未更新',
        StateGapKind.sectionUnchanged => '$sectionLabel本轮无实际变化',
        StateGapKind.lazyCharacters => '角色未更新：$namesText',
      };
}

/// 判定本轮状态维护缺口（返回空列表 = 无需状态轮）。
///
/// [copy] 是本轮工作副本（正文轮工具已执行过的状态）；[story] 为已采纳正文
/// （懒修改判定的输入）。[checkLazy] 关闭时跳过角色块比对。
/// 当前时间不参与判定（属于正文，见类文档）。
List<StateGap> inspectState({
  required AgentStateWorkingCopy copy,
  required String story,
  bool checkLazy = true,
}) {
  final gaps = <StateGap>[];
  for (final section in AgentStateSection.values) {
    final touched = copy.touchedSections.contains(section);
    final declared = copy.declaredUnchanged.containsKey(section);
    if (!touched && !declared) {
      gaps.add(StateGap(kind: StateGapKind.sectionUntouched, section: section));
      continue;
    }
    // 做过真实编辑却整栏一字未动（set 回原值 / 删了又加回来）：视为无效编辑。
    // 显式声明 noChange 属于合法路径（角色块级别的懒修改另有检查）；
    // 记忆栏目的「本轮条目」把关在 applyEdits 内（失败会进模型反馈）。
    if (touched &&
        !declared &&
        section != AgentStateSection.memorySummary &&
        copy.sectionText(section) == copy.sectionBaseText(section)) {
      gaps.add(StateGap(kind: StateGapKind.sectionUnchanged, section: section));
    }
  }
  if (checkLazy) {
    final lazy = lazyCharacterNames(
      story: story,
      previousCharacterState: copy.baseCharacterState,
      currentCharacterState: copy.characterState,
    );
    if (lazy.isNotEmpty) {
      gaps.add(StateGap(kind: StateGapKind.lazyCharacters, names: lazy));
    }
  }
  return gaps;
}

/// 本轮出场、且角色块与上一轮逐字节相同的具名角色（懒修改点名）。
///
/// 名称需 ≥2 字（避免「他」「刀」等误命中）且在正文中原样出现；
/// 比对的是 `## 角色名` 之后的块正文（标题行本身不计）。
List<String> lazyCharacterNames({
  required String story,
  required String previousCharacterState,
  required String currentCharacterState,
}) {
  if (story.trim().isEmpty) return const [];
  final before = {
    for (final b in splitCharacterBlocks(previousCharacterState))
      b.name: b.text,
  };
  final after = {
    for (final b in splitCharacterBlocks(currentCharacterState)) b.name: b.text,
  };
  final names = <String>[];
  for (final entry in after.entries) {
    if (entry.key.trim().length < 2) continue;
    if (!story.contains(entry.key)) continue;
    if (before[entry.key] == entry.value) names.add(entry.key);
  }
  return names;
}
