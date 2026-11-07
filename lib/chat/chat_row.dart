import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'chat_item.dart';

/// 当前已经真正挂到渲染树上的聊天行。
///
/// 几何模型只有“估算 / 实测高度”，它不知道懒加载列表此刻到底把哪一行放在
/// 视口顶部；`maxScrollExtent` 又只是估算值，会随构建进度漂移。页码若直接拿
/// 这两个数反推，长轮次滚动时就会随机跳。这里登记真实渲染对象，查询时现场读
/// 全局坐标——视口顶部压着哪一行，就返回哪一行的轮号。
class ChatRowRegistry {
  final Set<ChatRowMeasureBox> _rows = {};

  /// 当前挂载的行数（测试用来确认登记 / 注销是否成对）。
  int get attachedCount => _rows.length;

  void attach(ChatRowMeasureBox row) => _rows.add(row);

  void detach(ChatRowMeasureBox row) => _rows.remove(row);

  /// 全局纵坐标 [viewportTop] 落在哪一轮。
  ///
  /// 优先取矩形真正包含该坐标的行；若落在行间空隙 / 内容上下方，就取最近的
  /// 下方行，没有下方行再取上方最后一行。首帧还没布局时返回 null。
  int? roundIndexAt(double viewportTop) {
    ChatRowMeasureBox? above;
    ChatRowMeasureBox? below;
    var aboveBottom = double.negativeInfinity;
    var belowTop = double.infinity;
    for (final row in _rows) {
      if (!row.attached || !row.hasSize) continue;
      final top = row.localToGlobal(Offset.zero).dy;
      final bottom = top + row.size.height;
      if (top <= viewportTop && viewportTop < bottom) {
        return row.roundIndex;
      }
      if (bottom <= viewportTop && bottom > aboveBottom) {
        above = row;
        aboveBottom = bottom;
      }
      if (top > viewportTop && top < belowTop) {
        below = row;
        belowTop = top;
      }
    }
    return (below ?? above)?.roundIndex;
  }
}

/// 列表条目**高度**自上报部件（纯代理，不改变布局）。
///
/// 高度变化时在帧末把实测高度交给 [onMeasured]，几何模型据此更新前缀和
/// （轨道拇指、进度、跳转落点都读它）。刻意**不使用逐项 GlobalKey**：
/// 虚拟化列表里大量 GlobalKey 既重又容易在重排时错位 —— 部件本身就是渲染
/// 对象，自己读自己的尺寸即可。
///
/// 上报挂在渲染对象的 `performLayout` 上，而不是 State 的 `initState` /
/// `didUpdateWidget`：条目内部的状态变化会改高度却**不会**让 itemBuilder 重跑
/// （气泡展开 / 收起、代次控件显隐、流式正文增长），State 那套钩子收不到。
///
/// **Key 要落在列表 delegate 的直接子项上**（调用方把 `item.key` 传给 `key:`）：
/// `reverse` 列表新增条目会让所有已有条目的视图下标 +1，只有稳定 Key 能让框架
/// 把元素（连同折叠状态、选区）搬回新下标。
class ChatRowMeasure extends SingleChildRenderObjectWidget {
  const ChatRowMeasure({
    super.key,
    required this.itemKey,
    required this.roundIndex,
    required this.onMeasured,
    this.registry,
    required super.child,
  });

  /// 这一行的稳定身份（`轮uuid:类型`）。
  final ChatItemKey itemKey;

  /// 这一行所属轮号（页码登记处直接返回它，不按 Key / 几何反查）。
  final int roundIndex;

  /// 高度回传（帧末调用；只在这一行高度变化时调用）。
  final void Function(ChatItemKey key, double height) onMeasured;

  /// 已挂载行登记处（页码判断当前真实可见轮号用）；纯高度测试可不传。
  final ChatRowRegistry? registry;

  @override
  RenderObject createRenderObject(BuildContext context) => ChatRowMeasureBox(
        itemKey: itemKey,
        roundIndex: roundIndex,
        onMeasured: onMeasured,
        registry: registry,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    ChatRowMeasureBox renderObject,
  ) {
    renderObject
      ..itemKey = itemKey
      ..roundIndex = roundIndex
      ..onMeasured = onMeasured
      ..registry = registry;
  }
}

/// [ChatRowMeasure] 的渲染对象：自身高度变化时帧末上报。
class ChatRowMeasureBox extends RenderProxyBox {
  ChatRowMeasureBox({
    required ChatItemKey itemKey,
    required this.roundIndex,
    required void Function(ChatItemKey key, double height) onMeasured,
    ChatRowRegistry? registry,
  })  :
        // ignore: prefer_initializing_formals
        _itemKey = itemKey,
        // ignore: prefer_initializing_formals
        _onMeasured = onMeasured,
        // ignore: prefer_initializing_formals
        _registry = registry;

  ChatItemKey _itemKey;

  /// 当前行的身份（登记处查询轮号时读它，随换版本 / 换分支更新）。
  ChatItemKey get itemKey => _itemKey;

  /// 当前行所属轮号（登记处直接返回它）。
  int roundIndex;

  ChatRowRegistry? _registry;

  set registry(ChatRowRegistry? value) {
    if (identical(_registry, value)) return;
    if (attached) _registry?.detach(this);
    _registry = value;
    if (attached) value?.attach(this);
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _registry?.attach(this);
  }

  @override
  void detach() {
    _registry?.detach(this);
    super.detach();
  }

  set itemKey(ChatItemKey value) {
    if (_itemKey == value) return;
    _itemKey = value;
    // 身份变了（切版本 / 换分支）：同一高度也要按新身份重新记账。
    _reportedHeight = -1;
    _scheduleReport();
  }

  void Function(ChatItemKey key, double height) _onMeasured;

  set onMeasured(void Function(ChatItemKey key, double height) value) =>
      _onMeasured = value;

  /// 上次已上报的高度；-1 = 本对象尚未上报过。
  double _reportedHeight = -1;

  /// 本帧是否已排过一次上报（同一帧多次布局只排队一次）。
  bool _reportScheduled = false;

  @override
  void performLayout() {
    super.performLayout();
    if (size.height != _reportedHeight) _scheduleReport();
  }

  void _scheduleReport() {
    if (_reportScheduled) return;
    _reportScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _reportScheduled = false;
      if (!attached) return;
      // 帧末现读：本帧后续布局可能又改过尺寸。
      final height = size.height;
      // 0 高（条目刚插入尚未量到内容）不该进账本，否则把估算模型拉偏。
      if (height <= 0) return;
      _reportedHeight = height;
      _onMeasured(_itemKey, height);
    });
  }
}
