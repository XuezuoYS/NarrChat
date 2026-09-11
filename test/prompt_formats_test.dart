import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/models/book.dart';
import 'package:narrchat/services/prompt_formats.dart';
import 'package:narrchat/services/prompt_sections.dart';

/// 模式格式生成要求（ChatPromptFormat / AgentLv1PromptFormat /
/// AgentLv2PromptFormat / PromptMode）与共享组装（PromptSections）单元测试。
///
/// 验证点：
/// - 各格式规格集中持有模式特有文案（槽位内容、契约常量）；
/// - 空槽位不注入任何内容，非空槽位按固定位置插入共享骨架；
/// - 组装结果只含对应模式的格式段（互斥断言）。
class _StubFormat implements PromptFormatSpec {
  const _StubFormat({
    this.head = const [],
    this.afterIdentity = const [],
    this.tail = const [],
    this.userHeadLines = const [],
    this.execute = const [],
  });

  /// 各槽位可配置的测试内容（marker 便于定位插入位置）。
  final List<String> head;
  final List<String> afterIdentity;
  final List<String> tail;
  final List<String> userHeadLines;
  final List<String> execute;

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

    test('systemAfterIdentity 为角色状态输出格式（围栏契约 + 结构说明 + 形态示例）', () {
      final lines = format.systemAfterIdentity;
      expect(lines.first, contains('【角色状态输出格式】'));
      expect(lines.first, contains('```markdown 围栏'));
      expect(lines[2], contains('每个角色类别使用一级标题'));
      // 形态示例以真实围栏给出（模型照此形状输出）。
      final example = lines.indexOf('```markdown');
      expect(example, greaterThan(0));
      expect(lines.sublist(example).take(2), ['```markdown', '# 主角']);
      expect(lines.sublist(example), contains('## 林远'));
      expect(lines.last, '');
    });

    test('systemTail 为记忆总结格式（项目符号规则），末行为空行', () {
      final lines = format.systemTail;
      expect(lines.first, contains('【记忆总结格式】'));
      expect(lines[1], '');
      final rules = lines[2];
      expect(rules, contains('- 每条记忆独占一行'));
      expect(rules, contains('不得使用真实日期'));
      expect(rules, contains('为已确认的历史记忆'));
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
      expect(lines[2], contains('- 第N轮｜日期：xxx｜概括内容'));
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

    test('systemTail 为历史工具契约（先读后写 / 只读一次 / 每轮恰一条 / 正文禁止记忆区块）', () {
      final lines = format.systemTail;
      expect(lines.first, contains('narrchat_readHistory'));
      expect(lines.first, startsWith('- '));
      expect(lines.first, contains('state-maintenance turn'));
      expect(lines.any((l) => l.contains('禁止')), isTrue);
      expect(lines.any((l) => l.contains('恰好一条')), isTrue);
      expect(lines.any((l) => l.contains('narrchat_editHistory')), isTrue);
      expect(lines.any((l) => l.contains('不接受')), isTrue);
      // 历史只读一次：维护回合复用正文回合的读取结果。
      expect(lines.any((l) => l.contains('历史**只读一次**')), isTrue);
      expect(lines.first, contains('Read history ONCE'));
      expect(lines.any((l) => l.contains('第一个维护帧就直接写')), isTrue);
      // 记忆格式（Chat 的规则）不在这里——历史由工具维护。
      expect(lines.any((l) => l.contains('【记忆总结格式】')), isFalse);
      expect(lines.last, '');
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

    test('userExecuteNote 双语：先读历史再输出 5 区块（历史只读一次）', () {
      final lines = format.userExecuteNote;
      expect(lines, hasLength(3));
      expect(lines[0], contains('[Execute now]'));
      expect(lines[0], contains('narrchat_readHistory'));
      expect(lines[0], contains('ONCE'));
      expect(lines[0], contains('five'));
      expect(lines[0], contains('reuses this read'));
      expect(lines[1], '', reason: '中英两块之间空行分隔');
      expect(lines[2], contains('【指令执行】[Agent 模式]'));
      expect(lines[2], contains('先调用 narrchat_readHistory'));
      expect(lines[2], contains('**一次**'));
      expect(lines[2], contains('复用这次读取结果'));
      expect(lines[2], contains('五个区块'));
      expect(lines[2], contains('## 角色状态'));
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

    test('systemHead 集中双语 8 条契约（三区块输出 / 锚定编辑 / 维护回合 / 思考语言），末行为空行', () {
      final lines = format.systemHead;
      expect(lines.first, '当前模式：Agent');
      expect(lines[2], contains('【AGENT 模式契约】'));
      // 双语成对出现（中文 8 条 + 英文 8 条：7 条流程规则 + 思考语言规则），
      // 全部为 `- ` 项目符号（不用数字序号：渲染会重编号、中英配对会错位）。
      final zhCount = lines.where((l) => l.startsWith('- 【')).length;
      final enCount = lines.where((l) => l.startsWith('- [')).length;
      expect(zhCount, 8);
      expect(enCount, 8);
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
        '<AFTER_IDENTITY>',
        '书籍名称：',
        '<TAIL>',
        '【警告】',
      ]);
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
      // 空槽位下：Markdown 规则行 →（空行）→ 书籍名称；块之间恰好一个空行。
      expect(
        system,
        contains('删除线格式。\n\n书籍名称：'),
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
      String systemOf(PromptFormatSpec format) => sections.buildSystemPrompt(
            book: book,
            worldBookEntries: '',
            mods: null,
            format: format,
          );
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
}
