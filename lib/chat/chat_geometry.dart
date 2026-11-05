import 'chat_item.dart';

/// 纵向几何模型：全书每个条目的高度、前缀和、偏移与进度。
///
/// 为什么自己算而不用 `ScrollPosition.maxScrollExtent`：`ListView` 的
/// `estimateMaxScrollOffset` 只是估算，尤其在反向列表里会随构建进度漂移，
/// 滚动条"跳舞"就是它直接读数造成的。这里把几何变成唯一权威：
///
/// - 已实测的条目用实测高度；
/// - 没实测的用持久化缓存（同宽同字号）；
/// - 都没有就按种类均值估；
/// - 前缀和用 Fenwick 树，改一个高度是 O(log n)，偏移查询也是 O(log n)。
///
/// 坐标系与 Flutter 的 `reverse: true` 列表一致：**偏移 0 = 最新一端（底部）**。
class ChatGeometry {
  ChatGeometry({Map<ChatItemKind, double>? estimates})
      : _estimates = estimates ?? defaultEstimates;

  /// 未测量时的分种类估算值（有图片的再额外抬高，见 [_estimateOf]）。
  static const Map<ChatItemKind, double> defaultEstimates = {
    ChatItemKind.branchHeader: 88,
    ChatItemKind.user: 96,
    ChatItemKind.ai: 320,
    ChatItemKind.failed: 160,
  };

  /// 带图片条目的额外估算高度（图片加载前先把空间留够，避免滚动跳变）。
  static const double imageExtraHeight = 180;

  final Map<ChatItemKind, double> _estimates;

  List<ChatItem> _items = const [];
  final Map<ChatItemKey, int> _indexOf = {};
  final Map<ChatItemKey, double> _heights = {};
  final Set<ChatItemKey> _measured = {};

  /// Fenwick 树（1-based），存每个条目的高度。
  late List<double> _tree = [];

  int get itemCount => _items.length;

  List<ChatItem> get items => List.unmodifiable(_items);

  /// 全书总高（含估算）。
  double get total => itemCount == 0 ? 0 : _prefix(itemCount);

  bool isMeasured(int index) =>
      index >= 0 && index < itemCount && _measured.contains(_items[index].key);

  double heightOf(int index) {
    if (index < 0 || index >= itemCount) return 0;
    return _heights[_items[index].key] ?? _estimateOf(_items[index]);
  }

  /// 重建全书条目（换书 / 切分支 / 宽度或字号变化后用）。
  void rebuild(List<ChatItem> items, {Map<ChatItemKey, double>? cache}) {
    _items = List.unmodifiable(items);
    _indexOf.clear();
    _heights.clear();
    _measured.clear();
    for (var i = 0; i < _items.length; i++) {
      final item = _items[i];
      _indexOf[item.key] = i;
      final cached = cache?[item.key];
      _heights[item.key] = cached ?? _estimateOf(item);
      if (cached != null) _measured.add(item.key);
    }
    _rebuildTree();
  }

  /// 追加一个条目（生成中 / 新轮到达）。高度未知时先用估算值。
  void append(ChatItem item, {double? height}) {
    final existing = _indexOf[item.key];
    if (existing != null) {
      if (height != null) updateHeight(item.key, height);
      return;
    }
    final list = List<ChatItem>.of(_items)..add(item);
    _items = List.unmodifiable(list);
    _indexOf[item.key] = list.length - 1;
    final value = height ?? _estimateOf(item);
    _heights[item.key] = value;
    if (height != null) _measured.add(item.key);
    _tree.add(0);
    _add(list.length, value);
  }

  /// 更新某个条目的实测高度；高度没变时返回 false（省掉一次重排）。
  bool updateHeight(ChatItemKey key, double height) {
    final index = _indexOf[key];
    if (index == null || height <= 0) return false;
    final previous = _heights[key];
    _measured.add(key);
    if (previous != null && (previous - height).abs() < 0.5) return false;
    _heights[key] = height;
    final delta = height - (previous ?? 0);
    _add(index + 1, delta);
    return true;
  }

  /// 距离**底部**（最新一端）到第 [index] 个条目**顶边**的偏移。
  double offsetOf(int index) {
    if (index < 0 || index >= itemCount) return total;
    return total - _prefix(index + 1);
  }

  /// 位于偏移 [offset] 处的条目序号（从底部数）。
  ///
  /// 越界会被夹到两端，调用方不用自己判边界。
  int indexAt(double offset) {
    if (itemCount == 0) return 0;
    final fromTop = total - offset;
    if (fromTop <= 0) return 0;
    // 二分找第一个「顶边 ≥ fromTop」的条目。
    var low = 0;
    var high = itemCount - 1;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (_prefix(mid + 1) < fromTop) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }

  /// 滚动进度：0 = 贴底（最新），1 = 顶部（最早）。
  double progressAt(double offset, double viewportExtent) {
    final maxOffset = total - viewportExtent;
    if (maxOffset <= 0) return 0;
    final clamped = offset.clamp(0.0, maxOffset).toDouble();
    return (clamped / maxOffset).clamp(0.0, 1.0);
  }

  /// 条目 → 它所属轮的序号（跳转 "第 N 轮" 用）。
  int? roundIndexAt(int index) {
    if (index < 0 || index >= itemCount) return null;
    return _items[index].roundIndex;
  }

  /// 第一个属于第 [roundIndex] 轮的条目序号（找不到返回 null）。
  int? indexOfRound(int roundIndex) {
    for (var i = 0; i < _items.length; i++) {
      if (_items[i].roundIndex == roundIndex) return i;
    }
    return null;
  }

  /// 当前所有实测高度的快照（落持久化缓存用）。
  Map<ChatItemKey, double> dumpMeasuredHeights() => {
        for (final key in _measured)
          if (_heights[key] != null) key: _heights[key]!,
      };

  double _estimateOf(ChatItem item) {
    final base = _estimates[item.kind] ?? 200;
    return item.hasImages ? base + imageExtraHeight : base;
  }

  void _rebuildTree() {
    final n = _items.length;
    _tree = List<double>.filled(n + 1, 0, growable: true);
    for (var i = 1; i <= n; i++) {
      _tree[i] += _heights[_items[i - 1].key] ?? 0;
      final parent = i + (i & -i);
      if (parent <= n) _tree[parent] += _tree[i];
    }
  }

  void _add(int index, double delta) {
    if (delta == 0) return;
    final n = _items.length;
    for (var i = index; i <= n && i > 0; i += i & -i) {
      _tree[i] += delta;
    }
  }

  /// 前 [count] 个条目的高度和（不含第 count 个）。
  double _prefix(int count) {
    var sum = 0.0;
    for (var i = count.clamp(0, _items.length); i > 0; i -= i & -i) {
      sum += _tree[i];
    }
    return sum;
  }
}
