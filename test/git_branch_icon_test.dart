import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/widgets/git_branch_icon.dart';

/// [GitBranchIcon] 的口径：
/// - 尺寸 / 颜色默认跟随 [IconTheme]（和 [Icon] 一样可被按钮、菜单统一着色）；
/// - 显式传值优先；
/// - 只有颜色变化才需要重绘。
GitBranchPainter _painterOf(WidgetTester tester) {
  final paint = tester.widget<CustomPaint>(
    find.descendant(
      of: find.byType(GitBranchIcon),
      matching: find.byType(CustomPaint),
    ),
  );
  return paint.painter! as GitBranchPainter;
}

void main() {
  testWidgets('尺寸与颜色默认跟随 IconTheme', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: IconTheme(
            data: IconThemeData(size: 21, color: Color(0xFF123456)),
            child: GitBranchIcon(),
          ),
        ),
      ),
    );

    expect(tester.getSize(find.byType(GitBranchIcon)), const Size(21, 21));
    expect(_painterOf(tester).color, const Color(0xFF123456));
  });

  testWidgets('显式 size / color 优先于 IconTheme', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: IconTheme(
            data: IconThemeData(size: 21, color: Color(0xFF123456)),
            child: GitBranchIcon(size: 16, color: Colors.red),
          ),
        ),
      ),
    );

    expect(tester.getSize(find.byType(GitBranchIcon)), const Size(16, 16));
    expect(_painterOf(tester).color, Colors.red);
  });

  test('只有颜色变化才重绘', () {
    const black = GitBranchPainter(color: Colors.black);
    const anotherBlack = GitBranchPainter(color: Colors.black);
    const white = GitBranchPainter(color: Colors.white);

    expect(black.shouldRepaint(anotherBlack), isFalse);
    expect(black.shouldRepaint(white), isTrue);
  });
}
