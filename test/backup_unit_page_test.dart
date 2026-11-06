import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/providers/cloud_sync_provider.dart';
import 'package:narrchat/screens/backup_unit_page.dart';
import 'package:narrchat/services/cloud_backup/backup_catalog.dart';
import 'package:narrchat/services/webdav_service.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:provider/provider.dart';

import 'helpers/notice_harness.dart';

/// 云备份二级页：某个库的代次列表（新 → 旧）+ 整份还原。
void main() {
  /// 造一个库条目：输入乱序也行，catalog 会排好。
  BackupUnitEntry entryOf(
    List<WebDavFile> files, {
    Map<String, String> bookTitles = const {},
  }) {
    return BackupCatalog.build(files: files, bookTitles: bookTitles).single;
  }

  BackupUnitEntry libraryEntry() => entryOf([
        WebDavFile(
          name: 'narrchat_library_shot-g2.db',
          size: 2048,
          lastModified: DateTime(2026, 11, 1, 9, 5),
        ),
        WebDavFile(
          name: 'narrchat_library_shot-g7.db',
          size: 446464,
          lastModified: DateTime(2026, 11, 6, 22, 8),
        ),
        WebDavFile(
          name: 'narrchat_library_shot-g5.db',
          lastModified: DateTime(2026, 11, 3, 12),
        ),
      ]);

  Future<void> pumpPage(
    WidgetTester tester, {
    required CloudSyncProvider provider,
    required BackupUnitEntry target,
    double width = 420,
  }) async {
    tester.view.physicalSize = Size(width, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<CloudSyncProvider>.value(
        value: provider,
        child: MaterialApp(
          theme: NarrChatTheme.light,
          builder: floatingNoticeBuilder(),
          home: BackupUnitPage(entry: target),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('代次新 → 旧展示：代数 / 时间 / 大小 / 最新徽章', (tester) async {
    await pumpPage(
      tester,
      provider: CloudSyncProvider(),
      target: libraryEntry(),
    );

    expect(find.text('共 3 代 · 最新第 7 代'), findsOneWidget);
    expect(find.text('最新备份：2026-11-06 22:08 · 436.0 KB'), findsOneWidget);
    expect(find.text('2026-11-06 22:08 · 436.0 KB'), findsOneWidget);
    expect(find.text('第 7 代'), findsOneWidget);
    expect(find.text('第 5 代'), findsOneWidget);
    expect(find.text('第 2 代'), findsOneWidget);
    expect(find.text('最新'), findsOneWidget);

    final y7 = tester.getTopLeft(find.text('第 7 代')).dy;
    final y5 = tester.getTopLeft(find.text('第 5 代')).dy;
    final y2 = tester.getTopLeft(find.text('第 2 代')).dy;
    expect(y7 < y5 && y5 < y2, isTrue, reason: '最新一代排最上面');
  });

  testWidgets('书籍库用《书名》：标题与还原确认都用友好名', (tester) async {
    final spy = _SpyProvider();
    final target = entryOf(
      [const WebDavFile(name: 'narrbook_b1_shot-g1.db')],
      bookTitles: const {'b1': '深海余烬'},
    );
    await pumpPage(tester, provider: spy, target: target);

    expect(find.text('书籍《深海余烬》库'), findsWidgets);

    await tester.tap(find.byTooltip('下载并恢复此版本').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('书籍《深海余烬》库 · 第 1 代'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });

  testWidgets('确认还原：调用 restoreSnapshot 并提示成功', (tester) async {
    final spy = _SpyProvider();
    await pumpPage(tester, provider: spy, target: libraryEntry());

    await tester.tap(find.byTooltip('下载并恢复此版本').first);
    await tester.pumpAndSettle();
    expect(find.text('用这个备份覆盖本地？'), findsOneWidget);

    await tester.tap(find.text('替换'));
    await tester.pumpAndSettle();

    expect(spy.restoredName, 'narrchat_library_shot-g7.db');
    expect(spy.restoredLabel, 'Library 库');
    expect(find.text('已用第 7 代覆盖本地数据'), findsOneWidget);
    await flushNotices(tester);
  });

  testWidgets('取消还原：不调用 restoreSnapshot', (tester) async {
    final spy = _SpyProvider();
    await pumpPage(tester, provider: spy, target: libraryEntry());

    await tester.tap(find.byTooltip('下载并恢复此版本').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(spy.restoredName, isNull);
    expect(find.textContaining('处理失败'), findsNothing);
  });

  testWidgets('还原失败：显示失败原因', (tester) async {
    final spy = _SpyProvider()..nextError = '磁盘被占用';
    await pumpPage(tester, provider: spy, target: libraryEntry());

    await tester.tap(find.byTooltip('下载并恢复此版本').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('替换'));
    await tester.pumpAndSettle();

    expect(spy.restoredName, 'narrchat_library_shot-g7.db');
    expect(find.text('处理失败：磁盘被占用'), findsOneWidget);
    await flushNotices(tester);
  });

  testWidgets('同步进行中：还原按钮禁用', (tester) async {
    final provider = CloudSyncProvider()..debugSetLaneBusy(true);
    await pumpPage(tester, provider: provider, target: libraryEntry());

    final button = tester.widget<IconButton>(
      find
          .ancestor(
            of: find.byIcon(Icons.cloud_download_outlined).first,
            matching: find.byType(IconButton),
          )
          .first,
    );
    expect(button.onPressed, isNull);
  });
}

/// 还原结果可编排的替身：只覆盖 [restoreSnapshot]，不联网也不碰真实仓储。
class _SpyProvider extends CloudSyncProvider {
  _SpyProvider();

  String? restoredName;
  String? restoredLabel;
  String? nextError;

  @override
  Future<String?> restoreSnapshot(String snapshotName, {String? label}) async {
    restoredName = snapshotName;
    restoredLabel = label;
    return nextError;
  }
}
