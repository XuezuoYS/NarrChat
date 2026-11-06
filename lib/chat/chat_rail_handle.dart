import 'package:flutter/foundation.dart';

/// 轨道的展开 / 收起开关（外部可驱动）。
///
/// 需要它是因为"点消息区任意处收起""Esc 收起"这两个入口都在页面里，而展开状态
/// 住在轨道内部。页面持有一个 handle，轨道监听它；轨道自己点开 / 收起时也回写
/// 同一个 handle，双方看到的是同一个状态。
class ChatRailHandle extends ChangeNotifier {
  bool _expanded = false;

  /// 面板是否展开。
  bool get expanded => _expanded;

  set expanded(bool value) {
    if (_expanded == value) return;
    _expanded = value;
    notifyListeners();
  }

  void expand() => expanded = true;

  void collapse() => expanded = false;

  void toggle() => expanded = !_expanded;
}
