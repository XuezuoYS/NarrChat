import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/book_creation/book_creation_step.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/book_creation/book_creation_step_card.dart';
import 'package:narrchat/widgets/markdown_preview.dart';
import 'package:narrchat/widgets/streaming_markdown.dart';

/// 创建步骤卡片：运行态流式文本、完成态摘要 / 分步 Token、展开生成内容。
void main() {
  Future<void> pumpCard(
    WidgetTester tester, {
    required BookCreationStepStatus status,
    String visibleText = '',
    String? summary,
    String? detailMarkdown,
    List<String> problems = const [],
    BookCreationUsage usage = BookCreationUsage.empty,
  }) async {
    tester.view.physicalSize = const Size(900, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: NarrChatTheme.light,
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: BookCreationStepCard(
              badge: '3',
              title: '基础设定与世界书',
              status: status,
              visibleText: visibleText,
              summary: summary,
              detailMarkdown: detailMarkdown,
              problems: problems,
              usage: usage,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('运行中：无文本显示正在生成，有文本走流式渲染', (tester) async {
    await pumpCard(tester, status: BookCreationStepStatus.running);
    expect(find.text('生成中…'), findsOneWidget);
    expect(find.text('模型正在生成…'), findsOneWidget);
    expect(find.byType(StreamingMarkdown), findsNothing);

    await pumpCard(
      tester,
      status: BookCreationStepStatus.running,
      visibleText: '基础设定正在生成……',
    );
    expect(find.byType(StreamingMarkdown), findsOneWidget);
    expect(find.text('模型正在生成…'), findsNothing);
  });

  testWidgets('完成：摘要 + 分步 Token，展开后渲染生成内容', (tester) async {
    await pumpCard(
      tester,
      status: BookCreationStepStatus.done,
      summary: '基础设定 32 字 · 世界书 2 条',
      detailMarkdown: '### 基础设定\n\n- 世界：现代都市',
      usage: const BookCreationUsage(
        promptTokens: 120,
        completionTokens: 456,
        cachedTokensIn: 30,
      ),
    );

    expect(find.text('已完成'), findsOneWidget);
    expect(find.text('基础设定 32 字 · 世界书 2 条'), findsOneWidget);
    expect(find.text('输入 120 · 输出 456'), findsOneWidget);
    expect(find.byType(MarkdownPreview), findsNothing);

    await tester.tap(
      find.byKey(
        const ValueKey('book_creation_step_expand_基础设定与世界书'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(MarkdownPreview), findsOneWidget);
    expect(find.text('收起生成内容'), findsOneWidget);
  });

  testWidgets('失败：显示失败原因，不显示展开入口', (tester) async {
    await pumpCard(
      tester,
      status: BookCreationStepStatus.failed,
      summary: '写入失败',
      problems: const ['数据库写入失败：磁盘不可用'],
    );
    expect(find.text('失败'), findsOneWidget);
    expect(find.text('数据库写入失败：磁盘不可用'), findsOneWidget);
    expect(find.text('查看生成内容'), findsNothing);
  });
}
