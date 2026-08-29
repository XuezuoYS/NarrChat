import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/providers/cloud_sync_provider.dart';
import 'package:narrchat/services/clipboard_image_service.dart';
import 'package:narrchat/services/sync/image_deletion.dart';
import 'package:narrchat/widgets/image_preview.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import 'helpers/fakes.dart';

/// 查看器共享动作测试：复制图片（剪贴板写入）、另存为（路径选择 + 跨平台落盘分支）、
/// 删除（二次确认 + 删除服务 + 回调）、操作菜单（右键/长按入口的菜单项与动作路由）。
///
/// 直接构造宿主页面触发动作函数（与应用内查看器共用同一套共享逻辑），
/// 确认对话框 / 菜单均在 MaterialApp 的 Navigator/Overlay 上完成。
void main() {
  // 每个用例独立的临时目录（真实文件 IO 用例共用；用例间互不残留）。
  late Directory tempDir;
  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('img_viewer_actions_');
  });
  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Widget buildHost({
    required Future<void> Function(BuildContext context) onPressed,
    ImageDeletionService? deletion,
  }) {
    return MultiProvider(
      providers: [
        Provider<ImageDeletionService>.value(
          value: deletion ?? FakeImageDeletionService(),
        ),
        // 删除后触发自动同步（未配置时内部忽略）。
        ChangeNotifierProvider.value(value: CloudSyncProvider()),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: TextButton(
                onPressed: () => onPressed(ctx),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('复制图片：文件存在时字节写入剪贴板并提示', (tester) async {
    final file = File(p.join(tempDir.path, 'pic.png'))
      ..writeAsBytesSync([1, 2, 3]);
    final writer = _FakeClipboardWriter();
    await tester.pumpWidget(buildHost(
      onPressed: (ctx) => copyImageFile(
        ctx,
        relPath: 'img/pic.png',
        absPath: file.path,
        writer: writer,
      ),
    ));

    // 真实文件读取需在 runAsync 中完成（FakeAsync 不推进真实 IO）。
    await tester.runAsync(() async {
      await tester.tap(find.text('go'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pumpAndSettle();

    expect(writer.writtenPath, file.path); // 原始文件路径透传（供 CF_HDROP）
    expect(writer.written?.toList(), [1, 2, 3]);
    expect(find.text('图片已复制到剪贴板'), findsOneWidget);
  });

  testWidgets('复制图片：文件缺失提示且不写剪贴板', (tester) async {
    final writer = _FakeClipboardWriter();
    await tester.pumpWidget(buildHost(
      onPressed: (ctx) => copyImageFile(
        ctx,
        relPath: 'img/missing.png',
        absPath: p.join(tempDir.path, 'missing.png'),
        writer: writer,
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(writer.written, isNull);
    expect(find.text('图片文件已丢失，无法复制'), findsOneWidget);
  });

  testWidgets('复制图片：剪贴板写入失败提示重试', (tester) async {
    final file = File(p.join(tempDir.path, 'pic.png'))
      ..writeAsBytesSync([9]);
    final writer = _FakeClipboardWriter(fail: true);
    await tester.pumpWidget(buildHost(
      onPressed: (ctx) => copyImageFile(
        ctx,
        relPath: 'img/pic.png',
        absPath: file.path,
        writer: writer,
      ),
    ));
    await tester.runAsync(() async {
      await tester.tap(find.text('go'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pumpAndSettle();
    expect(find.text('复制失败，请重试'), findsOneWidget);
  });

  testWidgets('另存为图片：Windows 选择路径后复制原文件并提示路径', (tester) async {
    final src = File(p.join(tempDir.path, 'pic.png'))
      ..writeAsBytesSync([1, 2, 3]);
    final target = p.join(tempDir.path, 'saved.png');
    final picker = _FakeSavePicker(outPath: target);
    await tester.pumpWidget(buildHost(
      onPressed: (ctx) => saveImageFile(
        ctx,
        relPath: 'img/pic.png',
        absPath: src.path,
        savePicker: picker.pick,
        needsNativeBytes: () => false,
      ),
    ));
    await tester.runAsync(() async {
      await tester.tap(find.text('go'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pumpAndSettle();

    expect(picker.requestedFileName, 'pic.png'); // 原图文件名作为保存对话框预填名。
    expect(picker.requestedBytes, isNull); // Windows 不传字节（原生不落盘）。
    expect(File(target).readAsBytesSync().toList(), [1, 2, 3]); // Dart 侧复制到目标。
    expect(find.text('已保存到 $target'), findsOneWidget);
  });

  testWidgets('另存为图片：Android 传字节由原生 SAF 写入并提示成功', (tester) async {
    final src = File(p.join(tempDir.path, 'pic.png'))
      ..writeAsBytesSync([1, 2, 3]);
    // 插件返回的是拼装的展示路径（真实文件由原生 SAF 写入，Dart 侧不复制）。
    final displayPath = p.join(tempDir.path, 'fake_display.png');
    final picker = _FakeSavePicker(outPath: displayPath);
    await tester.pumpWidget(buildHost(
      onPressed: (ctx) => saveImageFile(
        ctx,
        relPath: 'img/pic.png',
        absPath: src.path,
        savePicker: picker.pick,
        needsNativeBytes: () => true,
      ),
    ));
    await tester.runAsync(() async {
      await tester.tap(find.text('go'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pumpAndSettle();

    expect(picker.requestedBytes?.toList(), [1, 2, 3]); // 字节交给原生 SAF 写入。
    expect(File(displayPath).existsSync(), isFalse); // Dart 侧不再复制。
    expect(find.text('图片已保存'), findsOneWidget);
  });

  testWidgets('另存为图片：用户取消对话框不提示且不复制', (tester) async {
    final src = File(p.join(tempDir.path, 'pic.png'))
      ..writeAsBytesSync([7]);
    final picker = _FakeSavePicker(outPath: null); // 取消。
    await tester.pumpWidget(buildHost(
      onPressed: (ctx) => saveImageFile(
        ctx,
        relPath: 'img/pic.png',
        absPath: src.path,
        savePicker: picker.pick,
        needsNativeBytes: () => false,
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    expect(find.text('图片已保存'), findsNothing);
    expect(find.textContaining('已保存到'), findsNothing);
    expect(find.text('保存失败，请重试'), findsNothing);
  });

  testWidgets('另存为图片：对话框异常提示保存失败', (tester) async {
    final src = File(p.join(tempDir.path, 'pic.png'))
      ..writeAsBytesSync([7]);
    final picker = _FakeSavePicker(error: true);
    await tester.pumpWidget(buildHost(
      onPressed: (ctx) => saveImageFile(
        ctx,
        relPath: 'img/pic.png',
        absPath: src.path,
        savePicker: picker.pick,
        needsNativeBytes: () => false,
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('保存失败，请重试'), findsOneWidget);
  });

  testWidgets('另存为图片：Windows 复制失败提示保存失败', (tester) async {
    final src = File(p.join(tempDir.path, 'pic.png'))
      ..writeAsBytesSync([7]);
    // 目标父目录不存在 → file.copy 抛异常。
    final picker = _FakeSavePicker(
      outPath: p.join(tempDir.path, 'no_such_dir', 'saved.png'),
    );
    await tester.pumpWidget(buildHost(
      onPressed: (ctx) => saveImageFile(
        ctx,
        relPath: 'img/pic.png',
        absPath: src.path,
        savePicker: picker.pick,
        needsNativeBytes: () => false,
      ),
    ));
    await tester.runAsync(() async {
      await tester.tap(find.text('go'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pumpAndSettle();
    expect(find.text('保存失败，请重试'), findsOneWidget);
  });

  testWidgets('另存为图片：文件缺失提示无法保存', (tester) async {
    final picker = _FakeSavePicker();
    await tester.pumpWidget(buildHost(
      onPressed: (ctx) => saveImageFile(
        ctx,
        relPath: 'img/missing.png',
        absPath: p.join(tempDir.path, 'missing.png'),
        savePicker: picker.pick,
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(picker.requestedFileName, isNull); // 未进入保存对话框。
    expect(find.text('图片文件已丢失，无法保存'), findsOneWidget);
  });

  testWidgets('删除图片：取消确认则不删除', (tester) async {
    final deletion = FakeImageDeletionService();
    await tester.pumpWidget(buildHost(
      onPressed: (ctx) => deleteImageFile(ctx, relPath: 'img/a.png'),
      deletion: deletion,
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('删除图片'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(deletion.calls, 0);
    expect(find.text('已删除'), findsNothing);
  });

  testWidgets('删除图片：确认后调用删除服务并回调', (tester) async {
    final deletion = FakeImageDeletionService();
    var onDeletedCall = 0;
    await tester.pumpWidget(buildHost(
      onPressed: (ctx) => deleteImageFile(
        ctx,
        relPath: 'img/a.png',
        onDeleted: () => onDeletedCall++,
      ),
      deletion: deletion,
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除').last);
    await tester.pumpAndSettle();
    expect(deletion.deleted, ['img/a.png']);
    expect(onDeletedCall, 1);
    expect(find.text('已删除'), findsOneWidget);
  });

  testWidgets('删除图片：删除服务失败提示且不回调', (tester) async {
    await tester.pumpWidget(buildHost(
      onPressed: (ctx) => deleteImageFile(ctx, relPath: 'img/a.png'),
      deletion: _FailingDeletionService(),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除').last);
    await tester.pumpAndSettle();
    expect(find.text('删除失败，请重试'), findsOneWidget);
  });

  testWidgets('菜单：展示三个动作，选中删除进入二次确认', (tester) async {
    await tester.pumpWidget(buildHost(
      onPressed: (ctx) => showImageViewerMenu(
        ctx,
        relPath: 'img/a.png',
        absPath: null,
        globalPosition: const Offset(40, 40),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('另存为'), findsOneWidget);
    expect(find.text('复制图片'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);

    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('删除图片'), findsOneWidget); // 二次确认对话框
  });

  testWidgets('菜单：Android 不展示复制图片（仅另存为 / 删除）', (tester) async {
    // 测试宿主为 Windows，用 canCopyImage 注入口模拟 Android 平台判定。
    await tester.pumpWidget(buildHost(
      onPressed: (ctx) => showImageViewerMenu(
        ctx,
        relPath: 'img/a.png',
        absPath: null,
        globalPosition: const Offset(40, 40),
        canCopyImage: () => false,
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('另存为'), findsOneWidget);
    expect(find.text('复制图片'), findsNothing);
    expect(find.text('删除'), findsOneWidget);

    await tester.tap(find.text('删除')); // 删除入口仍可用。
    await tester.pumpAndSettle();
    expect(find.text('删除图片'), findsOneWidget);
  });
}

/// 剪贴板图片写入替身：记录写入的文件路径与字节，可注入失败。
class _FakeClipboardWriter implements ClipboardImageWriter {
  _FakeClipboardWriter({this.fail = false});

  final bool fail;
  String? writtenPath;
  Uint8List? written;

  @override
  Future<void> writeImage({
    required String absPath,
    required Uint8List bytes,
  }) async {
    if (fail) throw Exception('write failed');
    writtenPath = absPath;
    written = bytes;
  }
}

/// 另存为对话框替身：记录文件名与字节参数，可返回路径 / null（取消）/ 抛异常。
class _FakeSavePicker {
  _FakeSavePicker({this.outPath, this.error = false});

  final String? outPath;
  final bool error;
  String? requestedFileName;
  Uint8List? requestedBytes;

  Future<String?> pick({required String fileName, Uint8List? bytes}) async {
    requestedFileName = fileName;
    requestedBytes = bytes;
    if (error) throw Exception('save failed');
    return outPath;
  }
}

/// 删除失败替身（模拟磁盘 / 墓碑写入异常）。
class _FailingDeletionService implements ImageDeletionService {
  @override
  Future<void> delete(String relPath) async => throw Exception('boom');
}
