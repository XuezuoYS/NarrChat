import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/providers/cloud_sync_provider.dart';
import 'package:narrchat/screens/book_recycle_bin_page.dart';
import 'package:narrchat/services/cloud_backup/backup_catalog.dart';
import 'package:narrchat/services/webdav_service.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:provider/provider.dart';

import 'helpers/notice_harness.dart';

/// 书籍回收站页：一行一本已删书 + 还原 / 彻底删除。
void main() {
  /// 打开页面（从宿主路由 push，方便断言还原成功后自动返回）。
  Future<void> pumpPage(
    WidgetTester tester, {
    required CloudSyncProvider provider,
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
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => BookRecycleBinPage.open(context),
                  child: const Text('打开回收站'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('打开回收站'));
    await tester.pumpAndSettle();
  }

  void setEntries(CloudSyncProvider provider) {
    provider.debugSetBackups(
      [
        const WebDavFile(name: 'narrbook_b0_shot-g1.db'),
        const WebDavFile(name: 'narrbook_b1_shot-g2.db'),
      ],
      bookTitles: const {'b0': '书零', 'b1': '书一'},
      deletedBooks: {
        'b0': BackupDeletedBook(
          deletedAt: DateTime(2026, 11, 6, 10),
          roundIndex: 3,
        ),
        'b1': BackupDeletedBook(
          deletedAt: DateTime(2026, 11, 7, 16, 50),
          roundIndex: 12,
        ),
      },
    );
  }

  testWidgets('行内容：书名 / UUID / 删除时间 + 轮次，按删除时间新 → 旧', (tester) async {
    final provider = CloudSyncProvider();
    setEntries(provider);
    await pumpPage(tester, provider: provider);

    expect(find.text('共 2 本已删除的书'), findsOneWidget);
    expect(find.text('书一'), findsOneWidget);
    expect(find.text('UUID：b1'), findsOneWidget);
    expect(find.text('删除于 2026-11-07 16:50 · 第 12 轮'), findsOneWidget);
    expect(find.text('书零'), findsOneWidget);
    expect(find.text('UUID：b0'), findsOneWidget);
    expect(find.text('删除于 2026-11-06 10:00 · 第 3 轮'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('书一')).dy,
      lessThan(tester.getTopLeft(find.text('书零')).dy),
      reason: '最近删除的排前面',
    );
  });

  testWidgets('轮次缺失 / 为 0 的文案', (tester) async {
    final provider = CloudSyncProvider();
    provider.debugSetBackups(
      [
        const WebDavFile(name: 'narrbook_old_shot-g1.db'),
        const WebDavFile(name: 'narrbook_new_shot-g2.db'),
      ],
      bookTitles: const {'old': '老墓碑', 'new': '空书'},
      deletedBooks: {
        'old': BackupDeletedBook(
          deletedAt: DateTime(2026, 11, 6, 10),
          roundIndex: null,
        ),
        'new': BackupDeletedBook(
          deletedAt: DateTime(2026, 11, 7, 10),
          roundIndex: 0,
        ),
      },
    );
    await pumpPage(tester, provider: provider);

    expect(find.text('删除于 2026-11-07 10:00 · 尚无轮次'), findsOneWidget);
    expect(find.text('删除于 2026-11-06 10:00 · 轮次未知'), findsOneWidget);
  });

  testWidgets('空态：没有可展示的已删书', (tester) async {
    final provider = CloudSyncProvider()..debugSetBackups(const []);
    await pumpPage(tester, provider: provider);

    expect(find.textContaining('回收站是空的'), findsOneWidget);
    expect(find.text('书籍回收站'), findsOneWidget);
  });

  testWidgets('点行打开管理弹窗：详情 + 还原 / 彻底删除', (tester) async {
    final provider = _SpyProvider();
    setEntries(provider);
    await pumpPage(tester, provider: provider);

    await tester.tap(find.text('书一'));
    await tester.pumpAndSettle();
    expect(find.text('管理「书一」'), findsOneWidget);
    expect(find.text('b1'), findsOneWidget);
    expect(find.text('第 12 轮'), findsOneWidget);
    expect(find.text('还原此书'), findsOneWidget);
    expect(find.text('彻底删除'), findsOneWidget);

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('管理「书一」'), findsNothing);
    expect(provider.restoredEntry, isNull);
    expect(provider.purgedEntry, isNull);
  });

  testWidgets('还原成功：调用 provider 并返回列表', (tester) async {
    final provider = _SpyProvider();
    setEntries(provider);
    await pumpPage(tester, provider: provider);

    await tester.tap(find.text('书一'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('还原此书'));
    await tester.pumpAndSettle();

    expect(provider.restoredEntry?.unit.refUuid, 'b1');
    expect(find.text('打开回收站'), findsOneWidget, reason: '成功后退回上一页');
    expect(find.text('书籍回收站'), findsNothing);
  });

  testWidgets('还原失败：留在本页并提示原因', (tester) async {
    final provider = _SpyProvider()..nextError = '磁盘被占用';
    setEntries(provider);
    await pumpPage(tester, provider: provider);

    await tester.tap(find.text('书一'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('还原此书'));
    await tester.pumpAndSettle();

    expect(provider.restoredEntry?.unit.refUuid, 'b1');
    expect(find.text('还原失败：磁盘被占用'), findsOneWidget);
    expect(find.text('书籍回收站'), findsOneWidget);
    await flushNotices(tester);
  });

  testWidgets('彻底删除：二次确认；取消不调用，确认才调用', (tester) async {
    final provider = _SpyProvider();
    setEntries(provider);
    await pumpPage(tester, provider: provider);

    // 第一次：管理弹窗 → 彻底删除 → 确认框取消。
    await tester.tap(find.text('书一'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, '彻底删除'));
    await tester.pumpAndSettle();
    expect(find.text('彻底删除这本书的备份？'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(provider.purgedEntry, isNull);
    expect(find.text('书籍回收站'), findsOneWidget);

    // 第二次：确认后才真正调用。
    await tester.tap(find.text('书一'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, '彻底删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '彻底删除'));
    await tester.pumpAndSettle();

    expect(provider.purgedEntry?.unit.refUuid, 'b1');
    expect(find.text('已彻底删除《书一》的云端备份'), findsOneWidget);
    expect(find.text('书籍回收站'), findsOneWidget, reason: '成功后留在本页');
    await flushNotices(tester);
  });

  testWidgets('彻底删除失败：提示原因并留在本页', (tester) async {
    final provider = _SpyProvider()..nextError = '云端不可用';
    setEntries(provider);
    await pumpPage(tester, provider: provider);

    await tester.tap(find.text('书一'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, '彻底删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '彻底删除'));
    await tester.pumpAndSettle();

    expect(provider.purgedEntry?.unit.refUuid, 'b1');
    expect(find.text('彻底删除失败：云端不可用'), findsOneWidget);
    expect(find.text('书籍回收站'), findsOneWidget);
    await flushNotices(tester);
  });

  testWidgets('窄屏(320)：长书名 / 长 uuid 不溢出', (tester) async {
    final provider = CloudSyncProvider();
    const uuid = 'abcdef12-3456-7890-abcd-ef1234567890';
    provider.debugSetBackups(
      [const WebDavFile(name: 'narrbook_${uuid}_shot-g1.db')],
      bookTitles: const {uuid: '一个特别特别特别特别特别长的书名'},
      deletedBooks: {
        uuid: BackupDeletedBook(
          deletedAt: DateTime(2026, 11, 7, 16, 50),
          roundIndex: 123,
        ),
      },
    );
    await pumpPage(tester, provider: provider, width: 320);

    expect(find.text('一个特别特别特别特别特别长的书名'), findsOneWidget);
    expect(find.text('UUID：$uuid'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

/// 只覆盖回收站动作的替身：不联网也不碰真实仓储。
class _SpyProvider extends CloudSyncProvider {
  _SpyProvider();

  BackupUnitEntry? restoredEntry;
  BackupUnitEntry? purgedEntry;
  String? nextError;

  @override
  Future<String?> restoreDeletedBook(BackupUnitEntry entry) async {
    restoredEntry = entry;
    return nextError;
  }

  @override
  Future<String?> permanentlyDeleteDeletedBook(BackupUnitEntry entry) async {
    purgedEntry = entry;
    return nextError;
  }
}
