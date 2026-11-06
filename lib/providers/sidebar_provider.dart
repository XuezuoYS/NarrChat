import 'package:flutter/foundation.dart';

import '../models/round.dart';

/// 侧边栏查看状态：
/// - 查看“当前轮次”（跟随最新一轮）；
/// - 查看“历史轮次”（固定查看某一历史轮次，历史模式侧边栏会以灰色/红色边框醒目区分）。
class SidebarProvider extends ChangeNotifier {
  /// 当前正在查看的历史轮的 uuid；null 表示查看当前轮次。
  ///
  /// R3 没有投影行 id，轮的身份就是它作为"代"的 uuid。
  String? _historyRoundUuid;

  bool get isHistoryView => _historyRoundUuid != null;

  String? get historyRoundUuid => _historyRoundUuid;

  /// 切回“当前轮次”。
  void showCurrent() {
    if (_historyRoundUuid != null) {
      _historyRoundUuid = null;
      notifyListeners();
    }
  }

  /// 点击“查看本轮侧边栏”：最新一轮视为当前轮次，其余视为历史轮次。
  void showRound(Round round, Round? latestRound) {
    final isLatest = latestRound != null && round.uuid == latestRound.uuid;
    final next = isLatest ? null : round.uuid;
    if (next != _historyRoundUuid) {
      _historyRoundUuid = next;
      notifyListeners();
    }
  }
}
