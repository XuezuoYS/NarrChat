import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/config/model_presets.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/providers/ai_settings_provider.dart';
import 'package:narrchat/providers/round_provider.dart';

import 'helpers/fakes.dart';

/// 每轮模型名（`{{model}}` 解析值）随轮次落库的持久化测试。
void main() {
  const book = Book(id: 1, title: '测试书');

  test('sendRound 落库模型名：使用 {{model}} 而非友好名称', () async {
    final dao = FakeRoundDao();
    final provider = RoundProvider(
      dao: dao,
      bookDao: FakeBookDao(books: [book]),
      aiService: ToggleAiService(),
      // 默认预设（DeepSeek V4 Pro，模型 ID deepseek-v4-pro）。
      aiSettingsProvider: AiSettingsProvider(),
    );

    final ok = await provider.sendRound(userInput: '你好', book: book);
    expect(ok, isTrue);
    expect(dao.rounds, hasLength(1));
    expect(dao.rounds.single.modelName, 'deepseek-v4-pro');
    // 关键：存的是 {{model}}（API ID），不是友好名称。
    expect(dao.rounds.single.modelName, isNot('DeepSeek V4 Pro'));
  });

  test('无设置注入时按默认预设回退模型名', () async {
    final dao = FakeRoundDao();
    final provider = RoundProvider(
      dao: dao,
      bookDao: FakeBookDao(books: [book]),
      aiService: ToggleAiService(),
    );

    final ok = await provider.sendRound(userInput: '你好', book: book);
    expect(ok, isTrue);
    expect(dao.rounds.single.modelName, ModelPresets.defaultPreset.modelId);
  });
}
