import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 与 ChatScreen 宽屏分支「右侧栏固定槽位 + SlideTransition」同构的测试夹具。
///
/// 用于验证：
/// 1. 初始收起（value=0）时侧栏被滑出裁剪、显示「打开侧栏」；
/// 2. 触发展开后 SlideTransition 的 offset 平滑插值（而非瞬间跳变）；
/// 3. 动画结束后侧栏回到槽位原位（可见），按钮消失。
class _SidebarHarness extends StatefulWidget {
  const _SidebarHarness();

  @override
  State<_SidebarHarness> createState() => _SidebarHarnessState();
}

class _SidebarHarnessState extends State<_SidebarHarness>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
      value: 0,
    );
    _anim = CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 与真实实现一致：用 AnimatedBuilder 逐帧驱动，按钮显隐随动画进度更新。
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final open = _controller.value > 0.5;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Expanded(
              child:
                  ColoredBox(color: Colors.white, child: Center(child: Text('聊天区'))),
            ),
            SizedBox(
              width: 380,
              child: Stack(
                children: [
                  if (!open)
                    Center(
                      child: TextButton(
                        onPressed: () => _controller.forward(),
                        child: const Text('打开侧栏'),
                      ),
                    ),
                  ClipRect(
                    child: SlideTransition(
                      key: const Key('sidebar-slide'),
                      position: Tween<Offset>(
                        begin: const Offset(1, 0),
                        end: Offset.zero,
                      ).animate(_anim),
                      child: const Material(
                        child: SizedBox(
                          width: 380,
                          height: 600,
                          child: Center(child: Text('侧栏内容')),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

void main() {
  Offset slideOffset(WidgetTester tester) => tester
      .widget<SlideTransition>(find.byKey(const Key('sidebar-slide')))
      .position
      .value;

  testWidgets('收起状态：侧栏滑出槽位（offset=(1,0)），显示打开按钮', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: _SidebarHarness())),
    );
    expect(slideOffset(tester), const Offset(1, 0));
    expect(find.text('打开侧栏'), findsOneWidget);
  });

  testWidgets('展开动画：offset 平滑插值，结束后侧栏原位可见', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: _SidebarHarness())),
    );
    await tester.tap(find.text('打开侧栏'));
    await tester.pump(); // 开始动画
    await tester.pump(const Duration(milliseconds: 100)); // 中途采样
    final mid = slideOffset(tester);
    expect(mid.dx, greaterThan(0.0));
    expect(mid.dx, lessThan(1.0));
    await tester.pump(const Duration(milliseconds: 300));
    expect(slideOffset(tester), Offset.zero);
    expect(find.text('打开侧栏'), findsNothing);
  });
}
