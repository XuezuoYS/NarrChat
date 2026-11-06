import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/screens/debug_files_screen.dart';
import 'package:narrchat/screens/debug_screen.dart';
import 'package:narrchat/services/debug_database_service.dart';
import 'package:narrchat/services/debug_file_service.dart';
import 'package:narrchat/services/update_check_service.dart';
import 'package:narrchat/theme/app_theme.dart';

import 'helpers/fakes.dart';
import 'helpers/notice_harness.dart';

const GitHubRelease _release = GitHubRelease(
  tagVersion: 'v1.4.0',
  displayName: 'NarrChat 1.4.0',
  pageUrl: 'https://github.com/XuezuoYS/NarrChat/releases/tag/v1.4.0',
  notes: '## 更新内容\n- 新功能',
  publishedAt: '2026-01-01T00:00:00Z',
);

const String _probeItemLabel = '触发检查到更新的提示框（即使版本相同或更旧也触发）';

/// R3 起版本是"按库逐个看"，不再有单一数据库版本入口。
const String _versionItemLabel = '查看各数据库版本';

/// 读版本就抛错的服务替身（模拟库被占用 / 损坏）。
class _ThrowingDebugDatabaseService extends FakeDebugDatabaseService {
  @override
  Future<List<DebugDbInfo>> listDatabases() async {
    throw StateError('数据库已被占用');
  }
}

Future<void> _pumpDebugScreen(
  WidgetTester tester,
  FakeUpdateCheckService service, {
  DebugDatabaseService? dbService,
  DebugFileService? fileService,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: NarrChatTheme.light,
      builder: floatingNoticeBuilder(),
      home: DebugScreen(
        updateService: service,
        databaseService: dbService ?? FakeDebugDatabaseService(),
        fileService: fileService ?? FakeDebugFileService(),
      ),
    ),
  );
}

/// 点击「触发检查到更新的提示框」入口。
Future<void> _tapProbeItem(WidgetTester tester) async {
  final target = find.text(_probeItemLabel);
  expect(target, findsOneWidget);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

/// 点击「查看各数据库版本」入口。
Future<void> _tapVersionItem(WidgetTester tester) async {
  final target = find.text(_versionItemLabel);
  expect(target, findsOneWidget);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('强制触发：以 forceShow 发起检查并弹出「发现新版本」对话框', (tester) async {
    final service = FakeUpdateCheckService([UpdateAvailable(_release)]);
    await _pumpDebugScreen(tester, service);

    await _tapProbeItem(tester);

    // 调试入口必须绕过版本比较：无论本地版本比远端新/旧都强制展示。
    expect(service.calls, 1);
    expect(service.forceShowValues, [true]);
    expect(service.checkedVersions, hasLength(1));
    expect(find.text('发现新版本'), findsOneWidget);
    expect(find.textContaining('v1.4.0 已发布'), findsOneWidget);
    expect(find.textContaining('当前版本'), findsOneWidget);
  });

  testWidgets('检查失败：悬浮通知提示原因，不弹对话框', (tester) async {
    final service = FakeUpdateCheckService([const CheckFailed('网络请求失败：boom')]);
    await _pumpDebugScreen(tester, service);

    await _tapProbeItem(tester);

    expect(service.forceShowValues, [true]);
    expect(find.text('发现新版本'), findsNothing);
    expect(find.text('检查更新失败：网络请求失败：boom'), findsOneWidget);
    await flushNotices(tester);
  });

  testWidgets('仓库无发布：悬浮通知提示未获取到发布信息', (tester) async {
    final service = FakeUpdateCheckService([const NoRelease()]);
    await _pumpDebugScreen(tester, service);

    await _tapProbeItem(tester);

    expect(service.forceShowValues, [true]);
    expect(find.text('发现新版本'), findsNothing);
    expect(find.text('未获取到 GitHub 发布信息'), findsOneWidget);
    await flushNotices(tester);
  });

  testWidgets('查看数据库版本：按库列出实际版本，版本不符时标出期望值', (tester) async {
    final service = FakeUpdateCheckService([const NoRelease()]);
    final dbService = FakeDebugDatabaseService()
      ..databases = const [
        DebugDbInfo(
          id: 'library',
          label: '书籍目录库',
          path: '/x/narrchat_library.db',
          expectedVersion: 22,
          actualVersion: 22,
          sizeBytes: 10,
          exists: true,
        ),
        DebugDbInfo(
          id: 'book:b1',
          label: '书 b1',
          path: '/x/books/narrbook_b1.db',
          expectedVersion: 22,
          actualVersion: 20,
          sizeBytes: 20,
          exists: true,
        ),
        DebugDbInfo(
          id: 'sync',
          label: '本地同步库',
          path: '/x/local_db/sync.db',
          expectedVersion: 1,
          actualVersion: 0,
          sizeBytes: 0,
          exists: false,
        ),
      ];
    await _pumpDebugScreen(tester, service, dbService: dbService);

    await _tapVersionItem(tester);

    expect(find.text('数据库版本'), findsOneWidget);
    expect(find.textContaining('3.0 起数据分成多个库文件'), findsOneWidget);
    // 版本一致：只显示实际版本。
    expect(find.text('书籍目录库：22'), findsOneWidget);
    // 版本落后：标出期望值。
    expect(find.text('书 b1：20（期望 22）'), findsOneWidget);
    // 文件不存在的库不展示。
    expect(find.textContaining('本地同步库'), findsNothing);
  });

  testWidgets('读取数据库版本失败：悬浮通知提示，不弹对话框', (tester) async {
    final service = FakeUpdateCheckService([const NoRelease()]);
    await _pumpDebugScreen(
      tester,
      service,
      dbService: _ThrowingDebugDatabaseService(),
    );

    await _tapVersionItem(tester);

    expect(find.text('数据库版本'), findsNothing);
    expect(find.text('读取数据库版本失败：Bad state: 数据库已被占用'), findsOneWidget);
    await flushNotices(tester);
  });

  testWidgets('查看全部数据文件：进入只读文件浏览页并列出根目录', (tester) async {
    final service = FakeUpdateCheckService([const NoRelease()]);
    final fileService = FakeDebugFileService(
      directories: {
        '': [
          debugFileEntry('user_data', isDirectory: true),
          debugFileEntry('local_config', isDirectory: true),
        ],
      },
    );
    await _pumpDebugScreen(tester, service, fileService: fileService);

    await tester.tap(find.text('查看全部数据文件（只读）'));
    await tester.pumpAndSettle();

    expect(find.byType(DebugFilesScreen), findsOneWidget);
    expect(fileService.listedPaths, ['']);
    expect(find.text('user_data'), findsOneWidget);
    expect(find.text('local_config'), findsOneWidget);
    // 旧的数据库结构入口已被替换，不应当还能看到。
    expect(find.text('查看数据库结构、内容和表（可切换库）'), findsNothing);
  });
}
