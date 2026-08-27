import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/sync/sync_bootstrapper.dart';

/// 首次连接分支判定测试。
void main() {
  test('仅本地有 → 初始化云端', () {
    expect(
      SyncBootstrapper.decide(localHasData: true, cloudHasData: false),
      SyncBootstrapDecision.initCloud,
    );
  });

  test('仅云端有 → 拉取云端', () {
    expect(
      SyncBootstrapper.decide(localHasData: false, cloudHasData: true),
      SyncBootstrapDecision.pullCloud,
    );
  });

  test('双方都有 → 默认双端合并', () {
    expect(
      SyncBootstrapper.decide(localHasData: true, cloudHasData: true),
      SyncBootstrapDecision.mergeBoth,
    );
  });

  test('都无 → 无可同步', () {
    expect(
      SyncBootstrapper.decide(localHasData: false, cloudHasData: false),
      SyncBootstrapDecision.nothing,
    );
  });
}
