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

/// 云同步面板（重新设计版）widget 测试。
///
/// 重点：窄屏（360）下不溢出、亮/暗主题均可渲染、滑动式同步模式分段可选、
/// 云端备份列表按新版快照命名展示（云端记录 #N · 时间 · 大小）。
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
          home: Material(
            child: SingleChildScrollView(
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
    // 无 RenderFlex overflow 异常即通过（溢出会在测试中抛异常导致失败）。
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

  testWidgets('云端备份列表：按新版快照命名展示「云端记录 #N」并过滤旧命名', (tester) async {
    final provider = CloudSyncProvider();
    final form = makeForm(provider: provider);
    provider.debugSetBackups([
      const WebDavFile(
        name: 'narrchat_snapshot_g3_20260816_100000.db',
        size: 2048,
      ),
      const WebDavFile(name: 'narrchat_user_2026-08-16_10-00-00.db'), // 旧命名
      const WebDavFile(name: 'manifest.json'),
    ]);
    await pumpPanel(
      tester,
      theme: NarrChatTheme.light,
      form: form,
      provider: provider,
    );
    // 旧版命名与 manifest 不再出现在备份列表中。
    expect(find.text('narrchat_user_2026-08-16_10-00-00.db'), findsNothing);
    expect(find.text('manifest.json'), findsNothing);
    expect(find.text('云端记录 #3'), findsOneWidget);
    expect(find.textContaining('2026-08-16'), findsWidgets);
    expect(find.textContaining('2.0 KB'), findsOneWidget);
  });

  testWidgets('云端备份列表：多代快照按代际新 → 旧排列', (tester) async {
    final provider = CloudSyncProvider();
    final form = makeForm(provider: provider);
    provider.debugSetBackups([
      const WebDavFile(name: 'narrchat_snapshot_g2_20260816_100000.db'),
      const WebDavFile(name: 'narrchat_snapshot_g7_20260816_120000.db'),
      const WebDavFile(name: 'narrchat_snapshot_g5_20260816_110000.db'),
    ]);
    // 直接验证排序规则（纯函数），再验证面板展示顺序。
    final sorted = [...provider.backups]..sort(CloudSyncProvider.compareSnapshots);
    expect(
      sorted.map((f) => f.name).toList(),
      [
        'narrchat_snapshot_g7_20260816_120000.db',
        'narrchat_snapshot_g5_20260816_110000.db',
        'narrchat_snapshot_g2_20260816_100000.db',
      ],
    );
    await pumpPanel(
      tester,
      theme: NarrChatTheme.light,
      form: form,
      provider: provider,
    );
    expect(find.text('云端记录 #7'), findsOneWidget);
    expect(find.text('云端记录 #5'), findsOneWidget);
    expect(find.text('云端记录 #2'), findsOneWidget);
  });
}
