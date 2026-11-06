import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/chat/branch_panel.dart';
import 'package:narrchat/providers/round_provider.dart';
import 'package:narrchat/widgets/ai_bubble_actions.dart';
import 'package:narrchat/widgets/app_menu.dart';
import 'package:narrchat/widgets/git_branch_icon.dart';

import 'helpers/chat_harness.dart';
import 'helpers/fakes.dart';
import 'helpers/notice_harness.dart';

/// 对话页的分支 UI 接线：
/// - 顶栏分支入口用统一 Git 图标，点开是贴着入口的小窗（不居中、不暗化背景）；
/// - 小窗没有关闭按钮，点窗外任意处（含入口本身）关闭；
/// - 「从此新建分支」放在 AI 气泡右键菜单里（失败代没有该入口，底栏不再有）；
/// - 非默认分支的链首卡片显示「起始自第 N 轮第 M 代」+ 父 UUID，可跳回分叉点。
///
/// 面板内部行为（切换 / 改名 / 删除的交互细节）见 `branch_panel_test.dart`，
/// 本文件只测**跨层接线**。

/// 建库 → 播轮 → pump 对话页（播种必须在 runAsync 里，见 chat_harness 说明）。
typedef _Thread = ({RoundProvider provider, TestStack stack});

Future<_Thread> _pumpThread(
  WidgetTester tester, {
  Size size = const Size(1400, 900),
  int rounds = 2,
  int bodyRepeats = 1,
}) async {
  final stack = (await tester.runAsync(TestStack.create))!;
  addTearDown(() => tester.runAsync(stack.dispose));
  await tester.runAsync(() async {
    await stack.seedBook(uuid: kHarnessBookUuid, title: '测试书');
    for (var i = 1; i <= rounds; i++) {
      await stack.seedRound(
        kHarnessBookUuid,
        roundIndex: i,
        userInput: '第 $i 轮的用户输入',
        aiNarrative: '第 $i 轮的剧情正文。' * bodyRepeats,
      );
    }
  });
  final provider = await pumpChatScreen(
    tester,
    stack: stack,
    seedRounds: 0,
    size: size,
  );
  return (provider: provider, stack: stack);
}

/// 顶栏分支入口按钮。
Finder _branchEntry() => find.byKey(const ValueKey('chat-branch-entry'));

/// 右键菜单项（按 value 定位）。
Finder _menuItem(String value) => find.byWidgetPredicate(
  (w) => w is PopupMenuItem<String> && w.value == value,
);

Future<void> _openBranchPanel(WidgetTester tester) async {
  await tester.tap(_branchEntry());
  await settle(tester);
}

/// 打开 AI 气泡右键菜单（触屏长按 = 业务菜单口径）。
Future<void> _openBubbleMenu(WidgetTester tester, String bodyText) async {
  await tester.longPress(find.text(bodyText));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('顶栏入口：Git 图标 + 分支名；点开是贴着入口的小窗且不暗化背景', (tester) async {
    await _pumpThread(tester);
    await settle(tester);

    final entry = _branchEntry();
    expect(
      find.descendant(of: entry, matching: find.text('主线')),
      findsOneWidget,
      reason: '默认分支显示为「主线」',
    );
    expect(
      find.descendant(of: entry, matching: find.byType(GitBranchIcon)),
      findsOneWidget,
      reason: '顶栏分支入口统一用 Git 分支图标',
    );

    await _openBranchPanel(tester);
    expect(find.byType(BranchPanel), findsOneWidget);
    expect(find.byType(Dialog), findsNothing, reason: '不再用居中 Dialog');

    final entryRect = tester.getRect(entry);
    final panelRect = tester.getRect(find.byType(BranchPanel));
    expect(
      panelRect.right,
      closeTo(entryRect.right, 1),
      reason: '小窗右缘对齐入口（右上角打开位置）',
    );
    expect(
      panelRect.top,
      greaterThan(entryRect.bottom),
      reason: '小窗贴在入口下方，而不是居中',
    );
    expect(panelRect.center.dx, greaterThan(700), reason: '小窗在窗口右半边');

    // 不暗化其它部位：弹出路由的遮罩全透明，靠面板自身阴影表达悬浮。
    final route = ModalRoute.of(tester.element(find.byType(BranchPanel)));
    expect(route, isA<PopupRoute<void>>());
    expect(route!.barrierColor, Colors.transparent);
  });

  testWidgets('打开小窗有入场动画：淡入 + 从右上角轻缩放', (tester) async {
    await _pumpThread(tester);
    await settle(tester);

    await tester.tap(_branchEntry());
    await tester.pump(); // 建立路由（动画 t=0）
    expect(find.byType(BranchPanel), findsOneWidget);

    final fade = tester.widget<FadeTransition>(
      find
          .ancestor(
            of: find.byType(BranchPanel),
            matching: find.byType(FadeTransition),
          )
          .first,
    );
    final scale = tester.widget<ScaleTransition>(
      find
          .ancestor(
            of: find.byType(BranchPanel),
            matching: find.byType(ScaleTransition),
          )
          .first,
    );
    expect(fade.opacity.value, lessThan(1), reason: '首帧应是淡入起点');
    expect(scale.scale.value, lessThan(1), reason: '首帧应是缩放起点');
    expect(scale.alignment, Alignment.topRight, reason: '从入口所在的右上角展开');

    await tester.pump(const Duration(milliseconds: 220));
    expect(fade.opacity.value, 1);
    expect(scale.scale.value, 1);
    await settle(tester);
  });

  testWidgets('小窗无关闭按钮：点窗外关闭；点入口按钮本身也只关闭', (tester) async {
    await _pumpThread(tester);
    await settle(tester);

    await _openBranchPanel(tester);
    expect(find.byType(BranchPanel), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(BranchPanel),
        matching: find.byIcon(Icons.close),
      ),
      findsNothing,
      reason: '右上角的 X 已取消，关闭统一走「点外面」',
    );

    // 点聊天区（窗外）→ 关闭。
    await tester.tapAt(const Offset(320, 420));
    await settle(tester);
    expect(find.byType(BranchPanel), findsNothing);

    // 再开一次，点入口按钮所在位置 → 只关闭（不会关了又立刻重开）。
    await _openBranchPanel(tester);
    expect(find.byType(BranchPanel), findsOneWidget);
    // 遮罩盖在入口上：按入口按钮的坐标点击，事件先落到遮罩 → 关闭。
    await tester.tapAt(tester.getCenter(_branchEntry()));
    await settle(tester);
    expect(find.byType(BranchPanel), findsNothing);
  });

  testWidgets('右键菜单「从此新建分支」：建分支并切过去，底栏不再有该入口', (tester) async {
    final thread = await _pumpThread(tester);
    final provider = thread.provider;
    await settle(tester);

    expect(
      find.descendant(
        of: find.byType(AiBubbleActions),
        matching: find.text('从此新建分支'),
      ),
      findsNothing,
      reason: '气泡底部操作栏不再放分支入口',
    );

    final forkedFrom = provider.rounds.last.roundIndex;
    await _openBubbleMenu(tester, '第 2 轮的剧情正文。');

    expect(_menuItem('fork'), findsOneWidget);
    // 菜单顺序：紧跟「按意见修改」之后。
    final labels = tester
        .widgetList<PopupMenuItem<String>>(find.byType(PopupMenuItem<String>))
        .map((item) {
          final child = item.child;
          return child is AppMenuAction ? child.label : '';
        })
        .toList();
    expect(
      labels.indexOf('从此新建分支'),
      labels.indexOf('按意见修改') + 1,
      reason: '菜单项顺序固定：按意见修改 → 从此新建分支',
    );

    await tester.tap(
      find.descendant(of: _menuItem('fork'), matching: find.text('从此新建分支')),
    );
    await settle(tester);

    expect(provider.branches.length, 2, reason: '默认分支 + 新分叉');
    expect(provider.workingBranchUuid, isNotEmpty, reason: '分叉后应切到新分支');
    expect(
      provider.currentBranch?.fatherRowIndex,
      forkedFrom,
      reason: '从被点的那条 AI 气泡（视觉最下方 = 最新一轮）分叉',
    );
    expect(find.text('分支 2'), findsWidgets);
  });

  testWidgets('错误代右键菜单没有「从此新建分支」', (tester) async {
    final stack = (await tester.runAsync(TestStack.create))!;
    addTearDown(() => tester.runAsync(stack.dispose));
    await tester.runAsync(() async {
      await stack.seedBook(uuid: kHarnessBookUuid, title: '测试书');
      await stack.seedRound(
        kHarnessBookUuid,
        roundIndex: 1,
        userInput: '断线那一次',
        message: '连接超时',
        messageStatus: 'error',
      );
    });
    await pumpChatScreen(tester, stack: stack, seedRounds: 0);
    await settle(tester);

    // 失败代没有正文，长按气泡页眉同样能打开业务菜单。
    await tester.longPress(find.text('第 1 轮'));
    await tester.pumpAndSettle();
    expect(find.text('复制正文'), findsOneWidget, reason: '菜单确实打开了');
    expect(_menuItem('fork'), findsNothing, reason: '错误代不给新建分支入口');
    expect(find.text('从此新建分支'), findsNothing);
  });

  testWidgets('改名后分支列表立即更新（不用重开小窗），顶栏标签同步', (tester) async {
    final thread = await _pumpThread(tester);
    final provider = thread.provider;
    await settle(tester);

    await tester.runAsync(
      () => provider.forkBranch(round: provider.rounds.first, title: '分支 2'),
    );
    await tester.runAsync(() => provider.loadRounds(kHarnessBookUuid));
    await settle(tester);
    expect(provider.workingBranchUuid, isNotEmpty);

    await _openBranchPanel(tester);
    final panel = find.byType(BranchPanel);
    expect(
      find.descendant(of: panel, matching: find.text('分支 2')),
      findsOneWidget,
    );

    // 走面板里的「分支操作 → 重命名 → 确定」。
    await tester.tap(find.byTooltip('分支操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    await tester.enterText(
      find.descendant(of: dialog, matching: find.byType(TextField)),
      '如果线',
    );
    await tester.tap(find.descendant(of: dialog, matching: find.text('确定')));
    await settle(tester);

    expect(provider.currentBranch?.branchName, '如果线');
    expect(panel, findsOneWidget, reason: '改名不关闭小窗');
    expect(
      find.descendant(of: panel, matching: find.text('如果线')),
      findsOneWidget,
      reason: '列表要立即显示新名字，而不是等重开小窗',
    );
    expect(
      find.descendant(of: panel, matching: find.text('分支 2')),
      findsNothing,
    );
    expect(
      find.descendant(of: _branchEntry(), matching: find.text('如果线')),
      findsOneWidget,
      reason: '顶栏分支标签同步更新',
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('chat-branch-header-card')),
        matching: find.text('如果线'),
      ),
      findsOneWidget,
      reason: '链首分支头卡片同步更新',
    );
  });

  testWidgets('链首卡片：起始点 + 父 UUID + Git 图标，点击跳转回父分支并定位', (tester) async {
    // 播长正文：贴底时第 3 轮早已不在视口，跳转对齐断言才有意义。
    final thread = await _pumpThread(tester, rounds: 8, bodyRepeats: 80);
    final provider = thread.provider;
    await settle(tester);

    final forkRound = provider.rounds[2];
    final branchUuid = await tester.runAsync(
      () => provider.forkBranch(round: forkRound, title: '如果线'),
    );
    await tester.runAsync(() => provider.loadRounds(kHarnessBookUuid));
    await settle(tester);

    expect(branchUuid, isNotNull);
    final card = find.byKey(const ValueKey('chat-branch-header-card'));
    expect(card, findsOneWidget, reason: '非默认分支应在链首显示分支头卡片');
    expect(
      find.descendant(of: card, matching: find.byType(GitBranchIcon)),
      findsOneWidget,
      reason: '卡片图标也统一为 Git 分支图标',
    );
    expect(find.text('如果线'), findsWidgets);
    expect(
      find.text('起始自第 3 轮第 1 代'),
      findsOneWidget,
      reason: '分叉点父代序号来自 round_serial_num',
    );
    expect(find.text('父 UUID：${forkRound.uuid}'), findsOneWidget);
    // 灰字可读性：父 UUID 用次级正文色，不用极浅的 outline。
    final uuidText = tester.widget<Text>(
      find.text('父 UUID：${forkRound.uuid}'),
    );
    expect(
      uuidText.style?.color,
      Theme.of(tester.element(card)).colorScheme.onSurfaceVariant,
      reason: '父 UUID 必须用可读的次级文字色',
    );
    expect(find.text('点击跳转'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('chat-branch-father-jump')));
    await settle(tester);

    expect(provider.workingBranchUuid, '', reason: '跳回父分支（默认分支）');
    expect(card, findsNothing, reason: '回到主线后卡片消失');
    // 落点口径：第 3 轮落在视口顶附近（不是停在底部）。
    // 切分支会整链重建，离屏轮次的高度只有估算值，落点允许一两行误差。
    final listTop = tester.getTopLeft(find.byType(ListView)).dy;
    final roundTop = tester.getTopLeft(find.text('第 3 轮的用户输入')).dy;
    expect(roundTop, greaterThanOrEqualTo(listTop - 1));
    expect(
      roundTop,
      lessThanOrEqualTo(listTop + 100),
      reason: '跳转应定位到分叉那一轮附近（实际偏差 ${roundTop - listTop}px）',
    );
    expect(
      find.text('第 2 轮的用户输入'),
      findsNothing,
      reason: '更早的轮次应留在视口上方',
    );
  });

  testWidgets('父代已删除：卡片仍显示快照序号，点跳转只提示「已被删除」', (tester) async {
    final thread = await _pumpThread(tester);
    final provider = thread.provider;
    await settle(tester);

    final firstRound = provider.rounds.first;
    final branchUuid = await tester.runAsync(
      () => provider.forkBranch(round: firstRound, title: '如果线'),
    );
    // 回到主线删掉分叉点那一轮（含后续轮），子分支保留。
    await tester.runAsync(() async {
      await provider.switchBranch('');
      await provider.deleteRound(provider.rounds.first, deleteFollowing: true);
      await provider.switchBranch(branchUuid!);
    });
    await settle(tester);

    expect(provider.workingBranchUuid, branchUuid);
    expect(
      find.text('起始自第 1 轮第 1 代'),
      findsOneWidget,
      reason: '父代已删，序号回落到 father_row_shot 快照',
    );
    expect(find.text('父 UUID：${firstRound.uuid}'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('chat-branch-father-jump')));
    await settleNoticeEnter(tester);

    expect(find.textContaining('父代已被删除'), findsOneWidget);
    expect(
      provider.workingBranchUuid,
      branchUuid,
      reason: '父代已删时不做「跳到别处」的半截跳转',
    );
    await flushNotices(tester);
  });
}
