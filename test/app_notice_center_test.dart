import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/models/app_notice.dart';
import 'package:narrchat/services/app_notice_center.dart';

/// [AppNoticeCenter] 的隔离测试：单槽位 FIFO、同文案去重、上限淘汰、
/// 驻留到点进入退出动画、点击/划过提前退出、兜底移除。
void main() {
  /// 进入动画 + 默认驻留：驻留计时从入队时刻起算（含进入动画）。
  final fullDwell = AppNoticeCenter.enterDuration + AppNoticeCenter.defaultDwell;

  test('单槽位：新条目排队，前一条移除后接上下一条', () {
    final center = AppNoticeCenter();
    center.show('第一条');
    center.show('第二条');
    center.show('第三条');

    expect(center.current?.message, '第一条');
    expect(center.pendingCount, 2);

    center.completeDismissal(center.current!.id);
    expect(center.current?.message, '第二条');
    expect(center.pendingCount, 1);

    center.completeDismissal(center.current!.id);
    expect(center.current?.message, '第三条');
    expect(center.pendingCount, 0);
    center.dispose();
  });

  test('空白文案不入队', () {
    final center = AppNoticeCenter();
    center.show('');
    center.show('   ');
    expect(center.current, isNull);
    expect(center.pendingCount, 0);
    center.dispose();
  });

  test('去重：同文案正在显示时重置驻留计时，不新增条目', () {
    fakeAsync((async) {
      final center = AppNoticeCenter();
      center.show('已复制');
      expect(center.pendingCount, 0);

      // 第 3 秒（尚未到 3.2s 到点）再复制一次：计时重置。
      async.elapse(AppNoticeCenter.enterDuration + const Duration(seconds: 2));
      expect(center.isExiting, isFalse);
      center.show('已复制');
      expect(center.pendingCount, 0, reason: '不叠加新条目');

      // 重置后须再等满一个「进入 + 驻留」才进入退出动画。
      async.elapse(fullDwell);
      expect(center.isExiting, isTrue);
      center.dispose();
    });
  });

  test('去重：仍在队列中的同文案被忽略', () {
    final center = AppNoticeCenter();
    center.show('A');
    center.show('B');
    center.show('B');
    expect(center.pendingCount, 1);
    center.dispose();
  });

  test('队列上限：超出时丢弃最旧的一条', () {
    final center = AppNoticeCenter();
    for (var i = 0; i < AppNoticeCenter.maxPending + 2; i++) {
      center.show('消息$i');
    }
    expect(center.current?.message, '消息0');
    expect(center.pendingCount, AppNoticeCenter.maxPending);
    // 入队过程中最旧的待显示条目（消息1）已被丢弃 → 队首是消息2。
    center.completeDismissal(center.current!.id);
    expect(center.current?.message, '消息2');
    center.dispose();
  });

  test('驻留到点自动进入退出动画，宿主回报后移除', () {
    fakeAsync((async) {
      final center = AppNoticeCenter();
      center.show('已保存', kind: NoticeKind.success);

      async.elapse(fullDwell - const Duration(milliseconds: 1));
      expect(center.isExiting, isFalse, reason: '未到驻留时长不提前消失');

      async.elapse(const Duration(milliseconds: 1));
      expect(center.isExiting, isTrue);

      final id = center.current!.id;
      center.completeDismissal(id);
      expect(center.current, isNull);
      center.dispose();
    });
  });

  test('dwell 可覆盖：更短的驻留时长先到点', () {
    fakeAsync((async) {
      final center = AppNoticeCenter();
      center.show('已复制', dwell: const Duration(seconds: 1));
      async.elapse(AppNoticeCenter.enterDuration + const Duration(seconds: 1));
      expect(center.isExiting, isTrue);
      center.dispose();
    });
  });

  test('点击 / 划过：dismissCurrent 立即进入退出动画，重复调用无副作用', () {
    fakeAsync((async) {
      final center = AppNoticeCenter();
      center.show('提示');
      expect(center.isExiting, isFalse);

      center.dismissCurrent();
      expect(center.isExiting, isTrue);
      center.dismissCurrent();
      expect(center.isExiting, isTrue);

      // 退出动画时长内仍在树上；播完由宿主回报移除。
      async.elapse(AppNoticeCenter.exitDuration);
      expect(center.current, isNotNull);
      center.completeDismissal(center.current!.id);
      expect(center.current, isNull);
      center.dispose();
    });
  });

  test('宿主异常（未回报）时兜底移除，不会长期常驻', () {
    fakeAsync((async) {
      final center = AppNoticeCenter();
      center.show('失败提示', kind: NoticeKind.error);
      async.elapse(fullDwell);
      expect(center.isExiting, isTrue);

      // 不调用 completeDismissal：兜底定时器到点后自行移除。
      async.elapse(AppNoticeCenter.exitDuration + const Duration(milliseconds: 500));
      expect(center.current, isNull);
      center.dispose();
    });
  });

  test('过期的 completeDismissal 不误删后来者', () {
    fakeAsync((async) {
      final center = AppNoticeCenter();
      center.show('第一条');
      center.show('第二条');
      final staleId = center.current!.id;
      center.dismissCurrent();
      center.completeDismissal(staleId);
      expect(center.current?.message, '第二条');

      // 第一条的兜底定时器到点时不得误删第二条。
      async.elapse(AppNoticeCenter.exitDuration + const Duration(seconds: 1));
      expect(center.current?.message, '第二条');
      center.dispose();
    });
  });

  test('reset 清空当前与队列', () {
    final center = AppNoticeCenter();
    center.show('A');
    center.show('B');
    center.reset();
    expect(center.current, isNull);
    expect(center.pendingCount, 0);
    expect(center.isExiting, isFalse);
    center.dispose();
  });

  test('dispose 后不再有悬挂定时器', () {
    fakeAsync((async) {
      final center = AppNoticeCenter();
      center.show('提示');
      center.dispose();
      // 无异常即通过：dispose 已取消全部定时器（否则到点会回调已释放的通知中心）。
      async.elapse(const Duration(minutes: 1));
      expect(center.isExiting, isFalse, reason: '已释放的定时器不得再推进状态');
    });
  });
}
