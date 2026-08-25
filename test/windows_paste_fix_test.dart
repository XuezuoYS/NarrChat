import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/windows_paste_fix.dart';

/// 测试 [WindowsPasteFix.rewrite] 的状态机：
/// 把 Windows 11「Win+V 剪贴板历史」下发的畸形 Ctrl+V 序列重写为干净按键，
/// 并确保全零 transit-mode 探测与正常硬件按键原样透传。
void main() {
  const junkPhysical = 0x1600000000;
  const cleanPhysicalCtrl = 0x700e0;
  const cleanPhysicalV = 0x70019;
  const logicalCtrl = 0x200000100;
  const logicalV = 0x76;

  KeyData ev({
    required KeyEventType type,
    required int physical,
    required int logical,
    bool synthesized = false,
  }) {
    return KeyData(
      timeStamp: Duration.zero,
      type: type,
      physical: physical,
      logical: logical,
      character: null,
      synthesized: synthesized,
    );
  }

  WindowsPasteFix fix() => WindowsPasteFix.instance;

  setUp(fix().resetState);

  test('正常硬件按键原样透传，且复位状态机', () {
    final result = fix().rewrite(
      ev(
        type: KeyEventType.down,
        physical: cleanPhysicalV,
        logical: logicalV,
      ),
    );
    expect(result, isNotNull);
    expect(result!.physical, cleanPhysicalV);
    expect(result.logical, logicalV);
    expect(result.type, KeyEventType.down);
  });

  test('全零 transit-mode 探测必须原样透传（不能被吞）', () {
    final result = fix().rewrite(
      ev(type: KeyEventType.down, physical: 0, logical: 0),
    );
    expect(result, isNotNull);
    expect(result!.physical, 0);
    expect(result.logical, 0);
  });

  test('Win+V 畸形 6 事件序列被重写为干净 Ctrl+V（吞掉重复的 Ctrl）', () {
    final emitted = <KeyData>[];
    final swallowed = <bool>[];

    KeyData? feed(KeyData d) {
      final r = fix().rewrite(d);
      if (r == null) {
        swallowed.add(true);
      } else {
        emitted.add(r);
      }
      return r;
    }

    // 第 1 步：Ctrl down（非合成）→ 干净 Ctrl down。
    feed(ev(type: KeyEventType.down, physical: junkPhysical, logical: logicalCtrl));
    // 第 2 步：Ctrl up（合成）→ 吞掉。
    feed(ev(type: KeyEventType.up, physical: junkPhysical, logical: logicalCtrl, synthesized: true));
    // 第 3 步：V down → 干净 V down。
    feed(ev(type: KeyEventType.down, physical: junkPhysical, logical: logicalV));
    // 第 4 步：V up → 干净 V up。
    feed(ev(type: KeyEventType.up, physical: junkPhysical, logical: logicalV));
    // 第 5 步：Ctrl down（合成）→ 吞掉。
    feed(ev(type: KeyEventType.down, physical: junkPhysical, logical: logicalCtrl, synthesized: true));
    // 第 6 步：Ctrl up（合成）→ 干净 Ctrl up。
    feed(ev(type: KeyEventType.up, physical: junkPhysical, logical: logicalCtrl, synthesized: true));

    // 发出 4 个事件（Ctrl down / V down / V up / Ctrl up），吞掉 2 个重复 Ctrl。
    expect(emitted, hasLength(4));
    expect(swallowed, hasLength(2));

    expect(emitted[0].type, KeyEventType.down);
    expect(emitted[0].physical, cleanPhysicalCtrl);
    expect(emitted[0].logical, logicalCtrl);

    expect(emitted[1].type, KeyEventType.down);
    expect(emitted[1].physical, cleanPhysicalV);
    expect(emitted[1].logical, logicalV);

    expect(emitted[2].type, KeyEventType.up);
    expect(emitted[2].physical, cleanPhysicalV);
    expect(emitted[2].logical, logicalV);

    expect(emitted[3].type, KeyEventType.up);
    expect(emitted[3].physical, cleanPhysicalCtrl);
    expect(emitted[3].logical, logicalCtrl);

    // 状态机归零：一套干净 Ctrl+V 结束后可再次识别下一套序列。
    expect(fix().rewrite(
      ev(type: KeyEventType.down, physical: junkPhysical, logical: logicalCtrl),
    ), isNotNull);
  });

  test('序列被打断（缺 V-down）时复位，不再误吞后续正常按键', () {
    // 只发 Ctrl down + Ctrl up（合成），未接 V down，应视为序列被打断。
    fix().rewrite(ev(type: KeyEventType.down, physical: junkPhysical, logical: logicalCtrl));
    fix().rewrite(ev(type: KeyEventType.up, physical: junkPhysical, logical: logicalCtrl, synthesized: true));

    // 随后一个正常按键应原样透传（状态机已复位，不会误判为 junk）。
    final normal = fix().rewrite(
      ev(type: KeyEventType.down, physical: cleanPhysicalV, logical: logicalV),
    );
    expect(normal, isNotNull);
    expect(normal!.physical, cleanPhysicalV);
  });
}
