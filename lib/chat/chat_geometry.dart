import 'chat_item.dart';

/// 纵向几何模型：**全书**每个条目的高度、前缀和、偏移与进度。
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
/// **几何覆盖整条活动链**（窗口只决定"哪些条目真的渲染"）：轨道要显示的是
/// 全书进度，而不是"这一窗的进度"；跳转落点也靠全书偏移算，窗口外的条目
/// 只有估算高度，但它和落点用的是同一套估算，相减时正好抵消。
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
    // 占位条目另有 fixedHeight，这里的值只在没给固定高度时兜底。
    ChatItemKind.leadingSpacer: 0,
    ChatItemKind.trailingSpacer: 0,
  };

  /// 带图片条目的额外估算高度（图片加载前先把空间留够，避免滚动跳变）。
  static const double imageExtraHeight = 180;

  final Map<ChatItemKind, double> _estimates;

  List<ChatItem> _items = const [];
  final Map<ChatItemKey, int> _indexOfKey = {};

  /// 轮号 → 该轮**第一个真实条目**的下标（分支头 / 占位条目不参与）。
  final Map<int, int> _indexOfRound = {};
  final Map<ChatItemKey, double> _heights = {};
  final Set<ChatItemKey> _measured = {};

  /// 最后一个真实轮次条目与其轮号（重建/追加时顺手维护，避免每次线性找）。
  ChatItem? _lastRoundItem;
  ChatItem? _firstRoundItem;

  /// Fenwick 树（1-based），存每个条目的高度。
  late List<double> _tree = [];

  int get itemCount => _items.length;

  bool get isEmpty => _items.isEmpty;

  /// 全书条目（自旧到新，只读）。
  List<ChatItem> get items => _items;

  /// 全书总高（含估算）。
  double get total => itemCount == 0 ? 0 : _prefix(itemCount);

  /// 书里最大的轮号（几何为空时 null）。
  int? get maxRoundIndex => lastRoundItem?.roundIndex;

  /// 书里最小的轮号（几何为空时 null）。
  int? get firstRoundIndex => _firstRoundItem?.roundIndex;

  /// 最后一个真实轮次条目（跳过占位条目，分支头也算真实条目）。
  ChatItem? get lastRoundItem => _lastRoundItem;

  bool isMeasured(int index) =>
      index >= 0 && index < itemCount && _measured.contains(_items[index].key);

  double heightOf(int index) {
    if (index < 0 || index >= itemCount) return 0;
    return _heights[_items[index].key] ?? _estimateOf(_items[index]);
  }

  /// 重建全书条目（换书 / 切分支 / 宽度或字号变化后用）。
  void rebuild(List<ChatItem> items, {Map<ChatItemKey, double>? cache}) {
    _items = List.unmodifiable(items);
    _indexOfKey.clear();
    _indexOfRound.clear();
    _heights.clear();
    _measured.clear();
    _lastRoundItem = null;
    _firstRoundItem = null;
    for (var i = 0; i < _items.length; i++) {
      final item = _items[i];
      _indexOfKey[item.key] = i;
      if (_isRoundItem(item)) {
        _indexOfRound.putIfAbsent(item.roundIndex, () => i);
        _firstRoundItem ??= item;
        _lastRoundItem = item;
      }
      final cached = cache?[item.key];
      _heights[item.key] = cached ?? _estimateOf(item);
      if (cached != null) _measured.add(item.key);
    }
    _rebuildTree();
  }

  /// 追加一个条目（生成中 / 新轮到达）。高度未知时先用估算值。
  void append(ChatItem item, {double? height}) {
    final existing = _indexOfKey[item.key];
    if (existing != null) {
      if (height != null) updateHeight(item.key, height);
      return;
    }
    final list = List<ChatItem>.of(_items)..add(item);
    _items = List.unmodifiable(list);
    final index = list.length - 1;
    _indexOfKey[item.key] = index;
    if (_isRoundItem(item)) {
      _indexOfRound.putIfAbsent(item.roundIndex, () => index);
      _firstRoundItem ??= item;
      _lastRoundItem = item;
    }
    final value = height ?? _estimateOf(item);
    _heights[item.key] = value;
    if (height != null) _measured.add(item.key);
    _tree.add(0);
    _add(index + 1, value);
  }

  /// 更新某个条目的实测高度；高度没变时返回 false（省掉一次重排）。
  bool updateHeight(ChatItemKey key, double height) {
    final index = _indexOfKey[key];
    if (index == null || height <= 0) return false;
    // 占位条目的高度就是它的语义（见 [updateFixedHeight]），不接受实测覆盖。
    if (_items[index].isSpacer) return false;
    final previous = _heights[key];
    _measured.add(key);
    if (previous != null && (previous - height).abs() < 0.5) return false;
    _heights[key] = height;
    _add(index + 1, height - (previous ?? 0));
    return true;
  }

  /// 距离**底部**（最新一端）到第 [index] 个条目**底边**的偏移。
  double offsetOf(int index) {
    if (index < 0 || index >= itemCount) return total;
    return total - _prefix(index + 1);
  }

  /// 距离**底部**到第 [index] 个条目**顶边**的偏移（= 底边 + 自身高度）。
  ///
  /// 跳转落点与「顶边对齐视口顶」都用它，别在调用处自己 `offsetOf + heightOf`。
  double topEdgeOf(int index) => offsetOf(index) + heightOf(index);

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
  ///
  /// [bookOffset] 是视口**底边**距书底的距离（全书坐标）；[viewportExtent] 是视口高。
  double progressOf(double bookOffset, double viewportExtent) {
    final maxOffset = total - viewportExtent;
    if (maxOffset <= 0) return 0;
    return (bookOffset.clamp(0.0, maxOffset)) / maxOffset;
  }

  /// 条目 → 它所属轮的序号（跳转 "第 N 轮" 用）。
  int? roundIndexAt(int index) {
    if (index < 0 || index >= itemCount) return null;
    return _items[index].roundIndex;
  }

  /// 偏移 [offset] 处所属的轮号（"视口顶部是哪一轮"的判据）。
  ///
  /// 精确落在某个条目的**顶边**上时算作那一条：用户看到的第一行就是它。
  /// [indexAt] 在边界上给的是上方那一条，这里补一次边界修正。
  int? roundIndexAtOffset(double offset) {
    final index = indexAt(offset);
    if (index + 1 < itemCount &&
        (offsetOf(index) - offset).abs() < 0.5) {
      return _items[index + 1].roundIndex;
    }
    return roundIndexAt(index);
  }

  /// 第一个属于第 [roundIndex] 轮的条目下标（找不到返回 null）。
  ///
  /// O(1)：重建时建了轮号索引（轮号有断裂时也能命中实际存在的轮）。
  int? indexOfRound(int roundIndex) => _indexOfRound[roundIndex];

  /// 指定身份的条目下标（找不到返回 null）。
  int? indexOf(ChatItemKey key) => _indexOfKey[key];

  /// 当前所有实测高度的快照（落持久化缓存用）。
  Map<ChatItemKey, double> dumpMeasuredHeights() => {
        for (final key in _measured)
          if (_heights[key] != null) key: _heights[key]!,
      };

  /// 是否参与「第几轮」索引（分支头与占位条目不参与）。
  static bool _isRoundItem(ChatItem item) =>
      !item.isSpacer && item.kind != ChatItemKind.branchHeader;

  double _estimateOf(ChatItem item) {
    // 占位条目：高度由调用方给定（底部避让 / 顶部收尾），估算值只兜底。
    final fixed = item.fixedHeight;
    if (fixed != null) return fixed;
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
