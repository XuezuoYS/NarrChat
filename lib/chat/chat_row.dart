import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'chat_item.dart';

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
    required this.onMeasured,
    required super.child,
  });

  /// 这一行的稳定身份（`轮uuid:类型`）。
  final ChatItemKey itemKey;

  /// 高度回传（帧末调用；只在这一行高度变化时调用）。
  final void Function(ChatItemKey key, double height) onMeasured;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      ChatRowMeasureBox(itemKey: itemKey, onMeasured: onMeasured);

  @override
  void updateRenderObject(
    BuildContext context,
    ChatRowMeasureBox renderObject,
  ) {
    renderObject
      ..itemKey = itemKey
      ..onMeasured = onMeasured;
  }
}

/// [ChatRowMeasure] 的渲染对象：自身高度变化时帧末上报。
class ChatRowMeasureBox extends RenderProxyBox {
  ChatRowMeasureBox({
    required ChatItemKey itemKey,
    required void Function(ChatItemKey key, double height) onMeasured,
  })  :
        // ignore: prefer_initializing_formals
        _itemKey = itemKey,
        // ignore: prefer_initializing_formals
        _onMeasured = onMeasured;

  ChatItemKey _itemKey;

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
