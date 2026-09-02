import 'package:flutter_test/flutter_test.dart';

import 'package:narrchat/models/book.dart';
import 'package:narrchat/services/prompt_formats.dart';
import 'package:narrchat/services/prompt_sections.dart';

/// 模式格式生成要求（ChatPromptFormat / AgentPromptFormat / PromptMode）
/// 与共享组装（PromptSections）单元测试。
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
    test('chat / agent 解析到各自格式规格（单一真源）', () {
      expect(PromptMode.chat.format, same(const ChatPromptFormat()));
      expect(PromptMode.agent.format, same(const AgentPromptFormat()));
    });
  });

  group('ChatPromptFormat', () {
    const format = ChatPromptFormat();

    test('sectionOrder 为 6 区块固定顺序', () {
      expect(ChatPromptFormat.sectionOrder, [
        '剧情演绎',
        '推荐行动',
        '当前时间',
        '世界状态',
        '角色状态',
        '记忆总结',
      ]);
    });

    test('systemHead 集中 6 区块纪律（绝对服从 + 缩进清单 + 纪律 + 快照规则）', () {
      final lines = format.systemHead;
      expect(lines.first, '【绝对服从】以下规则必须无条件、无例外地严格执行，'
          '不得拒绝、不得询问、不得省略：');
      expect(lines, contains('   ## 剧情演绎'));
      expect(lines, contains('   ## 记忆总结'));
      expect(lines.any((l) => l.contains('【二级标题纪律】')), isTrue);
      expect(lines.any((l) => l.contains('【状态快照规则】')), isTrue);
      // 不含 AGENT 契约。
      expect(
        lines.any((l) => l.contains('【AGENT 模式契约】')),
        isFalse,
        reason: 'Chat 格式不得包含 AGENT 契约',
      );
    });

    test('systemAfterIdentity 为角色状态输出格式，末行为空行', () {
      final lines = format.systemAfterIdentity;
      expect(lines.first, contains('【角色状态输出格式】'));
      expect(lines.first, contains('必须使用以下结构化 Markdown'));
      expect(lines[1], contains('每个角色类别使用一级标题'));
      expect(lines.last, '');
    });

    test('systemTail 为记忆总结格式（含 6 条规则），末行为空行', () {
      final lines = format.systemTail;
      expect(lines.first, contains('【记忆总结格式】'));
      expect(lines[1], contains('每条记忆独占一行'));
      expect(lines[1], contains('不得使用真实日期'));
      expect(lines[1], contains('为已确认的历史记忆'));
      expect(lines.last, '');
    });

    test('userHead 含【格式要求】与记忆格式提醒', () {
      final lines = format.userHead;
      expect(lines[0], contains('【格式要求】'));
      expect(
        lines[0],
        contains('剧情演绎 → 推荐行动 → 当前时间 → 世界状态 → 角色状态 → 记忆总结'),
      );
      expect(lines[0], contains('严禁在其它任何位置使用二级标题'));
      expect(lines[1], contains('【记忆总结格式】'));
      expect(lines[1], contains('- 第N轮｜日期：xxx｜概括内容'));
    });

    test('userExecuteNote 为单行【指令执行】', () {
      final lines = format.userExecuteNote;
      expect(lines, hasLength(1));
      expect(lines.single, contains('【指令执行】'));
      expect(lines.single, contains('完整输出 6 个二级标题区块'));
      expect(lines.single, contains('立即从 ## 剧情演绎 开始输出。'));
    });
  });

  group('AgentPromptFormat', () {
    const format = AgentPromptFormat();

    test('契约常量：输出标题与状态工具名（时间属于正文、无时间工具）', () {
      expect(AgentPromptFormat.outputSections, ['剧情演绎', '推荐行动', '当前时间']);
      expect(AgentPromptFormat.stateToolNames, [
        'narrchat_editSection',
      ]);
    });

    test('systemHead 集中双语 7 条契约（三区块输出 / 锚定编辑 / 状态维护回合），末行为空行', () {
      final lines = format.systemHead;
      expect(lines.first, contains('【AGENT 模式契约】'));
      // 双语成对出现（中文 7 条 + 英文 7 条）。
      final zhCount = lines.where((l) => l.startsWith(RegExp(r'^\d\. 【'))).length;
      final enCount = lines.where((l) => l.startsWith(RegExp(r'^\d\. \['))).length;
      expect(zhCount, 7);
      expect(enCount, 7);
      // 关键规则与工具契约引用（中英双语规则各一次）。
      expect(lines.any((l) => l.contains('narrchat_editSection')), isTrue);
      expect(lines.any((l) => l.contains('narrchat_readState')), isTrue);
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
      // 状态来源 = readState 工具输出（模型自取）；历史形状 = 三个正文小节。
      expect(lines.any((l) => l.contains('narrchat_readState')), isTrue);
      expect(lines.any((l) => l.contains('历史中你之前的消息恰好就是这三个小节')), isTrue);
      expect(lines.last, '');
    });

    test('空槽位：角色状态格式 / 记忆格式 / 用户头部不适用', () {
      expect(format.systemAfterIdentity, isEmpty);
      expect(format.systemTail, isEmpty);
      expect(format.userHead, isEmpty);
    });

    test('userExecuteNote 双语：先读状态再只写正文（不得再声称「四个状态工具」）', () {
      final lines = format.userExecuteNote;
      expect(lines, hasLength(2));
      // 规则句 EN 在前、中文在后（英文遵循率更高）。
      expect(lines[0], contains('[Execute now]'));
      expect(lines[0], contains('then write the STORY'));
      expect(lines[0], contains('narrchat_readState'));
      expect(lines[1], contains('【指令执行】'));
      expect(lines[1], contains('先调用 narrchat_readState'));
      expect(lines[1], contains('三个小节'));
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
        '书籍名称：测试书',
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
      // 空槽位下：Markdown 规则行 → 空行 → 空行 → 书籍名称（无多余内容）。
      expect(
        system,
        contains('删除线格式 \n\n\n书籍名称'),
        reason: '空槽位不得改变共享骨架的空行节奏',
      );
    });

    test('用户消息：userHead 在分隔线之前，指令执行在后置词之后', () {
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
        '==========',
        '【用户输入内容】',
        '<EXECUTE>',
        '【警告】',
      ]);
    });

    test('Chat / AGENT 格式组装结果相互排除', () {
      final chat = sections.buildSystemPrompt(
        book: book,
        worldBookEntries: '',
        mods: null,
        format: const ChatPromptFormat(),
      );
      final agent = sections.buildSystemPrompt(
        book: book,
        worldBookEntries: '',
        mods: null,
        format: const AgentPromptFormat(),
      );
      expect(chat, contains('【绝对服从】'));
      expect(chat, isNot(contains('【AGENT 模式契约】')));
      expect(agent, contains('【AGENT 模式契约】'));
      expect(agent, isNot(contains('【绝对服从】')));
      expect(agent, isNot(contains('【二级标题纪律】')));
      expect(agent, isNot(contains('【状态快照规则】')));
      expect(agent, isNot(contains('【记忆总结格式】')));
    });
  });
}
