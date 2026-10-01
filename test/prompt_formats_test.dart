import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/models/book.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/services/memory_merge_planner.dart';
import 'package:narrchat/services/prompt_formats.dart';
import 'package:narrchat/services/prompt_sections.dart';
import 'package:narrchat/utils/memory_entry_format.dart';

/// 模式格式生成要求（ChatPromptFormat / AgentLv1PromptFormat /
/// AgentLv2PromptFormat / PromptMode）与共享组装（PromptSections）单元测试。
///
/// 验证点：
/// - 各格式规格集中持有模式特有文案（槽位内容、契约常量）；
/// - 空槽位不注入任何内容，非空槽位按固定位置插入共享骨架；
/// - 共享输出契约（`[Markdown 兼容]` / 【推荐行动格式】）与槽位无关，
///   对三个模式逐字一致；
/// - 组装结果只含对应模式的格式段（互斥断言）。
class _StubFormat implements PromptFormatSpec {
  const _StubFormat({
    this.head = const [],
    this.afterIdentity = const [],
    this.tail = const [],
    this.userHeadLines = const [],
    this.execute = const [],
    this.userMerge = const [],
  });

  /// 各槽位可配置的测试内容（marker 便于定位插入位置）。
  final List<String> head;
  final List<String> afterIdentity;
  final List<String> tail;
  final List<String> userHeadLines;
  final List<String> execute;
  final List<String> userMerge;

  @override
  String get modeLabel => 'Stub';

  @override
  List<String> get systemHead => head;

  @override
  List<String> get systemAfterIdentity => afterIdentity;

  @override
  List<String> get systemTail => tail;

  @override
  List<String> get userHead => userHeadLines;

  @override
  List<String> get userExecuteNote => execute;

  @override
  List<String> memoryMergeUserNote(MemoryMergePlan? plan) => userMerge;
}

void main() {
  group('PromptMode', () {
    test('chat / agentLv1 / agentLv2 解析到各自格式规格（单一真源）', () {
      expect(PromptMode.chat.format, same(const ChatPromptFormat()));
      expect(PromptMode.agentLv1.format, same(const AgentLv1PromptFormat()));
      expect(PromptMode.agentLv2.format, same(const AgentLv2PromptFormat()));
    });
  });

  group('ChatPromptFormat', () {
    const format = ChatPromptFormat();

    test('sectionOrder 为 6 区块固定顺序；includeMemory=false 时排除记忆总结', () {
      expect(ChatPromptFormat.sectionOrder, [
        '剧情演绎',
        '推荐行动',
        '当前时间',
        '世界状态',
        '角色状态',
        '记忆总结',
      ]);
      expect(format.sections, ChatPromptFormat.sectionOrder);
      expect(
        const ChatPromptFormat(includeMemory: false).sections,
        ['剧情演绎', '推荐行动', '当前时间', '世界状态', '角色状态'],
      );
    });

    test('systemHead 集中 6 区块纪律（模式标记 + 项目符号清单 + 纪律 + 快照规则）', () {
      final lines = format.systemHead;
      // 首行模式标记（Agent 档位不写等级）。
      expect(lines.first, '当前模式：Chat');
      expect(format.modeLabel, 'Chat');
      expect(lines[2], '【绝对服从】以下规则必须无条件、无例外地严格执行，'
          '不得拒绝、不得询问、不得省略：');
      // 分条一律 `- ` 项目符号（不用数字序号：渲染会重编号）。
      expect(lines[4], contains('完整输出以下 6 个二级标题'));
      expect(lines[4], startsWith('- '));
      for (final section in ChatPromptFormat.sectionOrder) {
        expect(lines, contains('  - `## $section`'));
      }
      final bulletLines = lines.where((l) => l.startsWith('- ')).toList();
      expect(bulletLines, hasLength(3), reason: '清单 + 纪律 + 快照规则三条');
      expect(bulletLines.any((l) => l.contains('【二级标题纪律】')), isTrue);
      expect(bulletLines.any((l) => l.contains('上述 6 个二级标题')), isTrue);
      expect(bulletLines.any((l) => l.contains('【状态快照规则】')), isTrue);
      // 提示词文案不使用 #/## 作为结构标记（唯一例外：契约区块名与围栏示例）。
      expect(
        lines.where((l) => RegExp(r'^\s*#{1,6}\s').hasMatch(l)),
        isEmpty,
        reason: '文案里不得出现行首标题语法',
      );
      // 不含 AGENT 契约。
      expect(
        lines.any((l) => l.contains('【AGENT 模式契约】')),
        isFalse,
        reason: 'Chat 格式不得包含 AGENT 契约',
      );
    });

    test('systemAfterIdentity 为角色状态输出格式（围栏契约 + 结构说明 + 占位符形态示例）', () {
      final lines = format.systemAfterIdentity;
      expect(lines.first, contains('【角色状态输出格式】'));
      expect(lines.first, contains('```markdown 围栏'));
      expect(lines[2], contains('每个角色类别使用一级标题'));
      // 形态示例以真实围栏给出（模型照此形状输出），且**全部是占位符**：
      // 示例只表达形状，不写具体案例（否则会被模型当成设定照抄）。
      final example = lines.indexOf('```markdown');
      expect(example, greaterThan(0));
      expect(lines.sublist(example).take(5), [
        '```markdown',
        '# {类别名}',
        '## {角色名}',
        '- {属性名}：{属性值}',
        '```',
      ]);
      expect(lines.last, '');
    });

    test('systemTail 为记忆总结格式（项目符号规则），末行为空行', () {
      final lines = format.systemTail;
      expect(lines.first, contains('【记忆总结格式】'));
      expect(lines[1], '');
      final rules = lines[2];
      expect(rules, contains('- 每条记忆独占一行'));
      expect(rules, contains(kMemoryEntryFormat));
      expect(rules, contains('不得使用真实日期'));
      expect(rules, contains('为已确认的历史记忆'));
      // 与旧写法冲突时以新格式为准（一行简单提示，真源 = 常量）。
      expect(rules, contains(kMemoryEntryFormatPrecedence));
      expect(rules, isNot(contains('1. 每条记忆独占一行')));
      expect(lines.last, '');
    });

    test('userHead 含【格式要求】与记忆格式提醒（项目符号无编号）', () {
      final lines = format.userHead;
      expect(lines[0], contains('【格式要求】'));
      expect(
        lines[0],
        contains('`## 剧情演绎` → `## 推荐行动` → `## 当前时间` → '
            '`## 世界状态` → `## 角色状态` → `## 记忆总结`'),
      );
      expect(lines[1], '');
      expect(lines[2], contains('【记忆总结格式】'));
      // 模板同样只用占位符（`{轮次}` / `{时间}` / `{记忆内容}`）。
      expect(lines[2], contains(kMemoryEntryFormat));
    });

    test('userExecuteNote 为单行【指令执行】（含模式标记）', () {
      final lines = format.userExecuteNote;
      expect(lines, hasLength(1));
      expect(lines.single, contains('【指令执行】[Chat 模式]'));
      expect(lines.single, contains('完整输出 6 个二级标题区块'));
      expect(lines.single, contains('立即从 `## 剧情演绎` 开始输出。'));
    });
  });

  group('AgentLv1PromptFormat（5 区块 + 历史工具契约）', () {
    const format = AgentLv1PromptFormat();

    test('契约常量：5 个输出标题（无记忆总结）+ 历史一读一写', () {
      expect(AgentLv1PromptFormat.outputSections, [
        '剧情演绎',
        '推荐行动',
        '当前时间',
        '世界状态',
        '角色状态',
      ]);
      expect(AgentLv1PromptFormat.outputSections,
          isNot(contains('记忆总结')));
      expect(AgentLv1PromptFormat.stateToolNames, [
        'narrchat_readHistory',
        'narrchat_editHistory',
      ]);
      // 记忆阶段的单行编辑行（执行器修复指令复用本行）。
      expect(AgentLv1PromptFormat.memoryEditLine,
          contains('narrchat_editHistory'));
      expect(AgentLv1PromptFormat.memoryEditLine, contains('op=append'));
      expect(AgentLv1PromptFormat.memoryEditLine,
          contains(kMemoryEntryFormat));
    });

    test('systemHead 复用 Chat 骨架但只列 5 个区块（排除记忆总结）+ 思考语言规则', () {
      final lines = format.systemHead;
      expect(lines.first, '当前模式：Agent', reason: 'Agent 档位不写等级');
      expect(format.modeLabel, 'Agent');
      expect(lines[2], contains('【绝对服从】'));
      expect(lines[4], contains('完整输出以下 5 个二级标题'));
      expect(lines, contains('  - `## 世界状态`'));
      expect(lines, contains('  - `## 角色状态`'));
      expect(lines, isNot(contains('  - `## 记忆总结`')));
      expect(lines.any((l) => l.contains('上述 5 个二级标题')), isTrue);
      // 状态快照规则仍在（世界/角色由正文携带），但不再有记忆格式段。
      expect(lines.any((l) => l.contains('【状态快照规则】')), isTrue);
      // 思考语言规则（Agent 档位专属，`- ` 分条、无序号）。
      expect(lines, contains('- 【思考语言】思考（reasoning）一律用**英文**书写。'
          '本规则只约束思考通道：正文与工具参数保持原有语言（中文），'
          '**不要**翻译正文或锚点。'));
      expect(lines.any((l) => l.contains('- [Reasoning language]')), isTrue);
      // 文案不使用数字序号（有序列表渲染会重编号）。
      expect(lines.any((l) => RegExp(r'^\d+\. ').hasMatch(l)), isFalse);
    });

    test('systemTail 为四步契约（准备读史+大纲 → 记忆先写 → 正文 → 禁止记忆区块）', () {
      final lines = format.systemTail;
      final text = lines.join('\n');
      expect(lines.first, startsWith('- '));
      expect(lines.first, contains('narrchat_readHistory'));
      expect(lines.first, contains('ONCE'));
      expect(text, contains('【第一步·准备】'));
      expect(text, contains('【第二步·记忆先写】'));
      expect(text, contains('【第三步·正文】'));
      expect(text, contains('【第四步·禁止输出记忆区块】'));
      // 顺序 = 四步顺序：读史 → 大纲 → 记忆条目 → 正文。
      expect(
        text.indexOf('本轮大纲'),
        greaterThan(text.indexOf('narrchat_readHistory')),
      );
      expect(
        text.indexOf('恰好一条'),
        greaterThan(text.indexOf('本轮大纲')),
      );
      expect(
        text.indexOf('## 剧情演绎'),
        greaterThan(text.indexOf('恰好一条')),
      );
      // 每轮义务仍在：恰好一条（op=append）、不接受 noChange、缺/重即失败。
      expect(text, contains('narrchat_editHistory'));
      expect(text, contains('op=append'));
      expect(text, contains(kMemoryEntryFormat));
      // 与旧写法冲突时以新格式为准（同一提示行也在契约里）。
      expect(text, contains(kMemoryEntryFormatPrecedence));
      expect(text, contains('不接受'));
      expect(lines.any((l) => l.contains('禁止')), isTrue);
      // 记忆格式（Chat 的规则）不在这里——历史由工具维护。
      expect(text, isNot(contains('【记忆总结格式】')));
      // 文案不使用数字序号（有序列表渲染会重编号）。
      expect(lines.any((l) => RegExp(r'^\d+\. ').hasMatch(l)), isFalse);
      expect(lines.last, '');
    });

    test('阶段指令：prepareNote / memoryNote / storyNote 覆盖四步契约', () {
      final prepare = format.prepareNote();
      final memory = format.memoryNote();
      final story = format.storyNote();
      // 三段指令都非空，且都点明历史编辑器（准备段 = 本步不要调用它）。
      for (final note in [prepare, memory, story]) {
        expect(note, isNotEmpty);
        expect(note.join('\n'), contains('narrchat_editHistory'));
        // 文案不使用数字序号（有序列表渲染会重编号）。
        expect(note.any((l) => RegExp(r'^\d+\. ').hasMatch(l)), isFalse);
      }
      // 准备段：读史**一次** + 本轮大纲（含本轮结束时间）+ 本步不写正文。
      final prepareText = prepare.join('\n');
      expect(prepareText, contains('narrchat_readHistory'));
      expect(prepareText, contains('ONCE'));
      expect(prepareText, contains('**一次**'));
      expect(prepareText, contains('本轮大纲'));
      expect(prepareText, contains('结束'));
      // 记忆段：复用单行编辑行（恰好一条 + 记忆条目模板）。
      final memoryText = memory.join('\n');
      expect(memoryText, contains(AgentLv1PromptFormat.memoryEditLine));
      expect(memoryText, contains(kMemoryEntryFormat));
      expect(memoryText, contains('恰好一条'));
      // 正文段：5 个区块齐全、禁止记忆区块。
      final storyText = story.join('\n');
      for (final section in AgentLv1PromptFormat.outputSections) {
        expect(storyText, contains('`## $section`'), reason: '缺少区块：$section');
      }
      expect(storyText, contains('剧情演绎'));
      expect(storyText, contains('角色状态'));
      expect(storyText, contains('禁止'));
      // 明确点名被禁止的记忆区块（只以工具结果形式出现）。
      expect(storyText, contains('`## 记忆总结`'));
    });

    test('userHead 只声明 5 区块，无记忆格式提醒', () {
      final lines = format.userHead;
      expect(lines, hasLength(1));
      expect(lines.single, contains('【格式要求】'));
      expect(lines.single,
          contains('`## 剧情演绎` → `## 推荐行动` → `## 当前时间` → '
              '`## 世界状态` → `## 角色状态`'));
      expect(lines.single, isNot(contains('记忆总结')));
      expect(lines.single, contains('5 个二级标题（##）区块'));
    });

    test('userExecuteNote 双语：读史+大纲 → 先写记忆条目 → 再输出 5 区块', () {
      final lines = format.userExecuteNote;
      expect(lines, hasLength(3));
      expect(lines[0], contains('[Execute now]'));
      expect(lines[0], contains('narrchat_readHistory'));
      expect(lines[0], contains('ONCE'));
      expect(lines[0], contains('outline'));
      expect(lines[0], contains('narrchat_editHistory'));
      expect(lines[0], contains('op=append'));
      expect(lines[0], contains('five'));
      expect(lines[1], '', reason: '中英两块之间空行分隔');
      expect(lines[2], contains('【指令执行】[Agent 模式]'));
      expect(lines[2], contains('先调用 narrchat_readHistory **一次**'));
      expect(lines[2], contains('大纲'));
      expect(lines[2], contains('narrchat_editHistory'));
      expect(lines[2], contains('恰好一条'));
      expect(lines[2], contains('五个区块'));
      expect(lines[2], contains('## 角色状态'));
      // 顺序 = 四步顺序：读史 → 记忆条目 → 正文（记忆先于正文）。
      expect(
        lines[2].indexOf('narrchat_readHistory'),
        lessThan(lines[2].indexOf('narrchat_editHistory')),
      );
      expect(
        lines[2].indexOf('narrchat_editHistory'),
        lessThan(lines[2].indexOf('## 剧情演绎')),
      );
    });
  });

  group('AgentLv2PromptFormat', () {
    const format = AgentLv2PromptFormat();

    test('契约常量：输出标题与六个状态工具名（时间属于正文、无时间工具）', () {
      expect(AgentLv2PromptFormat.outputSections, ['剧情演绎', '推荐行动', '当前时间']);
      expect(AgentLv2PromptFormat.stateToolNames, [
        'narrchat_readWorldState',
        'narrchat_readCharacterState',
        'narrchat_readHistory',
        'narrchat_editWorldState',
        'narrchat_editCharacterState',
        'narrchat_editHistory',
      ]);
    });

    test('systemHead 集中双语契约（三区块输出 / 锚定编辑 / 维护回合 / 思考语言）+ 格式优先行，末行为空行', () {
      final lines = format.systemHead;
      expect(lines.first, '当前模式：Agent');
      expect(lines[2], contains('【AGENT 模式契约】'));
      // 中文 9 条（8 条流程 / 思考规则 + 记忆条目「格式优先」单行提示），
      // 英文 8 条（格式优先行按中文单行给出），
      // 全部为 `- ` 项目符号（不用数字序号：渲染会重编号、中英配对会错位）。
      final zhCount = lines.where((l) => l.startsWith('- 【')).length;
      final enCount = lines.where((l) => l.startsWith('- [')).length;
      expect(zhCount, 9);
      expect(enCount, 8);
      expect(lines, contains(kMemoryEntryFormatPrecedence));
      expect(lines.any((l) => RegExp(r'^\d+\. ').hasMatch(l)), isFalse);
      // 思考（reasoning）一律英文（英文思考便于阅读模型推理）。
      expect(lines.any((l) => l.contains('Write ALL of your reasoning')), isTrue);
      expect(lines.any((l) => l.contains('思考（reasoning）一律用**英文**书写')), isTrue);
      // 关键规则与工具契约引用（中英双语规则各一次），且只引用六个新工具。
      expect(lines.any((l) => l.contains('narrchat_editWorldState')), isTrue);
      expect(lines.any((l) => l.contains('narrchat_editCharacterState')), isTrue);
      expect(lines.any((l) => l.contains('narrchat_editHistory')), isTrue);
      expect(lines.any((l) => l.contains('narrchat_readWorldState')), isTrue);
      expect(lines.any((l) => l.contains('narrchat_readHistory')), isTrue);
      expect(lines.any((l) => l.contains('narrchat_readState')), isFalse,
          reason: '旧的合并工具已完全移除');
      expect(lines.any((l) => l.contains('narrchat_editSection')), isFalse);
      expect(lines.any((l) => l.contains('锚定式编辑')), isTrue);
      expect(lines.where((l) => l.contains('op=append')).length, 4);
      expect(lines.any((l) => l.contains('懒修改')), isTrue);
      expect(lines.any((l) => l.contains('状态维护回合')), isTrue);
      // 时间在正文声明；世界/角色/记忆三块是禁令（不得作为输出格式模仿）。
      for (final banned in ['## 世界状态', '## 角色状态', '## 记忆总结']) {
        expect(lines.any((l) => l.contains(banned)), isTrue,
            reason: '缺少禁令：$banned');
      }
      expect(lines.any((l) => l.contains('## 当前时间')), isTrue);
      // 小幅改动 = 常态：单调用多条 set；noChange 为最后手段（非偷懒捷径）。
      expect(lines.any((l) => l.contains('小幅改动是常态')), isTrue);
      expect(lines.any((l) => l.contains('每条对应一行改动')), isTrue);
      expect(lines.any((l) => l.contains('noChange 是例外而非偷懒捷径')), isTrue);
      expect(lines.any((l) => l.contains('「无需大改」这类空泛理由')), isTrue);
      // 历史形状 = 三个正文小节；状态由读取器提供。
      expect(lines.any((l) => l.contains('历史中你之前的消息恰好就是这三个小节')), isTrue);
      // 读取**只一次**：维护回合复用正文回合的读取结果、不重复读取。
      expect(lines.any((l) => l.contains('只读一次')), isTrue);
      expect(lines.any((l) => l.contains('reuses THESE results')), isTrue);
      expect(lines.any((l) => l.contains('The readers are DISABLED in this turn')),
          isTrue);
      expect(lines.any((l) => l.contains('本回合**读取工具已禁用**')), isTrue);
      expect(lines.last, '');
    });

    test('空槽位：角色状态格式 / 记忆格式 / 用户头部不适用', () {
      expect(format.systemAfterIdentity, isEmpty);
      expect(format.systemTail, isEmpty);
      expect(format.userHead, isEmpty);
    });

    test('userExecuteNote 双语：先读状态再只写正文（不得再声称「四个状态工具」）', () {
      final lines = format.userExecuteNote;
      expect(lines, hasLength(3));
      // 规则句 EN 在前、中文在后（英文遵循率更高），两块空行分隔。
      expect(lines[0], contains('[Execute now]'));
      expect(lines[0], contains('then write the STORY'));
      expect(lines[0], contains('narrchat_readWorldState'));
      expect(lines[0], contains('narrchat_readHistory'));
      expect(lines[1], '');
      expect(lines[2], contains('【指令执行】[Agent 模式]'));
      expect(lines[2], contains('先调用读取工具'));
      expect(lines[2], contains('narrchat_readWorldState'));
      expect(lines[2], contains('三个小节'));
      // 状态修改只在状态维护回合（旧文案「全部四个状态工具」是模型输出 6 区块的诱因）。
      for (final l in lines) {
        expect(l, isNot(contains('全部四个状态工具')));
        expect(l, isNot(contains('ALL FOUR')));
      }
    });
  });

  group('PromptSections 组装槽位', () {
    const sections = PromptSections();
    const book = Book(title: '测试书');

    /// 以 [format] 组装系统指令（共享骨架 + 该模式槽位）。
    String systemOf(PromptFormatSpec format) => sections.buildSystemPrompt(
          book: book,
          worldBookEntries: '',
          mods: null,
          format: format,
        );

    /// 断言 [markers] 依序出现在 [text] 中。
    void expectOrdered(String text, List<String> markers) {
      final positions = markers.map((m) => text.indexOf(m)).toList();
      for (var i = 0; i < positions.length; i++) {
        expect(positions[i], greaterThanOrEqualTo(0), reason: '缺少标记：${markers[i]}');
      }
      for (var i = 1; i < positions.length; i++) {
        expect(
          positions[i],
          greaterThan(positions[i - 1]),
          reason: '顺序错误：${markers[i - 1]} 应在 ${markers[i]} 之前',
        );
      }
    }

    test('系统指令：非空槽位按固定顺序插入共享骨架', () {
      const stub = _StubFormat(
        head: ['<HEAD>'],
        afterIdentity: ['<AFTER_IDENTITY>'],
        tail: ['<TAIL>'],
      );
      final system = sections.buildSystemPrompt(
        book: book,
        worldBookEntries: '',
        mods: null,
        format: stub,
      );
      expectOrdered(system, [
        '[MODE: SANDBOX]',
        '<HEAD>',
        '[Markdown 兼容]',
        '【推荐行动格式】',
        '<AFTER_IDENTITY>',
        '书籍名称：',
        '<TAIL>',
        '【警告】',
      ]);
    });

    test('系统指令：推荐行动格式为共享输出契约（含历史兼容提示，三模式逐字一致）', () {
      for (final format in <PromptFormatSpec>[
        const ChatPromptFormat(),
        const AgentLv1PromptFormat(),
        const AgentLv2PromptFormat(),
      ]) {
        final system = systemOf(format);
        final reason = '${format.modeLabel} 缺少共享的推荐行动契约';
        expect(system, contains('【推荐行动格式】'), reason: reason);
        // 条数口径：整块 2~5 条，含末条「自定义行动」。
        expect(system, contains('必须严格使用 Markdown 序号列表'), reason: reason);
        expect(system, contains('整块共 2~5 条'), reason: reason);
        expect(system, contains('最后一条固定为「自定义行动」'), reason: reason);
        // 历史兼容提示：历史里的旧写法（`- ` / `* ` 等）不得继承，只认上面的契约。
        expect(
          system,
          contains('【历史兼容】历史轮次的 `## 推荐行动` 若写成 `- `、`* ` 或其它格式，'
              '一律不得继承，只按上述【推荐行动格式】输出。'),
          reason: reason,
        );
        expect(
          system.indexOf('【推荐行动格式】'),
          lessThan(system.indexOf('【历史兼容】')),
          reason: '历史兼容提示应在格式契约之后',
        );
        expect(
          system.indexOf('【历史兼容】'),
          lessThan(system.indexOf('形态示例：')),
          reason: '历史兼容提示应在形态示例之前（示例是最后读到的正面形状）',
        );
        // 形态示例用真实序号给出（未包围栏，模型不会照抄围栏标记）。
        expect(
          system,
          contains('形态示例：\n\n'
              '1. {推荐下一步选项1}\n'
              '2. {推荐下一步选项2}\n'
              '3. {推荐下一步选项3}\n'
              '4. 自定义行动\n'),
          reason: reason,
        );
        expect(
          system,
          isNot(contains('```markdown\n1. {推荐下一步选项1}')),
          reason: '示例不得包在围栏里，否则模型可能连围栏一起输出',
        );
        // 兼容提示只覆盖 `## 推荐行动`，不波及其它区块的格式契约。
        final hintStart = system.indexOf('【历史兼容】');
        final hint = system.substring(
          hintStart,
          system.indexOf('\n', hintStart),
        );
        expect(hint, contains('`## 推荐行动`'), reason: reason);
        for (final other in ['世界状态', '角色状态', '记忆总结']) {
          expect(hint, isNot(contains(other)), reason: '兼容提示不涉及其它区块：$other');
        }
        expect(
          '【历史兼容】'.allMatches(system).length,
          1,
          reason: '共享段只注入一次',
        );
      }
    });

    test('系统指令：角色状态完整性为共享段（英详细 + 中概括，三模式逐字一致）', () {
      // 英详细：缺项即失败 / 新增必须补全 / 不删旧条目与主要角色。
      const en = '- [Character-state completeness] Keep the character state COMPLETE: '
          'a missing entry is a failure, an extra entry is not. Every character '
          'that has appeared stays in the character state with the FULL attribute '
          'set its category format requires (see the category formats above): when '
          'a character or an attribute line is added, fill in ALL attributes of '
          'that category — never a partial subset. NEVER omit or delete a main '
          'character, not even one that has not appeared for many rounds. Entries '
          'beyond the category format (extra characters or attribute lines added '
          'earlier) are kept as well.';
      // 中概括：一行摘要（与 Agent 档位双语规则同一格式）。
      const zh = '- 【角色状态完整性】角色状态必须完整：已登场的角色一个都不能少'
          '（主要角色即使连续多轮未出场也不例外），新增条目按所属类别格式'
          '补全**全部**属性项，类别格式之外的额外条目同样保留，一律不得删除。';

      for (final format in <PromptFormatSpec>[
        const ChatPromptFormat(),
        const AgentLv1PromptFormat(),
        const AgentLv2PromptFormat(),
      ]) {
        final system = systemOf(format);
        final reason = '${format.modeLabel} 缺少共享的角色状态完整性契约';
        expect(system, contains(en), reason: reason);
        expect(system, contains(zh), reason: reason);
        // 英详细在前、中概括在后（既有双语格式）。
        expect(
          system.indexOf(en),
          lessThan(system.indexOf(zh)),
          reason: '英文详细应在中文概括之前',
        );
        // 紧接其引用的「角色类别描述格式」，且在三模式的同一位置。
        expect(
          system.indexOf('角色类别描述格式'),
          lessThan(system.indexOf(zh)),
          reason: '完整性契约应在角色类别格式之后',
        );
        expect(
          system.indexOf(zh),
          lessThan(system.indexOf('世界书：')),
          reason: '完整性契约仍属角色段，应早于世界书',
        );
        expect(
          '- 【角色状态完整性】'.allMatches(system).length,
          1,
          reason: '共享段只注入一次',
        );
        // 措辞不提正文专属的「未登场」标注：Chat / Lv.1 的正文格式段仍保留它，
        // 而 Lv.2 的角色状态由工具维护（未出场角色本就无需改动、不该被要求标注）。
        if (format is AgentLv2PromptFormat) {
          expect(system, isNot(contains('未登场')), reason: 'Lv.2 不应收到正文专属标注要求');
        } else {
          expect(system, contains('未登场（本轮未出现）'), reason: '正文携带模式仍保留登场标注');
        }
      }
    });

    test('系统指令：所有空槽位不注入任何内容且空行节奏不变', () {
      const stub = _StubFormat();
      final system = sections.buildSystemPrompt(
        book: book,
        worldBookEntries: '',
        mods: null,
        format: stub,
      );
      expect(system, isNot(contains('<HEAD>')));
      expect(system, isNot(contains('<AFTER_IDENTITY>')));
      expect(system, isNot(contains('<TAIL>')));
      // 空槽位下：共享段（Markdown 规则 / 推荐行动契约）→（空行）→ 书籍名称；
      // 块之间恰好一个空行。
      expect(
        system,
        contains('删除线格式。\n\n【推荐行动格式】'),
        reason: '共享段不依赖任何槽位',
      );
      expect(
        system,
        contains('4. 自定义行动\n\n书籍名称：'),
        reason: '空槽位不得改变共享骨架的空行节奏',
      );
      expect(system, isNot(contains('\n\n\n')), reason: '不出现连续空行');
    });

    test('用户消息：userHead 在前，前置词/输入/后置词按标签分块，指令执行在后', () {
      const stub = _StubFormat(
        userHeadLines: ['<USER_HEAD>'],
        execute: ['<EXECUTE>'],
      );
      final user = sections.buildUserPrompt(
        book: book,
        lastRound: null,
        userInput: '输入',
        mods: null,
        format: stub,
      );
      expectOrdered(user, [
        '<USER_HEAD>',
        '【前置词开始】',
        '【前置词结束】',
        '【上轮时间】',
        '【用户输入内容开始】',
        '输入',
        '【用户输入内容结束】',
        '【后置词开始】',
        '【后置词结束】',
        '<EXECUTE>',
        '【警告】',
      ]);
      expect(user, isNot(contains('==========')), reason: '不再使用 = 分隔线');
      // 用户输入被空行 + 标签包围（边界清晰，且不与相邻块并段）。
      expect(user, contains('【用户输入内容开始】\n\n输入\n\n【用户输入内容结束】'));
      // 收尾【警告】与【指令执行】之间留空行。
      expect(user, contains('\n\n【警告】'));
    });

    test('三种格式组装结果相互排除', () {
      final chat = systemOf(const ChatPromptFormat());
      final lv1 = systemOf(const AgentLv1PromptFormat());
      final lv2 = systemOf(const AgentLv2PromptFormat());

      // Chat：6 区块纪律 + 记忆格式，无工具契约。
      expect(chat, contains('【绝对服从】'));
      expect(chat, contains('【记忆总结格式】'));
      expect(chat, isNot(contains('【AGENT 模式契约】')));
      expect(chat, isNot(contains('narrchat_readHistory')));

      // Lv.1：Chat 骨架（含角色状态格式）但无记忆格式，有历史工具契约。
      expect(lv1, contains('【绝对服从】'));
      expect(lv1, contains('【角色状态输出格式】'));
      expect(lv1, isNot(contains('【记忆总结格式】')));
      expect(lv1, contains('narrchat_readHistory'));
      expect(lv1, contains('narrchat_editHistory'));
      expect(lv1, isNot(contains('narrchat_readWorldState')));
      expect(lv1, isNot(contains('【AGENT 模式契约】')));

      // Lv.2：只有 AGENT 契约（无区块纪律 / 无快照规则 / 无记忆格式）。
      expect(lv2, contains('【AGENT 模式契约】'));
      expect(lv2, isNot(contains('【绝对服从】')));
      expect(lv2, isNot(contains('【二级标题纪律】')));
      expect(lv2, isNot(contains('【状态快照规则】')));
      expect(lv2, isNot(contains('【记忆总结格式】')));
    });
  });

  group('记忆总结轮次合并（档位驱动）', () {
    const sections = PromptSections();

    /// 上一轮（第 16 轮）的记忆总结：1-7 已合并 + 散条目 8..16。
    /// 档位 5 → 第 17 轮达到 2T=10，应合并 8-12。
    const memoryText = '- 1 - 7 | t1 ~ t7 | 前七轮要点。\n'
        '- 8 | t8 | 第八轮。\n'
        '- 9 | t9 | 第九轮。\n'
        '- 10 | t10 | 第十轮。\n'
        '- 11 | t11 | 第十一轮。\n'
        '- 12 | t12 | 第十二轮。\n'
        '- 13 | t13 | 第十三轮。\n'
        '- 14 | t14 | 第十四轮。\n'
        '- 15 | t15 | 第十五轮。\n'
        '- 16 | t16 | 第十六轮。';
    const lastRound = Round(
      bookUuid: 'b1',
      roundIndex: 16,
      memorySummary: memoryText,
      currentTime: 't16',
    );
    const bookOff = Book(title: '测试书');
    const bookOn5 = Book(title: '测试书', memorySummaryRounds: 5);

    String systemOf(Book book, PromptFormatSpec format) =>
        sections.buildSystemPrompt(
          book: book,
          worldBookEntries: '',
          mods: null,
          format: format,
        );

    String userOf(Book book, PromptFormatSpec format, {Round? round}) =>
        sections.buildUserPrompt(
          book: book,
          lastRound: round,
          userInput: '继续',
          mods: null,
          format: format,
        );

    test('策略文案：档位 0 = 不合并且保留既有区间；档位 5/10 = 2T 触发 + 合并格式', () {
      final off = memoryMergePolicyLines(0).join('\n');
      expect(off, contains('不要主动合并'));
      expect(off, contains('原样保留'));
      expect(off, isNot(contains(kMemoryMergedEntryFormat)));

      final on5 = memoryMergePolicyLines(5).join('\n');
      expect(on5, contains(kMemoryMergedEntryFormat));
      expect(on5, contains('2 × 5'));
      expect(on5, contains('最旧的 5 条'));
      expect(on5, contains('以用户要求为准'));

      final on10 = memoryMergePolicyLines(10).join('\n');
      expect(on10, contains('2 × 10'));
      expect(on10, contains('最旧的 10 条'));
    });

    test('本轮指令：应合并时给出填好区间与首末时间的模板行；无动作 / 无计划为空', () {
      final p = planMemoryMerge(
        memoryText: memoryText,
        tier: 5,
        newRoundIndex: 17,
      );
      final chat = memoryMergeDirectiveLines(p).join('\n');
      expect(chat, contains('【本轮记忆合并】'));
      expect(chat, contains('- 8 - 12 | t8 ~ t12 | {记忆内容}'));
      expect(chat, contains('其它行逐字保留'));
      expect(chat, contains('以用户要求为准'));

      final agent = memoryMergeAgentDirectiveLines(p).join('\n');
      expect(agent, contains('narrchat_editHistory'));
      expect(agent, contains('op=set'));
      expect(agent, contains('- 8 - 12 | t8 ~ t12 | {记忆内容}'));

      // 还没到 2T（第 11 轮）→ 无指令；档位 0 / null → 无指令。
      expect(
        memoryMergeDirectiveLines(
          planMemoryMerge(memoryText: memoryText, tier: 5, newRoundIndex: 11),
        ),
        isEmpty,
      );
      expect(memoryMergeDirectiveLines(null), isEmpty);
      expect(memoryMergeAgentDirectiveLines(null), isEmpty);
      expect(
        memoryMergeDirectiveLines(
          planMemoryMerge(memoryText: memoryText, tier: 0, newRoundIndex: 17),
        ),
        isEmpty,
      );
    });

    test('系统指令：策略块按档位注入；档位 0 与档位 5 互相排除，三个模式同口径', () {
      final off = systemOf(bookOff, const ChatPromptFormat());
      expect(off, contains('不要主动合并'));
      expect(off, isNot(contains(kMemoryMergedEntryFormat)));

      final on = systemOf(bookOn5, const ChatPromptFormat());
      expect(on, contains(kMemoryMergedEntryFormat));
      expect(on, contains('2 × 5'));
      // Chat 记忆规则不再出现「不得将多条合并为一条」的自相矛盾表述。
      expect(on, isNot(contains('不得将多条合并为一条')));
      expect(on, contains('每一轮都必须被一条记忆条目覆盖'));

      for (final format in <PromptFormatSpec>[
        const AgentLv1PromptFormat(),
        const AgentLv2PromptFormat(),
      ]) {
        final s = systemOf(bookOn5, format);
        expect(s, contains(kMemoryMergedEntryFormat),
            reason: '${format.modeLabel} 档位 > 0 时必须拿到同一份合并策略');
        final offS = systemOf(bookOff, format);
        expect(offS, contains('不要主动合并'));
      }
    });

    test('用户消息：Chat 在用户输入之后、指令执行之前注入本轮合并指令', () {
      final user = userOf(bookOn5, const ChatPromptFormat(), round: lastRound);
      expect(user, contains('【本轮记忆合并】'));
      expect(user, contains('- 8 - 12 | t8 ~ t12 | {记忆内容}'));
      final posInput = user.indexOf('【用户输入内容结束】');
      final posMerge = user.indexOf('【本轮记忆合并】');
      final posExec = user.indexOf('【指令执行】');
      expect(posMerge, greaterThan(posInput),
          reason: '指令必须在用户输入之后（用户要求优先）');
      expect(posMerge, lessThan(posExec));
      expect(user, contains('以用户要求为准'));

      // Agent 档位由阶段帧承载，用户消息不重复注入。
      for (final format in <PromptFormatSpec>[
        const AgentLv1PromptFormat(),
        const AgentLv2PromptFormat(),
      ]) {
        expect(userOf(bookOn5, format, round: lastRound),
            isNot(contains('【本轮记忆合并】')));
      }
      // 档位 0 / 未到 2T / 无上一轮 → 不注入。
      expect(userOf(bookOff, const ChatPromptFormat(), round: lastRound),
          isNot(contains('【本轮记忆合并】')));
      expect(
        userOf(
          bookOn5,
          const ChatPromptFormat(),
          round: const Round(
            bookUuid: 'b1',
            roundIndex: 10,
            memorySummary: memoryText,
          ),
        ),
        isNot(contains('【本轮记忆合并】')),
        reason: '上一轮是 16，本轮 11 的尾部片段末条对不上 → 不动作',
      );
      expect(userOf(bookOn5, const ChatPromptFormat()),
          isNot(contains('【本轮记忆合并】')));
    });

    test('用户消息：memoryMergeUserNote 槽位位于后置词之后、指令执行之前', () {
      const stub = _StubFormat(userMerge: ['<MERGE>'], execute: ['<EXECUTE>']);
      final user = sections.buildUserPrompt(
        book: bookOff,
        lastRound: null,
        userInput: '输入',
        mods: null,
        format: stub,
      );
      final pos = user.indexOf('<MERGE>');
      expect(pos, greaterThan(user.indexOf('【后置词结束】')));
      expect(pos, lessThan(user.indexOf('<EXECUTE>')));
    });

    test('Agent 契约与「本轮只此一条」不冲突：记忆步骤写明合并的 op 与漏读兜底', () {
      const lv1 = AgentLv1PromptFormat();
      final note = lv1.memoryNote().join('\n');
      expect(note, contains('op=set'), reason: '记忆步骤必须说明合并的 op');
      expect(note, contains('只此一次调用'));
      expect(note, isNot(contains('本轮历史只此一条')));
      expect(AgentLv1PromptFormat.memoryEditLine, contains('op=set'));
      expect(AgentLv1PromptFormat.historyContract.join('\n'), contains('op=set'));
      expect(
        AgentLv1PromptFormat.historyContract.join('\n'),
        contains('range entry'),
      );
      expect(lv1.userExecuteNote.join('\n'), contains('op=set'));

      final lv2 = const AgentLv2PromptFormat().systemHead.join('\n');
      expect(lv2, contains('op=set per range'));
      expect(lv2, contains('每个目标区间'));

      // 合并指令自带「会话里还没历史全文时先读一次」的兜底（漏读流程也能锚定）。
      final directive = memoryMergeAgentDirectiveLines(
        planMemoryMerge(memoryText: memoryText, tier: 5, newRoundIndex: 17),
      ).join('\n');
      expect(directive, contains('先调用一次 narrchat_readHistory'));
      expect(directive, contains('不要重复读取'));
    });
  });
}
