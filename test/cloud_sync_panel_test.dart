import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/providers/ai_settings_provider.dart';
import 'package:narrchat/providers/cloud_sync_provider.dart';
import 'package:narrchat/services/sync/sync_models.dart';
import 'package:narrchat/services/webdav_service.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/cloud_sync_panel.dart';
import 'package:narrchat/widgets/settings_form_state.dart';
import 'package:provider/provider.dart';

import 'helpers/notice_harness.dart';

/// 云备份面板 widget 测试（R3：一库一单元一代）。
///
/// 重点：窄屏不溢出、亮/暗主题可渲染、同步模式分段可选、
/// 快照列表按「归属库 · 第 N 代」展示、点击快照走整份替换确认。
void main() {
  SettingsFormState makeForm({CloudSyncProvider? provider}) {
    return SettingsFormState(
      ai: AiSettingsProvider(),
      sync: provider ?? CloudSyncProvider(),
    );
  }

  Future<void> pumpPanel(
    WidgetTester tester, {
    required ThemeData theme,
    required SettingsFormState form,
    CloudSyncProvider? provider,
    double width = 360,
  }) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: provider ?? CloudSyncProvider()),
        ],
        child: MaterialApp(
          theme: theme,
          builder: floatingNoticeBuilder(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: CloudSyncPanel(form: form),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('窄屏(360) 亮色：面板渲染且无溢出', (tester) async {
    await pumpPanel(tester, theme: NarrChatTheme.light, form: makeForm());
    expect(find.text('云同步'), findsOneWidget);
    expect(find.byType(TextField), findsWidgets);
  });

  testWidgets('窄屏(360) 暗色：面板渲染且无溢出', (tester) async {
    await pumpPanel(tester, theme: NarrChatTheme.dark, form: makeForm());
    expect(find.text('云同步'), findsOneWidget);
  });

  testWidgets('超窄屏(320) 亮色：面板渲染且无溢出', (tester) async {
    await pumpPanel(tester,
        theme: NarrChatTheme.light, form: makeForm(), width: 320);
    expect(find.text('云同步'), findsOneWidget);
  });

  testWidgets('超窄卡片(261)：连接操作行换行而不溢出', (tester) async {
    await pumpPanel(tester,
        theme: NarrChatTheme.light, form: makeForm(), width: 261);
    expect(find.text('测试连接'), findsOneWidget);
    expect(find.text('删除连接'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: '不得出现 RenderFlex overflow');
  });

  testWidgets('同步模式分段：点「手动」后 form.syncMode 变为 manual', (tester) async {
    final form = makeForm();
    await pumpPanel(tester, theme: NarrChatTheme.light, form: form);
    expect(form.syncMode, SyncMode.auto);

    await tester.tap(find.text('手动'));
    await tester.pump();
    expect(form.syncMode, SyncMode.manual);

    await tester.tap(find.text('全自动'));
    await tester.pump();
    expect(form.syncMode, SyncMode.auto);
  });

  testWidgets('备份列表：按「归属库 · 第 N 代」展示，认不出的文件原样显示名字', (tester) async {
    final provider = CloudSyncProvider();
    final form = makeForm(provider: provider);
    provider.debugSetBackups([
      const WebDavFile(
        name: 'narrchat_library_shot-g3.db',
        size: 2048,
        lastModified: null,
      ),
      const WebDavFile(name: 'narrbook_abcdef12-3456-7890-abcd-ef1234567890_shot-g7.db'),
      const WebDavFile(name: 'manifest_narrchat_library.json'),
    ]);
    await pumpPanel(
      tester,
      theme: NarrChatTheme.light,
      form: form,
      provider: provider,
    );

    expect(find.text('目录库 · 第 3 代'), findsOneWidget);
    expect(find.textContaining('书籍 '), findsWidgets);
    expect(find.textContaining('第 7 代'), findsOneWidget);
    // 清单文件不是快照，不展示成条目。
    expect(find.text('manifest_narrchat_library.json'), findsNothing);
    expect(find.textContaining('2.0 KB'), findsOneWidget);
  });

  testWidgets('备份列表：多代快照按代际新 → 旧排列', (tester) async {
    final provider = CloudSyncProvider();
    final form = makeForm(provider: provider);
    provider.debugSetBackups([
      const WebDavFile(name: 'narrchat_library_shot-g2.db'),
      const WebDavFile(name: 'narrchat_library_shot-g7.db'),
      const WebDavFile(name: 'narrchat_library_shot-g5.db'),
    ]);
    final sorted = [...provider.backups]..sort(CloudSyncProvider.compareSnapshots);
    expect(
      sorted.map((f) => f.name).toList(),
      [
        'narrchat_library_shot-g7.db',
        'narrchat_library_shot-g5.db',
        'narrchat_library_shot-g2.db',
      ],
    );

    await pumpPanel(
      tester,
      theme: NarrChatTheme.light,
      form: form,
      provider: provider,
    );
    expect(find.text('目录库 · 第 7 代'), findsOneWidget);
    expect(find.text('目录库 · 第 5 代'), findsOneWidget);
    expect(find.text('目录库 · 第 2 代'), findsOneWidget);
  });

  testWidgets('点击快照：弹「整份替换」确认，确认后走 restoreSnapshot', (tester) async {
    final provider = CloudSyncProvider(); // 未配置：restoreSnapshot 直接拒绝
    final form = makeForm(provider: provider);
    provider.debugSetBackups([
      const WebDavFile(name: 'narrchat_library_shot-g1.db'),
    ]);
    await pumpPanel(
      tester,
      theme: NarrChatTheme.light,
      form: form,
      provider: provider,
    );

    final button = find.byTooltip('下载并恢复此版本');
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();

    expect(find.text('用这个备份覆盖本地？'), findsOneWidget);
    expect(find.textContaining('整份替换本地'), findsOneWidget);

    await tester.tap(find.text('替换'));
    await tester.pumpAndSettle();

    expect(find.textContaining('处理失败'), findsOneWidget);
    await flushNotices(tester);
  });

  testWidgets('点击快照后取消：不调用还原', (tester) async {
    final provider = CloudSyncProvider();
    final form = makeForm(provider: provider);
    provider.debugSetBackups([
      const WebDavFile(name: 'narrchat_mods_shot-g1.db'),
    ]);
    await pumpPanel(
      tester,
      theme: NarrChatTheme.light,
      form: form,
      provider: provider,
    );

    final button = find.byTooltip('下载并恢复此版本');
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(find.text('用这个备份覆盖本地？'), findsNothing);
    expect(find.textContaining('处理失败'), findsNothing);
  });

  // ---------------------------------------------------------------------------
  // 「保留历史版本」展示框（点击弹窗修改，值保存在云端 sync_config.json）
  // ---------------------------------------------------------------------------

  testWidgets('保留历史版本是只读展示框：非 TextField，未连接显示 —', (tester) async {
    final provider = CloudSyncProvider();
    final form = makeForm(provider: provider);
    await pumpPanel(tester, theme: NarrChatTheme.light, form: form, provider: provider);

    // 连接设置卡只剩 4 个可编辑输入框（服务器 / 用户名 / 密码 / 文件夹）。
    expect(find.byType(TextField), findsNWidgets(4));
    expect(find.text('—'), findsOneWidget, reason: '未连接 / 未读到云端值时展示占位');
    expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
  });

  testWidgets('未连接点击展示框：只弹悬浮通知，不打开弹窗也不联网', (tester) async {
    final provider = CloudSyncProvider();
    final form = makeForm(provider: provider);
    await pumpPanel(tester, theme: NarrChatTheme.light, form: form, provider: provider);

    await tester.tap(find.text('—'));
    await tester.pump();

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('请先保存 WebDAV 连接配置后再修改'), findsOneWidget);
    await flushNotices(tester);
  });

  testWidgets('已连接且已读到云端值：展示框显示该数字，点击打开弹窗', (tester) async {
    final provider = CloudSyncProvider()
      ..debugSetConfigured(value: true)
      ..debugSetKeepVersions(8);
    final form = makeForm(provider: provider);
    await pumpPanel(tester, theme: NarrChatTheme.light, form: form, provider: provider);

    expect(find.text('8'), findsWidgets, reason: '状态卡与展示框都显示云端值');

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget, reason: '点击打开修改弹窗');
  });
}
