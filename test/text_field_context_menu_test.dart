import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/widgets/text_field_context_menu.dart';

import 'helpers/fakes.dart';

/// 隔离层测试：可复用的 [pasteIntoTextInput] 逻辑。
///
/// 覆盖文本插入（含选区替换 / 无效选区追加）、识图门控、非识图提示、超限提示，
/// 不触碰真实剪贴板 / 文件系统（用 [FakeClipboardPasteService] 注入）。
void main() {
  test('文本插入光标处（替换选区）', () async {
    final controller = TextEditingController(text: '前缀 后缀');
    // 以「空格」下标 2..3 构造一个选区（替换该空格）。
    controller.selection = const TextSelection(baseOffset: 2, extentOffset: 3);
    final added = <String>[];
    await pasteIntoTextInput(
      service: FakeClipboardPasteService(text: '插入'),
      controller: controller,
      acceptImages: false,
      imageSizeLimitMb: 16,
      convertJpgToJpeg: false,
      onImageAdded: added.add,
    );
    expect(controller.text, '前缀插入后缀');
    expect(controller.selection.baseOffset, controller.selection.extentOffset);
    expect(added, isEmpty);
  });

  test('选区无效时追加到末尾', () async {
    final controller = TextEditingController(text: 'abc');
    controller.selection = const TextSelection.collapsed(offset: -1); // 无效
    await pasteIntoTextInput(
      service: FakeClipboardPasteService(text: '末尾'),
      controller: controller,
      acceptImages: false,
      imageSizeLimitMb: 16,
      convertJpgToJpeg: false,
      onImageAdded: (_) {},
    );
    expect(controller.text, 'abc末尾');
  });

  test('识图模型：图片加入附件列表', () async {
    final controller = TextEditingController();
    final added = <String>[];
    String? notice;
    await pasteIntoTextInput(
      service: FakeClipboardPasteService(
        imagePng: Uint8List.fromList([0, 1, 2]),
      ),
      controller: controller,
      acceptImages: true,
      imageSizeLimitMb: 16,
      convertJpgToJpeg: false,
      onImageAdded: added.add,
      onNotice: (m) => notice = m,
    );
    expect(added, ['img/pasted.png']);
    expect(notice, isNull);
  });

  test('非识图模型：图片给出提示，不加附件', () async {
    final added = <String>[];
    String? notice;
    await pasteIntoTextInput(
      service: FakeClipboardPasteService(
        imagePng: Uint8List.fromList([0, 1, 2]),
      ),
      controller: TextEditingController(),
      acceptImages: false,
      imageSizeLimitMb: 16,
      convertJpgToJpeg: false,
      onImageAdded: added.add,
      onNotice: (m) => notice = m,
    );
    expect(added, isEmpty);
    expect(notice, contains('不支持识图'));
  });

  test('图片超限：给出提示，不加附件', () async {
    final added = <String>[];
    String? notice;
    await pasteIntoTextInput(
      service: FakeClipboardPasteService(
        imageWarning: '剪贴板图片超过 16MB，请压缩后重试。',
      ),
      controller: TextEditingController(),
      acceptImages: true,
      imageSizeLimitMb: 16,
      convertJpgToJpeg: false,
      onImageAdded: added.add,
      onNotice: (m) => notice = m,
    );
    expect(added, isEmpty);
    expect(notice, contains('超过'));
  });
}
