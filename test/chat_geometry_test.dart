import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/chat/chat_geometry.dart';
import 'package:narrchat/chat/chat_item.dart';

/// 纵向几何：前缀和、偏移、进度、增量更新。
void main() {
  ChatItem item(
    String uuid,
    int roundIndex,
    ChatItemKind kind, {
    bool hasImages = false,
  }) {
    return ChatItem(
      roundUuid: uuid,
      roundIndex: roundIndex,
      kind: kind,
      hasImages: hasImages,
    );
  }

  List<ChatItem> sample() => [
        item('r1', 1, ChatItemKind.user),
        item('r1', 1, ChatItemKind.ai),
        item('r2', 2, ChatItemKind.user),
        item('r2', 2, ChatItemKind.ai),
      ];

  test('空几何：到处为零，不越界', () {
    final geometry = ChatGeometry();
    expect(geometry.itemCount, 0);
    expect(geometry.total, 0);
    expect(geometry.offsetOf(0), 0);
    expect(geometry.indexAt(0), 0);
    expect(geometry.progressAt(0, 100), 0);
    expect(geometry.roundIndexAt(0), isNull);
    expect(geometry.indexOfRound(1), isNull);
  });

  test('未测量时按种类估算，总量等于各项之和', () {
    final geometry = ChatGeometry();
    geometry.rebuild(sample());

    expect(geometry.itemCount, 4);
    expect(geometry.heightOf(0), ChatGeometry.defaultEstimates[ChatItemKind.user]);
    expect(geometry.heightOf(1), ChatGeometry.defaultEstimates[ChatItemKind.ai]);
    expect(geometry.total, closeTo(96 + 320 + 96 + 320, 1e-9));
    expect(geometry.isMeasured(0), isFalse);
  });

  test('带图片的条目估算更高，避免加载后跳动', () {
    final geometry = ChatGeometry();
    geometry.rebuild([
      item('r1', 1, ChatItemKind.ai, hasImages: true),
    ]);
    expect(
      geometry.heightOf(0),
      ChatGeometry.defaultEstimates[ChatItemKind.ai]! +
          ChatGeometry.imageExtraHeight,
    );
  });

  test('偏移从底部算：最新条目偏移为 0', () {
    final geometry = ChatGeometry();
    geometry.rebuild(sample());
    geometry.updateHeight(geometry.items[3].key, 400);

    expect(geometry.offsetOf(3), 0, reason: '最后一条顶边贴着底部');
    expect(geometry.offsetOf(2), 400);
    expect(geometry.offsetOf(1), 400 + 96);
    expect(geometry.offsetOf(0), 400 + 96 + 320);
    expect(geometry.offsetOf(4), geometry.total, reason: '越界夹到总量');
  });

  test('indexAt 与 offsetOf 互为逆运算', () {
    final geometry = ChatGeometry();
    geometry.rebuild(sample());
    for (var i = 0; i < 4; i++) {
      final offset = geometry.offsetOf(i);
      expect(geometry.indexAt(offset), i, reason: '第 $i 条顶边处应命中自己');
    }
  });

  test('indexAt 越界夹到两端', () {
    final geometry = ChatGeometry();
    geometry.rebuild(sample());
    expect(geometry.indexAt(-100), 3, reason: '底部以下夹到最后一条');
    expect(geometry.indexAt(geometry.total * 2), 0, reason: '顶部以上夹到第一条');
  });

  test('进度：贴底 0、顶部 1、内容不足一屏为 0', () {
    final geometry = ChatGeometry();
    geometry.rebuild(sample());
    final maxOffset = geometry.total - 200;
    expect(geometry.progressAt(0, 200), 0);
    expect(geometry.progressAt(maxOffset, 200), closeTo(1, 1e-9));
    expect(geometry.progressAt(geometry.total / 2, 200), greaterThan(0));

    final short = ChatGeometry();
    short.rebuild([item('x', 1, ChatItemKind.user)]);
    expect(short.progressAt(0, 10000), 0, reason: '内容不足一屏不算滚动');
  });

  test('更新高度只做增量，Fenwick 前缀和仍正确', () {
    final geometry = ChatGeometry();
    geometry.rebuild(sample());
    final before = geometry.total;

    final changed = geometry.updateHeight(geometry.items[0].key, 200);
    expect(changed, isTrue);
    expect(geometry.total, closeTo(before + (200 - 96), 1e-9));
    expect(geometry.isMeasured(0), isTrue);
    expect(geometry.offsetOf(0), closeTo(320 + 96 + 320, 1e-9),
        reason: '第一条顶边 = 自己以外所有条目之和');

    final again = geometry.updateHeight(geometry.items[0].key, 200.2);
    expect(again, isFalse, reason: '差值小于 0.5 视为没变，省一次重排');
  });

  test('追加条目：前缀和正确、重复追加不产生两条', () {
    final geometry = ChatGeometry();
    geometry.rebuild(sample());
    final before = geometry.total;

    geometry.append(item('r3', 3, ChatItemKind.ai));
    expect(geometry.itemCount, 5);
    expect(geometry.total, closeTo(before + 320, 1e-9));
    expect(geometry.offsetOf(4), 0);

    geometry.append(item('r3', 3, ChatItemKind.ai), height: 500);
    expect(geometry.itemCount, 5, reason: '同一个 key 不重复追加');
    expect(geometry.heightOf(4), 500);
    expect(geometry.total, closeTo(before + 500, 1e-9));
  });

  test('rebuild 接受持久化缓存，命中即视为已测量', () {
    final geometry = ChatGeometry();
    final items = sample();
    geometry.rebuild(items, cache: {
      ChatItemKey('r1', ChatItemKind.ai): 640,
    });

    expect(geometry.heightOf(1), 640);
    expect(geometry.isMeasured(1), isTrue);
    expect(geometry.isMeasured(0), isFalse);
    expect(geometry.dumpMeasuredHeights(), {
      ChatItemKey('r1', ChatItemKind.ai): 640,
    });
  });

  test('按轮定位：拿到轮号与该轮第一个条目', () {
    final geometry = ChatGeometry();
    geometry.rebuild(sample());
    expect(geometry.roundIndexAt(2), 2);
    expect(geometry.roundIndexAt(99), isNull);
    expect(geometry.indexOfRound(2), 2);
    expect(geometry.indexOfRound(9), isNull);
  });

  test('分支头与失败代有各自的估算高度', () {
    final geometry = ChatGeometry();
    geometry.rebuild([
      ChatItem(
        roundUuid: 'br1',
        roundIndex: 3,
        kind: ChatItemKind.branchHeader,
        branchUuid: 'br1',
      ),
      item('r4', 4, ChatItemKind.failed),
    ]);
    expect(
      geometry.heightOf(0),
      ChatGeometry.defaultEstimates[ChatItemKind.branchHeader],
    );
    expect(
      geometry.heightOf(1),
      ChatGeometry.defaultEstimates[ChatItemKind.failed],
    );
  });
}
