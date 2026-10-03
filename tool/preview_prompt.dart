// 预览实际生成的 Prompt（仅用于核对，非应用运行）。
// 运行：dart run tool/preview_prompt.dart
//
// 只用**纯 Dart** 的文本层（`prompt_v2_build.dart` + `prompt_text.dart`），
// 因此可以在 Flutter 之外运行；这里打印的就是 v2 真实发送的 system / user 文本。
// 工具清单与阶段帧指令需要应用上下文，请在应用内用「预览请求体」查看。
import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/services/prompt_formats.dart';
import 'package:narrchat/services/prompt_text.dart';
import 'package:narrchat/services/prompt_v2_build.dart';
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
        '- 1 | 第一天 清晨 | 主角初入青云宗，拜入门下。\n'
        '- 2 | 第三天 午时 | 主角在宗门大比中获胜，苏清月担忧其伤势。',
    currentTime: '第三天 午时',
  );
  // 模式可改：chat / agentLv1 / agentLv2（Agent 档位的阶段帧指令在应用内查看）。
  const mode = PromptMode.chat;
  const builder = PromptV2Build();
  final request = PromptRequest(
    book: book,
    mode: mode,
    lastRound: lastRound,
    userInput: '我收剑而立，看向山门方向。',
    worldBookEntries: '青云宗是北域第一大派，护山大阵每十年开启一次。',
  );
  // ignore: avoid_print
  print('==================== SYSTEM ====================');
  // ignore: avoid_print
  print(builder.system(request));
  // ignore: avoid_print
  print('\n==================== USER ====================');
  // ignore: avoid_print
  print(builder.user(request));
}
