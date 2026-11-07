import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/providers/ai_settings_provider.dart';
import 'package:narrchat/providers/cloud_sync_provider.dart';
import 'package:narrchat/services/cloud_backup/backup_catalog.dart';
import 'package:narrchat/services/sync/sync_models.dart';
import 'package:narrchat/services/webdav_service.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/cloud_sync_panel.dart';
import 'package:narrchat/widgets/settings_form_state.dart';
import 'package:provider/provider.dart';

import 'helpers/backup_fakes.dart';
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
            body: SingleChildScrollView(child: CloudSyncPanel(form: form)),
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
    await pumpPanel(
      tester,
      theme: NarrChatTheme.light,
      form: makeForm(),
      width: 320,
    );
    expect(find.text('云同步'), findsOneWidget);
  });

  testWidgets('超窄卡片(261)：连接操作行换行而不溢出', (tester) async {
    await pumpPanel(
      tester,
      theme: NarrChatTheme.light,
      form: makeForm(),
      width: 261,
    );
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

  testWidgets('进入面板即自动拉取云端「保留历史版本」，无需点开弹窗', (tester) async {
    final dav = FakeWebDavService(
      files: {
        'narrchat_library_shot-g3.db': [1, 2, 3, 4],
        'sync_config.json': utf8.encode('{"keepVersions":9}'),
      },
    );
    final provider = CloudSyncProvider(webDavFactory: () => dav)
      ..debugSetConfigured();
    final form = makeForm(provider: provider);
    await pumpPanel(
      tester,
      theme: NarrChatTheme.light,
      form: form,
      provider: provider,
    );
    await tester.pumpAndSettle();

    expect(provider.keepVersionsLoaded, isTrue);
    expect(find.text('9'), findsWidgets, reason: '状态卡与展示框都显示云端值');
    expect(find.text('Library 库'), findsOneWidget);
  });

  testWidgets('备份列表：按 Library / Mod / 书籍 分组，书名来自本地索引', (tester) async {
    final provider = CloudSyncProvider();
    final form = makeForm(provider: provider);
    provider.debugSetBackups(
      [
        const WebDavFile(name: 'narrbook_b1_shot-g1.db'),
        const WebDavFile(
          name: 'narrchat_library_shot-g3.db',
          size: 2048,
          lastModified: null,
        ),
        const WebDavFile(name: 'manifest_narrchat_library.json'),
      ],
      bookTitles: const {'b1': '深海余烬'},
    );
    await pumpPanel(
      tester,
      theme: NarrChatTheme.light,
      form: form,
      provider: provider,
    );

    expect(find.text('Library 库'), findsOneWidget);
    expect(find.text('书籍《深海余烬》库'), findsOneWidget);
    expect(find.text('Mod 库'), findsNothing, reason: '云端没有 mods 快照就不占位置');
    expect(find.text('第 3 代 · 时间未知 · 2.0 KB · 共 1 份'), findsOneWidget);
    // 清单文件不是快照，不展示成条目。
    expect(find.text('manifest_narrchat_library.json'), findsNothing);

    // 固定顺序：Library 在书籍上面。
    expect(
      tester.getTopLeft(find.text('Library 库')).dy,
      lessThan(tester.getTopLeft(find.text('书籍《深海余烬》库')).dy),
    );
  });

  testWidgets('备份列表：书籍按最新备份时间新 → 旧', (tester) async {
    final provider = CloudSyncProvider();
    final form = makeForm(provider: provider);
    provider.debugSetBackups(
      [
        WebDavFile(
          name: 'narrbook_old_shot-g1.db',
          lastModified: DateTime.utc(2026, 11, 1, 10),
        ),
        WebDavFile(
          name: 'narrbook_new_shot-g1.db',
          lastModified: DateTime.utc(2026, 11, 5, 10),
        ),
      ],
      bookTitles: const {'old': '旧书', 'new': '新书'},
    );
    await pumpPanel(
      tester,
      theme: NarrChatTheme.light,
      form: form,
      provider: provider,
    );

    expect(
      tester.getTopLeft(find.text('书籍《新书》库')).dy,
      lessThan(tester.getTopLeft(find.text('书籍《旧书》库')).dy),
      reason: '最近备份的排前面',
    );
  });

  testWidgets('列表末尾「已删除」：活书/墓碑分开，点进书籍回收站', (tester) async {
    final provider = CloudSyncProvider();
    final form = makeForm(provider: provider);
    provider.debugSetBackups(
      [
        const WebDavFile(name: 'narrbook_live_shot-g1.db'),
        WebDavFile(
          name: 'narrbook_gone_shot-g2.db',
          lastModified: DateTime.utc(2026, 11, 7, 16),
        ),
      ],
      bookTitles: const {'live': '活书', 'gone': '删书'},
      deletedBooks: {
        'gone': BackupDeletedBook(
          deletedAt: DateTime(2026, 11, 7, 16, 50),
          roundIndex: 12,
        ),
      },
    );
    await pumpPanel(
      tester,
      theme: NarrChatTheme.light,
      form: form,
      provider: provider,
    );

    expect(find.text('书籍《活书》库'), findsOneWidget);
    expect(find.text('书籍《删书》库'), findsNothing, reason: '墓碑书不进活书列表');
    expect(find.text('已删除'), findsOneWidget);
    expect(find.text('1 本书 · 点进去还原或彻底删除'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('已删除')).dy,
      greaterThan(tester.getTopLeft(find.text('书籍《活书》库')).dy),
      reason: '已删除入口在列表末尾',
    );

    await tester.ensureVisible(find.text('已删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('已删除'));
    await tester.pumpAndSettle();

    expect(find.text('书籍回收站'), findsOneWidget);
    expect(find.text('删书'), findsOneWidget);
    expect(find.text('UUID：gone'), findsOneWidget);
    expect(find.text('删除于 2026-11-07 16:50 · 第 12 轮'), findsOneWidget);
  });

  testWidgets('只有已删除条目：不显示「云端暂无备份」空态', (tester) async {
    final provider = CloudSyncProvider();
    final form = makeForm(provider: provider);
    provider.debugSetBackups(
      [const WebDavFile(name: 'narrbook_gone_shot-g2.db')],
      bookTitles: const {'gone': '删书'},
      deletedBooks: {
        'gone': BackupDeletedBook(deletedAt: DateTime(2026, 11, 7)),
      },
    );
    await pumpPanel(
      tester,
      theme: NarrChatTheme.light,
      form: form,
      provider: provider,
    );

    expect(find.textContaining('云端暂无备份'), findsNothing);
    expect(find.text('已删除'), findsOneWidget);
  });

  testWidgets('窄屏(261)：「已删除」入口渲染且不溢出', (tester) async {
    final provider = CloudSyncProvider();
    final form = makeForm(provider: provider);
    provider.debugSetBackups(
      [
        const WebDavFile(name: 'narrbook_abcdef12_shot-g1.db'),
        const WebDavFile(name: 'narrbook_gone_shot-g2.db'),
      ],
      bookTitles: const {'abcdef12': '一个特别特别特别特别特别长的书名', 'gone': '删掉的书'},
      deletedBooks: {
        'gone': BackupDeletedBook(
          deletedAt: DateTime(2026, 11, 7),
          roundIndex: 123,
        ),
      },
    );
    await pumpPanel(
      tester,
      theme: NarrChatTheme.light,
      form: form,
      provider: provider,
      width: 261,
    );

    expect(find.text('已删除'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: '不得出现 RenderFlex overflow');
  });

  testWidgets('窄屏(261)：分组条目渲染且不溢出', (tester) async {
    final provider = CloudSyncProvider();
    final form = makeForm(provider: provider);
    provider.debugSetBackups(
      [
        const WebDavFile(name: 'narrchat_library_shot-g3.db', size: 446464),
        const WebDavFile(
          name: 'narrbook_abcdef12-3456-7890-abcd-ef1234567890_shot-g1.db',
          size: 1024,
        ),
      ],
      bookTitles: const {
        'abcdef12-3456-7890-abcd-ef1234567890': '一个特别特别特别特别特别长的书名',
      },
    );
    await pumpPanel(
      tester,
      theme: NarrChatTheme.light,
      form: form,
      provider: provider,
      width: 261,
    );

    expect(find.text('书籍《一个特别特别特别特别特别长的书名》库'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: '不得出现 RenderFlex overflow');
  });

  testWidgets('点击库条目：进入二级页才看到该库全部代次', (tester) async {
    final provider = CloudSyncProvider();
    final form = makeForm(provider: provider);
    provider.debugSetBackups([
      const WebDavFile(name: 'narrchat_library_shot-g2.db'),
      const WebDavFile(name: 'narrchat_library_shot-g7.db'),
      const WebDavFile(name: 'narrchat_library_shot-g5.db'),
    ]);
    await pumpPanel(
      tester,
      theme: NarrChatTheme.light,
      form: form,
      provider: provider,
    );

    // 顶层只有一条「Library 库」，不铺代次列表。
    expect(find.text('Library 库'), findsOneWidget);
    expect(find.text('第 7 代'), findsNothing);
    expect(find.text('第 5 代'), findsNothing);

    final tile = find.text('Library 库');
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    await tester.tap(tile);
    await tester.pumpAndSettle();

    expect(find.text('共 3 代 · 最新第 7 代'), findsOneWidget);
    expect(find.text('第 7 代'), findsOneWidget);
    expect(find.text('第 5 代'), findsOneWidget);
    expect(find.text('第 2 代'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('第 7 代')).dy,
      lessThan(tester.getTopLeft(find.text('第 5 代')).dy),
    );
  });

  // ---------------------------------------------------------------------------
  // 「保留历史版本」展示框（点击弹窗修改，值保存在云端 sync_config.json）
  // ---------------------------------------------------------------------------

  testWidgets('保留历史版本是只读展示框：非 TextField，未连接显示 —', (tester) async {
    final provider = CloudSyncProvider();
    final form = makeForm(provider: provider);
    await pumpPanel(
      tester,
      theme: NarrChatTheme.light,
      form: form,
      provider: provider,
    );

    // 连接设置卡只剩 4 个可编辑输入框（服务器 / 用户名 / 密码 / 文件夹）。
    expect(find.byType(TextField), findsNWidgets(4));
    expect(find.text('—'), findsOneWidget, reason: '未连接 / 未读到云端值时展示占位');
    expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
  });

  testWidgets('未连接点击展示框：只弹悬浮通知，不打开弹窗也不联网', (tester) async {
    final provider = CloudSyncProvider();
    final form = makeForm(provider: provider);
    await pumpPanel(
      tester,
      theme: NarrChatTheme.light,
      form: form,
      provider: provider,
    );

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
    await pumpPanel(
      tester,
      theme: NarrChatTheme.light,
      form: form,
      provider: provider,
    );

    expect(find.text('8'), findsWidgets, reason: '状态卡与展示框都显示云端值');

    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget, reason: '点击打开修改弹窗');
  });
}
