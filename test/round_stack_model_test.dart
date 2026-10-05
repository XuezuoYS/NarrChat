import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/round.dart';
import 'package:narrchat/models/round_stack.dart';

/// `round_stack` 模型层契约：库内列 ↔ Dart 对象互转、类型边界（时间戳）、
/// 以及 `Round.useStackUuid` 的往返。
///
/// 这些转换是「版本树 ↔ 投影」的唯一桥梁，错了整条链都错。
void main() {
  group('RoundStackRow', () {
    test('fromMap：空父亲归一化为 null，脏状态归一化为闲置，时间戳 0 视为无', () {
      final row = RoundStackRow.fromMap({
        'uuid': 'g1',
        'book_uuid': 'b1',
        'father_uuid': '   ',
        'round_index': 3,
        'round_serial_num': 2,
        'round_state': 'deleted',
        'round_created_at': 0,
        'user_images': '["img/a.png"]',
        'ai_images': 'not-json',
      });
      expect(row.fatherUuid, isNull, reason: '空白父亲 = 根');
      expect(row.roundState, isNull, reason: '仅 use / NULL 两种状态');
      expect(row.isUse, isFalse);
      expect(row.roundCreatedAt, isNull, reason: '0 = 无时间戳');
      expect(row.userImages, ['img/a.png']);
      expect(row.aiImages, isEmpty, reason: '非法 JSON 视为空');
    });

    test('toMap/fromMap 往返：内容列、tokens 的 null 语义、时间戳毫秒', () {
      final created = DateTime.fromMillisecondsSinceEpoch(1735689600000);
      final row = RoundStackRow(
        uuid: 'g1',
        bookUuid: 'b1',
        fatherUuid: 'f1',
        roundIndex: 2,
        roundSerialNum: 5,
        roundState: 'use',
        roundCreatedAt: created,
        userInput: '输入',
        aiNarrative: '正文',
        worldState: '世界',
        characterState: '角色',
        memorySummary: '记忆',
        currentTime: '第一天',
        recommendedAction: '选项A',
        tokensIn: 12,
        tokensOut: null,
        cachedTokensIn: 3,
        modelName: 'm',
        userImages: const ['u.png'],
        aiImages: const ['a.png'],
      );
      final back = RoundStackRow.fromMap(row.toMap());
      expect(back.uuid, 'g1');
      expect(back.fatherUuid, 'f1');
      expect(back.roundSerialNum, 5);
      expect(back.roundState, 'use');
      expect(back.isUse, isTrue);
      expect(back.roundCreatedAt, created);
      expect(back.aiNarrative, '正文');
      expect(back.tokensIn, 12);
      expect(back.tokensOut, isNull, reason: 'null = 无数据，不得回落 0');
      expect(back.cachedTokensIn, 3);
      expect(back.userImages, ['u.png']);
      expect(back.aiImages, ['a.png']);
    });

    test('fromRound/toRound：内容同形，时间戳毫秒 ↔ DateTime，投影锚点 = 本行 uuid', () {
      final created = DateTime.fromMillisecondsSinceEpoch(1735689600123);
      final round = Round(
        id: 7,
        bookUuid: 'b1',
        roundIndex: 1,
        userInput: 'u',
        aiNarrative: 'n',
        worldState: 'w',
        characterState: 'c',
        memorySummary: 'm',
        currentTime: 't',
        recommendedAction: 'r',
        tokensIn: 1,
        tokensOut: null,
        cachedTokensIn: 2,
        modelName: 'model',
        createdAt: created,
        userImages: const ['u.png'],
        aiImages: const ['a.png'],
        useStackUuid: 'ignored-here',
      );
      final stack = RoundStackRow.fromRound(
        round,
        uuid: 'g9',
        fatherUuid: 'f0',
        roundSerialNum: 3,
        roundState: 'use',
      );
      expect(stack.bookUuid, 'b1');
      expect(stack.roundIndex, 1);
      expect(stack.roundSerialNum, 3);
      expect(stack.fatherUuid, 'f0');
      expect(stack.roundCreatedAt, created);
      expect(stack.aiNarrative, 'n');
      expect(stack.tokensOut, isNull);

      final restored = stack.toRound(id: 7);
      expect(restored.id, 7);
      expect(restored.createdAt, created);
      expect(restored.useStackUuid, 'g9', reason: '投影锚点指向本代');
      expect(restored.aiNarrative, 'n');
      expect(restored.currentTime, 't');
      expect(restored.userImages, ['u.png']);
      expect(restored.tokensOut, isNull);
    });

    test('fromRound：round.createdAt 为 null 时 round_created_at 落 0 并读回 null', () {
      const round = Round(bookUuid: 'b1', roundIndex: 0);
      final stack = RoundStackRow.fromRound(
        round,
        uuid: 'g0',
        roundSerialNum: 1,
      );
      expect(stack.toMap()['round_created_at'], 0);
      expect(RoundStackRow.fromMap(stack.toMap()).roundCreatedAt, isNull);
      expect(stack.fatherUuid, isNull);
      expect(stack.roundState, isNull);
    });

    test('copyWith：clearFather / clearState 可显式置空', () {
      const row = RoundStackRow(
        uuid: 'g1',
        bookUuid: 'b1',
        fatherUuid: 'f1',
        roundIndex: 1,
        roundSerialNum: 1,
        roundState: 'use',
      );
      expect(row.copyWith(clearFather: true, clearState: true).fatherUuid, isNull);
      expect(row.copyWith(clearFather: true, clearState: true).roundState, isNull);
      expect(row.copyWith(roundSerialNum: 9).fatherUuid, 'f1');
      expect(row.copyWith(roundState: 'junk').roundState, isNull);
    });
  });

  test('RoundStackMeta.fromMap：只承载元数据列，use 状态可判定', () {
    final meta = RoundStackMeta.fromMap({
      'uuid': 'g2',
      'book_uuid': 'b1',
      'father_uuid': null,
      'round_index': 4,
      'round_serial_num': 6,
      'round_state': 'use',
      'round_created_at': 1000,
    });
    expect(meta.uuid, 'g2');
    expect(meta.fatherUuid, isNull);
    expect(meta.roundIndex, 4);
    expect(meta.roundSerialNum, 6);
    expect(meta.isUse, isTrue);
    expect(meta.roundCreatedAt, DateTime.fromMillisecondsSinceEpoch(1000));
  });

  test('RoundVersionInfo.switchable：≥2 存活代才显示控件', () {
    const single = RoundVersionInfo(
      currentSerial: 1,
      latestSerial: 1,
      aliveCount: 1,
    );
    const multiple = RoundVersionInfo(
      currentSerial: 2,
      latestSerial: 3,
      aliveCount: 3,
      prevUuid: 'p',
      nextUuid: 'n',
    );
    const failure = RoundVersionInfo(
      currentSerial: null,
      latestSerial: 2,
      aliveCount: 2,
      prevUuid: 'p',
    );
    expect(single.switchable, isFalse);
    expect(multiple.switchable, isTrue);
    expect(failure.switchable, isTrue, reason: '失败态仍需显示「还原上一代」');
    expect(failure.currentSerial, isNull);
  });

  test('RoundStackAdoptionReport.hasChanges：全 0 = 无变化（幂等采纳）', () {
    expect(const RoundStackAdoptionReport().hasChanges, isFalse);
    expect(const RoundStackAdoptionReport(reused: 1).hasChanges, isTrue);
    expect(const RoundStackAdoptionReport(created: 1).hasChanges, isTrue);
    expect(const RoundStackAdoptionReport(removedSubtree: 1).hasChanges, isTrue);
    expect(const RoundStackAdoptionReport(purgedOrphans: 1).hasChanges, isTrue);
  });

  test('Round.useStackUuid：fromMap / toMap / copyWith 往返', () {
    final round = Round.fromMap({
      'id': 3,
      'book_uuid': 'b1',
      'round_index': 2,
      'use_stack_uuid': 'g7',
    });
    expect(round.useStackUuid, 'g7');
    expect(round.copyWith(userInput: 'x').useStackUuid, 'g7');
    expect(round.toMap()['use_stack_uuid'], 'g7');
    // 老库 / 老客户端行没有该列：读出空串（待采纳），不得抛。
    expect(
      Round.fromMap({'book_uuid': 'b1', 'round_index': 2}).useStackUuid,
      '',
    );
  });
}
