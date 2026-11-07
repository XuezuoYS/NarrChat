import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/config/ai_platforms.dart';
import 'package:narrchat/models/ai_platform.dart';
import 'package:narrchat/theme/app_theme.dart';
import 'package:narrchat/widgets/model_selector.dart';

/// 记录一次模型选择的替身回调结果。
class _Pick {
  final String platformId;
  final String modelId;
  final String? effort;

  const _Pick(this.platformId, this.modelId, this.effort);
}

/// 构造一个含三种模型的测试平台：
/// - `flash`：支持思考，默认 high（初始选中）；
/// - `no-think`：不支持思考；
/// - `custom`：支持思考，默认 low，档位 low/high（可按需覆盖）。
AiPlatform _platform({
  String customEffort = 'low',
  List<String> customOptions = const ['low', 'high'],
}) {
  return AiPlatform(
    id: 'p1',
    displayName: '测试平台',
    apiType: AiPlatforms.defaultPlatform.apiType,
    baseUrl: 'https://example.com',
    models: [
      const AiModel(id: 'flash', shortLabel: 'Flash', reasoningEffort: 'high'),
      const AiModel(
        id: 'no-think',
        shortLabel: 'NoThink',
        supportsThinking: false,
      ),
      AiModel(
        id: 'custom',
        shortLabel: 'Custom',
        reasoningEffort: customEffort,
        reasoningEffortOptions: customOptions,
      ),
    ],
  );
}

/// pump 一个隔离的 [ModelSelector]，返回回调记录器。
Future<List<_Pick>> _pumpSelector(
  WidgetTester tester, {
  required List<AiPlatform> platforms,
  String selectedPlatformId = 'p1',
  String selectedModelId = 'flash',
  bool thinkingEnabled = true,
}) async {
  final picks = <_Pick>[];
  await tester.pumpWidget(
    MaterialApp(
      theme: NarrChatTheme.light,
      home: Scaffold(
        body: Center(
          child: ModelSelector(
            platforms: platforms,
            selectedPlatformId: selectedPlatformId,
            selectedModelId: selectedModelId,
            reasoningEffortFor: (platform, model) =>
                model.effectiveReasoningEffort,
            thinkingEnabled: thinkingEnabled,
            onSelect: (platformId, modelId, effort) =>
                picks.add(_Pick(platformId, modelId, effort)),
            caption: const Text('caption'),
          ),
        ),
      ),
    ),
  );
  return picks;
}

/// 点击触发区展开菜单（菜单关闭时树里只有触发区这一个 InkWell）。
Future<void> _openMenu(WidgetTester tester) async {
  await tester.tap(
    find
        .descendant(
          of: find.byType(ModelSelector),
          matching: find.byType(InkWell),
        )
        .first,
  );
  await tester.pumpAndSettle();
}

/// 模型列表里某一行的 MenuItemButton（避开触发区里的同名模型名）。
Finder _modelRow(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(MenuItemButton));

void main() {
  testWidgets('模型列表：无思考灰字；当前模型勾选并只显示它的强度', (tester) async {
    await _pumpSelector(tester, platforms: [_platform()]);
    await _openMenu(tester);

    expect(find.text('测试平台'), findsOneWidget);
    expect(find.text('NoThink'), findsOneWidget);
    expect(find.text('Custom'), findsOneWidget);
    expect(find.text('无思考'), findsOneWidget);

    // 只有当前选中的 Flash 显示记住的强度；未选中的 Custom 不显示 low。
    expect(find.text('high'), findsOneWidget);
    expect(find.text('low'), findsNothing);

    final flashRow = _modelRow('Flash');
    expect(
      find.descendant(of: flashRow, matching: find.byIcon(Icons.check)),
      findsOneWidget,
    );
    expect(
      tester
          .widget<Text>(
            find.descendant(of: flashRow, matching: find.text('high')),
          )
          .style!
          .color,
      NarrChatTheme.primary,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('无思考模型：点击直接选中并关闭菜单，effort 为 null', (tester) async {
    final picks = await _pumpSelector(tester, platforms: [_platform()]);
    await _openMenu(tester);

    await tester.tap(find.text('NoThink'));
    await tester.pumpAndSettle();

    expect(picks, hasLength(1));
    expect(picks.single.platformId, 'p1');
    expect(picks.single.modelId, 'no-think');
    expect(picks.single.effort, isNull);
    // 菜单已关闭。
    expect(find.text('测试平台'), findsNothing);
  });

  testWidgets('思考模型：进入强度面板，第一行标注模型，返回不触发选择', (tester) async {
    final picks = await _pumpSelector(tester, platforms: [_platform()]);
    await _openMenu(tester);

    await tester.tap(find.text('Custom'));
    await tester.pumpAndSettle();

    // 菜单列表已被替换；触发区显示的是 Flash，所以 Custom 只剩面板标题。
    expect(find.text('Custom'), findsOneWidget);
    expect(find.text('选择思考强度'), findsOneWidget);
    expect(find.text('low'), findsOneWidget);
    expect(find.text('high'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);

    // 返回箭头回到模型列表，不产生选择。
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    expect(find.text('测试平台'), findsOneWidget);
    expect(find.text('NoThink'), findsOneWidget);
    expect(picks, isEmpty);
  });

  testWidgets('选择档位：回调模型 + 强度，并关闭菜单', (tester) async {
    final picks = await _pumpSelector(tester, platforms: [_platform()]);
    await _openMenu(tester);
    await tester.tap(find.text('Custom'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('high'));
    await tester.pumpAndSettle();

    expect(picks, hasLength(1));
    expect(picks.single.modelId, 'custom');
    expect(picks.single.effort, 'high');
    expect(find.text('测试平台'), findsNothing);
  });

  testWidgets('当前值不在档位中：补到首项并允许选择原值', (tester) async {
    final picks = await _pumpSelector(
      tester,
      platforms: [_platform(customEffort: 'turbo')],
    );
    await _openMenu(tester);
    await tester.tap(find.text('Custom'));
    await tester.pumpAndSettle();

    expect(find.text('turbo'), findsOneWidget);
    expect(find.text('low'), findsOneWidget);
    expect(find.text('high'), findsOneWidget);

    await tester.tap(find.text('turbo'));
    await tester.pumpAndSettle();
    expect(picks.single.effort, 'turbo');
  });

  testWidgets('本轮思考关闭：强度面板显示关闭说明', (tester) async {
    await _pumpSelector(
      tester,
      platforms: [_platform()],
      thinkingEnabled: false,
    );
    await _openMenu(tester);
    await tester.tap(find.text('Custom'));
    await tester.pumpAndSettle();

    expect(find.text('本轮思考已关闭，所选强度将在开启思考后生效'), findsOneWidget);
    expect(find.text('选择思考强度'), findsNothing);
  });

  testWidgets('关闭后重新打开：回到模型列表，不残留强度面板', (tester) async {
    await _pumpSelector(tester, platforms: [_platform()]);
    await _openMenu(tester);
    await tester.tap(find.text('Custom'));
    await tester.pumpAndSettle();
    expect(find.text('选择思考强度'), findsOneWidget);

    // 点外面关闭（不产生选择），再打开应回到一级列表。
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    await _openMenu(tester);
    expect(find.text('NoThink'), findsOneWidget);
    expect(find.text('选择思考强度'), findsNothing);
  });
}
