import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/world_book_entry.dart';
import 'package:narrchat/services/app_notice_center.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/world_book_panel.dart';

import 'helpers/notice_harness.dart';

/// 世界书面板（纯草稿组件）。
///
/// 面板不依赖 Provider、不直接读写数据库：新增 / 编辑 / 启停 / 删除只通过
/// `onChanged` 回传完整草稿，真正落库由书籍设置页点「保存」时统一提交。
void main() {
  WorldBookEntry entry({
    String uuid = 'w1',
    String keyword = '青云宗',
    String content = '宗门设定',
    bool isActive = true,
  }) {
    return WorldBookEntry(
      uuid: uuid,
      bookUuid: '',
      keyword: keyword,
      content: content,
      isActive: isActive,
      createdAt: DateTime.utc(2026, 1, 1),
    );
  }

  /// Pump 面板，返回草稿回调记录与通知中心（供提示断言）。
  Future<({List<List<WorldBookEntry>> emitted, AppNoticeCenter center})>
  pumpPanel(
    WidgetTester tester, {
    List<WorldBookEntry> entries = const [],
    AppNoticeCenter? center,
  }) async {
    final emitted = <List<WorldBookEntry>>[];
    final noticeCenter = center ?? AppNoticeCenter();
    if (center == null) addTearDown(noticeCenter.dispose);
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: NarrChatTheme.light,
        builder: floatingNoticeBuilder(center: noticeCenter),
        home: Scaffold(
          body: SingleChildScrollView(
            child: WorldBookPanel(
              entries: entries,
              onChanged: (list) => emitted.add(List.of(list)),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return (emitted: emitted, center: noticeCenter);
  }

  testWidgets('渲染条目与数量', (tester) async {
    await pumpPanel(
      tester,
      entries: [
        entry(uuid: 'w1', keyword: '青云宗'),
        entry(uuid: 'w2', keyword: '苏清月', content: '女主设定', isActive: false),
      ],
    );

    expect(find.text('条目（2）'), findsOneWidget);
    expect(find.text('青云宗'), findsOneWidget);
    expect(find.text('女主设定'), findsOneWidget);
  });

  testWidgets('整行点击切换启用状态：只回调草稿', (tester) async {
    final result = await pumpPanel(tester, entries: [entry()]);

    await tester.tap(find.text('青云宗'));
    await tester.pump();

    expect(result.emitted, isNotEmpty);
    expect(result.emitted.last.single.isActive, isFalse);
    expect(result.emitted.last.single.uuid, 'w1', reason: '沿用已有条目身份');
  });

  testWidgets('新增条目：追加到草稿末尾并清空表单', (tester) async {
    final result = await pumpPanel(tester);

    await tester.enterText(find.widgetWithText(TextField, '触发关键词'), '魔宗');
    await tester.enterText(
      find.widgetWithText(TextField, '注入内容（命中后写入 System Prompt）'),
      '魔宗设定',
    );
    await tester.tap(find.text('添加条目'));
    await tester.pump();

    expect(result.emitted, isNotEmpty);
    final added = result.emitted.last.single;
    expect(added.keyword, '魔宗');
    expect(added.content, '魔宗设定');
    expect(added.isActive, isTrue);
    expect(added.uuid, isEmpty, reason: 'uuid 由落库时统一生成');
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, '触发关键词'))
          .controller!
          .text,
      isEmpty,
      reason: '添加成功后清空关键词输入',
    );
  });

  testWidgets('关键词或内容为空：只提示、不回调', (tester) async {
    final result = await pumpPanel(tester);

    await tester.tap(find.text('添加条目'));
    await tester.pump();

    expect(result.emitted, isEmpty);
    expect(result.center.current?.message, contains('关键词与内容不能为空'));
    await flushNotices(tester);
  });

  testWidgets('删除条目：只回调剩余草稿', (tester) async {
    final result = await pumpPanel(
      tester,
      entries: [
        entry(uuid: 'w1'),
        entry(uuid: 'w2', keyword: '第二个'),
      ],
    );

    await tester.tap(find.byTooltip('删除').first);
    await tester.pump();

    expect(result.emitted, isNotEmpty);
    expect(result.emitted.last.map((e) => e.uuid), ['w2']);
  });

  testWidgets('编辑条目：对话框保存后只回调草稿', (tester) async {
    final result = await pumpPanel(tester, entries: [entry()]);

    await tester.tap(find.byTooltip('编辑'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);

    final dialog = find.byType(AlertDialog);
    await tester.enterText(
      find.descendant(
        of: dialog,
        matching: find.widgetWithText(TextField, '触发关键词'),
      ),
      '青云宗, 山门',
    );
    await tester.tap(find.descendant(of: dialog, matching: find.text('保存')));
    await tester.pumpAndSettle();

    expect(result.emitted, isNotEmpty);
    expect(result.emitted.last.single.uuid, 'w1');
    expect(result.emitted.last.single.keyword, '青云宗, 山门');
  });

  testWidgets('外部传入新列表时采纳（父级回声内容相同时不重置）', (tester) async {
    final center = AppNoticeCenter();
    addTearDown(center.dispose);
    final first = await pumpPanel(
      tester,
      entries: [entry(uuid: 'w1')],
      center: center,
    );
    expect(find.text('青云宗'), findsOneWidget);

    // 父级外部刷新：新增一条。面板应采纳新列表。
    await pumpPanel(
      tester,
      entries: [
        entry(uuid: 'w1'),
        entry(uuid: 'w2', keyword: '新条目'),
      ],
      center: center,
    );
    expect(find.text('新条目'), findsOneWidget);
    expect(first.emitted, isEmpty, reason: '外部采纳不伪造成用户改动');
  });
}
