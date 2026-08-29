import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/mod.dart';
import 'package:narrchat/providers/mod_provider.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/book_mod_panel.dart';
import 'package:provider/provider.dart';

import 'helpers/fakes.dart';

void main() {
  late FakeModDao dao;

  setUp(() {
    dao = FakeModDao(
      mods: const [
        Mod(
          uuid: 'm1',
          name: '文笔润色',
          description: '让文风更流畅',
          prePrompt: '前置词内容',
        ),
        Mod(
          uuid: 'm2',
          name: '去AI味',
          description: '减少 AI 腔',
          postPrompt: '后置词内容',
        ),
      ],
    );
  });

  /// Pump 书籍设置页的 Mod 管理面板（编辑模式，书 b1）。
  Future<void> pumpPanel(
    WidgetTester tester, {
    Size size = const Size(1400, 900),
    List<BookModConfig> configs = const [],
  }) async {
    dao.bookMods['b1'] = List.of(configs);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => ModProvider(dao: dao),
        child: MaterialApp(
          theme: NarrChatTheme.light,
          home: Scaffold(
            body: SingleChildScrollView(
              child: BookModPanel(bookUuid: 'b1'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('点击已启用条目主体打开只读【预览 mod】对话框', (tester) async {
    await pumpPanel(
      tester,
      configs: const [
        BookModConfig(bookUuid: 'b1', modUuid: 'm1', isEnabled: true),
      ],
    );

    await tester.tap(find.text('文笔润色'));
    await tester.pumpAndSettle();

    // 打开的是只读「查看 Mod」对话框：5 个内容标签 + 仅「关闭」按钮。
    expect(find.text('查看 Mod'), findsOneWidget);
    expect(find.text('基本信息'), findsOneWidget);
    expect(find.text('前置词'), findsOneWidget);
    expect(find.text('后置词'), findsOneWidget);
    expect(find.text('系统提示词'), findsOneWidget);
    expect(find.text('世界书'), findsOneWidget);
    expect(find.widgetWithText(TextField, '文笔润色'), findsOneWidget,
        reason: '预览对话框展示 Mod 名称');
    expect(find.text('保存'), findsNothing, reason: '预览为只读，无保存按钮');
    expect(find.text('关闭'), findsOneWidget);
  });

  testWidgets('点击开关只切换启用状态，不打开预览对话框', (tester) async {
    await pumpPanel(
      tester,
      configs: const [
        BookModConfig(bookUuid: 'b1', modUuid: 'm1', isEnabled: true),
      ],
    );

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(find.text('查看 Mod'), findsNothing, reason: '开关区域不应触发预览');
    expect(find.textContaining('暂无启用中的 Mod'), findsOneWidget,
        reason: '关闭开关后移入「未启用」标签');
  });

  testWidgets('点击拖动柄不打开预览对话框，也不改变顺序', (tester) async {
    await pumpPanel(
      tester,
      configs: const [
        BookModConfig(bookUuid: 'b1', modUuid: 'm1', isEnabled: true, sortOrder: 0),
        BookModConfig(bookUuid: 'b1', modUuid: 'm2', isEnabled: true, sortOrder: 1),
      ],
    );

    await tester.tap(find.byIcon(Icons.drag_handle).first);
    await tester.pumpAndSettle();

    expect(find.text('查看 Mod'), findsNothing, reason: '拖动柄区域不应触发预览');
    final firstY = tester.getTopLeft(find.text('文笔润色')).dy;
    final secondY = tester.getTopLeft(find.text('去AI味')).dy;
    expect(firstY < secondY, isTrue, reason: '未发生拖动，顺序保持自上而下');
  });

  testWidgets('窄屏（竖版）布局下点击条目主体同样打开预览对话框', (tester) async {
    await pumpPanel(
      tester,
      size: const Size(400, 800),
      configs: const [
        BookModConfig(bookUuid: 'b1', modUuid: 'm1', isEnabled: true),
      ],
    );

    await tester.tap(find.text('文笔润色'));
    await tester.pumpAndSettle();

    expect(find.text('查看 Mod'), findsOneWidget);
    expect(find.widgetWithText(TextField, '文笔润色'), findsOneWidget);
  });
}
