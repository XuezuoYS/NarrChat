import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/utils/triple_tap_detector.dart';

void main() {
  test('连点三次触发一次并清零', () {
    fakeAsync((async) {
      var opened = 0;
      final detector = TripleTapDetector(onTripleTap: () => opened++);
      detector.tap();
      detector.tap();
      detector.tap();
      expect(opened, 1);
      // 第三次后清零，需重新累计三次。
      detector.tap();
      detector.tap();
      expect(opened, 1);
      detector.dispose();
    });
  });

  test('超过窗口未满三次则重置计数，再需连续三次', () {
    fakeAsync((async) {
      var opened = 0;
      final detector = TripleTapDetector(onTripleTap: () => opened++);
      detector.tap();
      detector.tap();
      // 超过窗口，计数器应被重置。
      async.elapse(const Duration(milliseconds: 900));
      detector.tap();
      detector.tap();
      expect(opened, 0);
      detector.tap();
      expect(opened, 1);
      detector.dispose();
    });
  });

  test('dispose 取消失效计时器且不抛错', () {
    fakeAsync((async) {
      var opened = 0;
      final detector = TripleTapDetector(onTripleTap: () => opened++);
      detector.tap();
      detector.dispose();
      async.elapse(const Duration(milliseconds: 900));
      detector.tap();
      expect(opened, 0);
    });
  });
}
