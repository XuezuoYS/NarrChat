import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/screens/database_merge_screen.dart';
import 'package:narrchat/services/database_merge_service.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/utils/formats.dart';

import 'helpers/merge_db.dart';

void main() {
  late DatabaseMergePlan plan;
  late DatabaseMergePlan modPlan;
  late DatabaseMergePlan tiePlan;

  setUp(() async {
    final local = await createMergeDb();
    final backup = await createMergeDb();
    try {
      // 冲突书：本地与备份同名但轮次不同（uuid 各自独立，判同看书名）。
      await local.insert('books', {
        'uuid': 'lok-a',
        'title': 'A',
        'category': '旧',
      });
      await local.insert('rounds', {
        'book_uuid': 'lok-a',
        'round_index': 1,
        'user_input': '本地内容',
        'ai_narrative': '本地正文',
        'created_at': DateTime(2026, 1, 1).toIso8601String(),
      });
      await backup.insert('books', {
        'uuid': 'bak-a',
        'title': 'A',
        'category': '新',
      });
      await backup.insert('rounds', {
        'book_uuid': 'bak-a',
        'round_index': 1,
        'user_input': '备份内容',
        'ai_narrative': '备份正文',
        'created_at': DateTime(2026, 2, 1).toIso8601String(),
      });
      // 仅导入有：B。
      await backup.insert('books', {'uuid': 'bak-b', 'title': 'B'});
      await backup.insert('rounds', {
        'book_uuid': 'bak-b',
        'round_index': 1,
        'user_input': '云端B',
      });
      // 仅本地有：C。
      await local.insert('books', {'uuid': 'lok-c', 'title': 'C'});
      // 全一致：D。
      await local.insert('books', {
        'uuid': 'lok-d',
        'title': 'D',
        'category': '同',
      });
      await local.insert('rounds', {
        'book_uuid': 'lok-d',
        'round_index': 1,
        'user_input': '一致',
      });
      await backup.insert('books', {
        'uuid': 'bak-d',
        'title': 'D',
        'category': '同',
      });
      await backup.insert('rounds', {
        'book_uuid': 'bak-d',
        'round_index': 1,
        'user_input': '一致',
      });

      plan = await DatabaseMergeService.buildPlan(backup, local);
    } finally {
      await local.close();
      await backup.close();
    }
    modPlan = await _buildModPlan();
    tiePlan = await _buildTiePlan();
  });

  testWidgets('列出书籍，冲突展示两侧轮次/时间与状态徽标', (tester) async {
    await _pumpScreen(tester, plan);
    expect(find.text('数据库合并'), findsOneWidget);
    expect(find.text('A'), findsOneWidget);
    expect(find.text('B'), findsOneWidget);
    expect(find.text('C'), findsOneWidget);
    expect(find.text('D'), findsOneWidget);
    expect(find.text('冲突'), findsOneWidget);
    expect(find.text('仅导入有'), findsOneWidget);
    expect(find.text('仅本地有'), findsNWidgets(2)); // 徽标 + 侧卡标签
    expect(find.text('两者全一致'), findsOneWidget);
    // 冲突书展示两侧卡片。
    expect(find.text('导入的备份'), findsNWidgets(2)); // 冲突导入侧 + 仅导入有侧
    expect(find.text('本地'), findsOneWidget);
  });

  testWidgets('冲突页：最后时间较新的一侧以绿色高亮（自适应主题）', (tester) async {
    await _pumpScreen(tester, plan);
    // 冲突书 A：导入侧时间 2026-02-01（更新）、本地 2026-01-01（较旧）。
    final newer = tester.widget<Text>(
      find.text('最后时间：${Formats.formatDateTime(DateTime(2026, 2, 1))}'),
    );
    expect(newer.style?.color, NarrChatColors.light.success);
    final older = tester.widget<Text>(
      find.text('最后时间：${Formats.formatDateTime(DateTime(2026, 1, 1))}'),
    );
    expect(older.style?.color, isNot(NarrChatColors.light.success));
    // 轮次与最后时间分开高亮：A 两侧轮次相同(1:1)，因此轮次行均不标绿，
    // 即使导入侧时间为较新一侧标绿——证明两者独立。
    final roundTexts = find.text('轮次 1').evaluate();
    expect(roundTexts, isNotEmpty);
    for (final el in roundTexts) {
      final t = el.widget as Text;
      expect(t.style?.color, isNot(NarrChatColors.light.success));
    }
    // 主题本身的绿色在亮/暗下均有定义。
    expect(NarrChatColors.light.success, isNot(NarrChatColors.dark.success));
  });

  testWidgets('切换保留侧并合并 → onApply 收到对应决策', (tester) async {
    final decisions = <String, BookPartDecisions>{};
    var called = false;
    await _pumpScreen(
      tester,
      plan,
      onApply: (p, bd, md) async {
        called = true;
        decisions.addAll(bd);
        return DatabaseMergeResult();
      },
    );
    expect(decisions, isEmpty);

    // 默认建议：冲突书 A 的备份较新 → 轮次内容建议采用导入；此处把「轮次内容」切为保留本地。
    await tester.tap(find.text('保留本地').at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.text('合并'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '确认合并'));
    await tester.pumpAndSettle();
    // 走完 SnackBar 计时，避免测试结束残留悬挂计时器。
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    expect(called, isTrue);
    expect(decisions['A']!.allLocal, isTrue);
    expect(decisions['B']!.allImport, isTrue); // 仅导入有始终导入
    expect(decisions['D']!.allLocal, isTrue);
  });

  testWidgets('仅导入有的书不可取消，始终导入', (tester) async {
    final decisions = <String, BookPartDecisions>{};
    await _pumpScreen(
      tester,
      plan,
      onApply: (p, bd, md) async {
        decisions.addAll(bd);
        return DatabaseMergeResult();
      },
    );
    // 不再提供「取消导入」开关，仅标明「仅导入有，将导入此书」。
    expect(find.byType(Switch), findsNothing);
    expect(find.text('仅导入有，将导入此书'), findsOneWidget);
    await tester.tap(find.text('合并'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '确认合并'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    expect(decisions['B']!.allImport, isTrue);
  });

  testWidgets('打开时默认按轮次时间最新（备份较新 → 内容部件采用导入）', (tester) async {
    final decisions = <String, BookPartDecisions>{};
    await _pumpScreen(
      tester,
      plan,
      onApply: (p, bd, md) async {
        decisions.addAll(bd);
        return DatabaseMergeResult();
      },
    );
    await tester.tap(find.text('合并'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '确认合并'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    expect(decisions['A']!.content, MergePartChoice.import,
        reason: '备份时间更新 → 内容部件建议导入');
    expect(decisions['A']!.settings, MergePartChoice.keepLocal,
        reason: '备份时间严格更新（非持平）→ 设置部件保持保留本地');
    expect(decisions['B']!.allImport, isTrue);
    expect(decisions['D']!.allLocal, isTrue);
  });

  testWidgets('自动勾选：全本地 → 冲突保留本地、仅导入有仍导入', (tester) async {
    final decisions = <String, BookPartDecisions>{};
    await _pumpScreen(
      tester,
      plan,
      onApply: (p, bd, md) async {
        decisions.addAll(bd);
        return DatabaseMergeResult();
      },
    );
    await tester.tap(find.text('自动勾选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全本地'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('合并'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '确认合并'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    expect(decisions['A']!.allLocal, isTrue);
    expect(decisions['B']!.allImport, isTrue); // 仅导入有始终导入
  });

  testWidgets('自动勾选：按轮次数最多 → 轮次相同默认采用导入', (tester) async {
    final decisions = <String, BookPartDecisions>{};
    await _pumpScreen(
      tester,
      plan,
      onApply: (p, bd, md) async {
        decisions.addAll(bd);
        return DatabaseMergeResult();
      },
    );
    await tester.tap(find.text('自动勾选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('按轮次数最多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('合并'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '确认合并'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    expect(decisions['A']!.content, MergePartChoice.import,
        reason: '两侧轮次相同 → 轮次内容优先采用导入');
    expect(decisions['A']!.settings, MergePartChoice.import,
        reason: '两侧轮次相同（均持平）→ 书籍设置同样采用导入');
  });

  testWidgets('自动勾选：按轮次时间最新，两侧时间持平 → 设置与内容均采用导入', (tester) async {
    final decisions = <String, BookPartDecisions>{};
    await _pumpScreen(
      tester,
      tiePlan,
      onApply: (p, bd, md) async {
        decisions.addAll(bd);
        return DatabaseMergeResult();
      },
    );
    await tester.tap(find.text('合并'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '确认合并'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    expect(decisions['A']!.content, MergePartChoice.import,
        reason: '两侧时间持平 → 轮次内容优先采用导入');
    expect(decisions['A']!.settings, MergePartChoice.import,
        reason: '两侧时间持平（均持平）→ 书籍设置同样采用导入');
  });

  testWidgets('点预览打开书籍内容对话框', (tester) async {
    await _pumpScreen(tester, plan);
    await tester.tap(find.byTooltip('预览').first);
    await tester.pumpAndSettle();
    expect(find.text('书籍设置'), findsOneWidget);
    expect(find.textContaining('轮次（'), findsOneWidget);
  });

  testWidgets('左上返回取消导入并退出页面', (tester) async {
    await _pumpScreen(tester, plan);
    expect(find.text('数据库合并'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    expect(find.text('数据库合并'), findsNothing);
  });

  testWidgets('Mod 冲突：提供导入/重命名/本地三选一，重命名传参 onApply', (tester) async {
    final modDecisions = <String, ModMergeDecision>{};
    await _pumpScreen(
      tester,
      modPlan,
      onApply: (p, bd, md) async {
        modDecisions.addAll(md);
        return DatabaseMergeResult();
      },
    );
    expect(find.text('Mod（1）'), findsOneWidget);
    expect(find.text('M'), findsOneWidget);
    expect(find.text('导入'), findsOneWidget);
    expect(find.text('重命名'), findsOneWidget);
    // 冲突 Mod 并排展示「导入的备份」与「本地」两侧，各有预览按钮。
    expect(find.text('导入的备份'), findsOneWidget);
    expect(find.text('本地'), findsNWidgets(2)); // 侧卡标签 + 「本地」决策段
    expect(find.byTooltip('预览'), findsNWidgets(2));

    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('合并'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '确认合并'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    expect(modDecisions['M'], ModMergeDecision.rename);
  });

  testWidgets('Mod 冲突：点侧卡即可选择对应导入/本地决策', (tester) async {
    final modDecisions = <String, ModMergeDecision>{};
    await _pumpScreen(
      tester,
      modPlan,
      onApply: (p, bd, md) async {
        modDecisions.addAll(md);
        return DatabaseMergeResult();
      },
    );

    // 默认建议为导入：导入侧卡选中（单选图标实心），本地未选中。
    expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_off), findsOneWidget);

    // 点击未选中的本地侧卡 → 决策改为保留本地，导入侧卡随之变为未选中。
    await tester.tap(find.byIcon(Icons.radio_button_off));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.radio_button_off), findsOneWidget);

    // 再点击未选中的导入侧卡 → 决策改回导入。
    await tester.tap(find.byIcon(Icons.radio_button_off));
    await tester.pumpAndSettle();

    await tester.tap(find.text('合并'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '确认合并'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    expect(modDecisions['M'], ModMergeDecision.import);
  });

  testWidgets('Mod 冲突：预览打开单个并排对比对话框（git 式）', (tester) async {
    await _pumpScreen(tester, modPlan);
    expect(find.byTooltip('预览'), findsNWidgets(2));

    // 任一点击预览都打开同一个并排对比对话框，同时展示两侧内容与差异标记。
    await tester.tap(find.byTooltip('预览').first);
    await tester.pumpAndSettle();
    expect(find.text('Mod 对比'), findsOneWidget);
    expect(find.text('云端描述'), findsOneWidget);
    expect(find.text('本地描述'), findsOneWidget);
    expect(find.text('有差异'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.text('Mod 对比'), findsNothing);

    // 本地侧预览按钮同样打开同一个对话框。
    await tester.tap(find.byTooltip('预览').last);
    await tester.pumpAndSettle();
    expect(find.text('Mod 对比'), findsOneWidget);
    expect(find.text('云端描述'), findsOneWidget);
    expect(find.text('本地描述'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.text('Mod 对比'), findsNothing);
  });

  testWidgets('自动勾选：全本地同样作用于 Mod（冲突保留本地）', (tester) async {
    final modDecisions = <String, ModMergeDecision>{};
    await _pumpScreen(
      tester,
      modPlan,
      onApply: (p, bd, md) async {
        modDecisions.addAll(md);
        return DatabaseMergeResult();
      },
    );
    await tester.tap(find.text('自动勾选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全本地'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('合并'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '确认合并'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    expect(modDecisions['M'], ModMergeDecision.keepLocal);
  });
}

/// 以 push 方式打开屏幕（使 pop 回到前置路由），并注入可选的 [onApply]。
Future<void> _pumpScreen(
  WidgetTester tester,
  DatabaseMergePlan plan, {
  Future<DatabaseMergeResult> Function(
    DatabaseMergePlan,
    Map<String, BookPartDecisions>,
    Map<String, ModMergeDecision>,
  )?
  onApply,
}) async {
  // 加大视口，确保 4 本书的卡片都在列表中构建（ListView 遇小视口会懒加载，
  // 导致后面的「仅本地有」等卡片未被构建）。
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      theme: NarrChatTheme.light,
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () =>
                DatabaseMergeScreen.open(context, plan: plan, onApply: onApply),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

/// 构建一个仅含「Mod 冲突」的计划（两侧同名 M 不同内容），供 Mod UI 用例使用。
Future<DatabaseMergePlan> _buildModPlan() async {
  final local = await createMergeDb();
  final backup = await createMergeDb();
  try {
    await local.insert('mods', {
      'uuid': 'lok-m',
      'name': 'M',
      'description': '本地描述',
    });
    await backup.insert('mods', {
      'uuid': 'bak-m',
      'name': 'M',
      'description': '云端描述',
    });
    return await DatabaseMergeService.buildPlan(backup, local);
  } finally {
    await local.close();
    await backup.close();
  }
}

/// 构建一个「冲突书 A 两侧轮次时间相同、轮次数相同」的计划，
/// 供「按轮次时间最新 / 按轮次数最多」持平时默认决策用例使用。
Future<DatabaseMergePlan> _buildTiePlan() async {
  final local = await createMergeDb();
  final backup = await createMergeDb();
  try {
    await local.insert('books', {
      'uuid': 'lok-a',
      'title': 'A',
      'category': '本地',
    });
    await local.insert('rounds', {
      'book_uuid': 'lok-a',
      'round_index': 1,
      'user_input': '本地内容',
      'ai_narrative': '本地正文',
      'created_at': DateTime(2026, 1, 1).toIso8601String(),
    });
    await backup.insert('books', {
      'uuid': 'bak-a',
      'title': 'A',
      'category': '备份',
    });
    await backup.insert('rounds', {
      'book_uuid': 'bak-a',
      'round_index': 1,
      'user_input': '备份内容',
      'ai_narrative': '备份正文',
      'created_at': DateTime(2026, 1, 1).toIso8601String(),
    });
    return await DatabaseMergeService.buildPlan(backup, local);
  } finally {
    await local.close();
    await backup.close();
  }
}
