import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/config/ai_platforms.dart';
import 'package:narrchat/models/book.dart';
import 'package:narrchat/providers/round_provider.dart';

import 'helpers/fakes.dart';

/// 每轮模型名（`{{model}}` 解析值）随轮次落库的持久化测试。
void main() {
  const book = Book(uuid: 'b1', title: '测试书');

  test('sendRound 落库模型名：使用 {{model}} 而非友好名称', () async {
    final dao = FakeRoundDao();
    final provider = RoundProvider(
      dao: dao,
      bookDao: FakeBookDao(books: [book]),
      aiService: ToggleAiService(),
      // 默认预设（DeepSeek V4 Pro，模型 ID deepseek-v4-pro）。
      aiSettingsProvider: ChatCompatibleSettings(),
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
    expect(dao.rounds.single.modelName, AiPlatforms.defaultModelId);
  });

  test('sendRound 落库用户图片：userImages 随轮次持久化（供气泡与历史回放）', () async {
    final dao = FakeRoundDao();
    final provider = RoundProvider(
      dao: dao,
      bookDao: FakeBookDao(books: [book]),
      aiService: ToggleAiService(),
      aiSettingsProvider: ChatCompatibleSettings(),
    );

    final images = ['img/aaa.png', 'img/bbb.jpg'];
    final ok = await provider.sendRound(
      userInput: '看图',
      book: book,
      userImages: images,
    );
    expect(ok, isTrue);
    expect(dao.rounds, hasLength(1));
    expect(dao.rounds.single.userImages, images);
    expect(dao.rounds.single.aiImages, isEmpty);
  });

  test('editAndReAsk：以修改后的图片重新生成并落库', () async {
    final dao = FakeRoundDao();
    final provider = RoundProvider(
      dao: dao,
      bookDao: FakeBookDao(books: [book]),
      aiService: ToggleAiService(),
      aiSettingsProvider: ChatCompatibleSettings(),
    );
    await provider.loadRounds(book.uuid);
    await provider.sendRound(
      userInput: '原始输入',
      book: book,
      userImages: ['img/old.png'],
    );
    // loadRounds 会创建「第零轮」，故取 round_index == 1 的脚本轮。
    final round = dao.rounds.firstWhere((r) => r.roundIndex == 1);

    await provider.editAndReAsk(
      round,
      '修改后输入',
      book: book,
      images: ['img/new.png'],
    );

    final last = dao.rounds.last;
    expect(last.userInput, '修改后输入');
    expect(last.userImages, ['img/new.png']);
  });
}
