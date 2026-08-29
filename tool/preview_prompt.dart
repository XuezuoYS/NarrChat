// 预览实际生成的 Prompt（仅用于核对，非应用运行）。
// 运行：dart run tool/preview_prompt.dart
import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/services/prompt_builder.dart';
import 'package:narrchat/utils/constants.dart';

void main() {
  const book = Book(
    title: '示例：青云修仙录',
    category: '玄幻后宫',
    baseSetting: '北域修仙世界，宗门林立，灵气复苏。',
    writingStyle: '用户补充示例：多用短句，动作描写要凌厉。',
    globalPrePrompt: '保持悬念，不要提前揭露真相。',
    globalPostPrompt: '本轮结束时留下新的钩子。',
    historyRounds: 3,
    roleHierarchy: '主角 > 女主角 > NPC',
    roleCategories: Constants.defaultRoleCategories,
  );
  const lastRound = Round(
    bookUuid: '',
    roundIndex: 2,
    userInput: '我祭出飞剑。',
    aiNarrative: '剑光如虹，劈开云雾。',
    worldState: '- 地点：青云宗后山\n- 灵气：浓郁',
    characterState: '## 女主角\n### 苏清月\n- 心情：担忧',
    memorySummary:
        '- 第1轮｜日期：第一天 清晨｜主角初入青云宗，拜入门下。\n- 第2轮｜日期：第三天 午时｜主角在宗门大比中获胜，苏清月担忧其伤势。',
    currentTime: '第三天 午时',
  );
  final bundle = const PromptBuilder().build(
    book: book,
    lastRound: lastRound,
    userInput: '我收剑而立，看向山门方向。',
    worldBookEntries: '青云宗是北域第一大派，护山大阵每十年开启一次。',
  );
  // ignore: avoid_print
  print('==================== SYSTEM ====================');
  // ignore: avoid_print
  print(bundle.systemPrompt);
  // ignore: avoid_print
  print('\n==================== USER ====================');
  // ignore: avoid_print
  print(bundle.userPrompt);
}
