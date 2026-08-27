import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/sync/sync_image_planner.dart';

/// 图片同步规划测试：内容寻址 + 全局删除传播。
///
/// 复活（重新添加）不在本规划层：删除/导入流程在墓碑文件上增删条目，
/// 同步合并已抵消，规划器收到的 tombstones 即最终删除意图。
void main() {
  group('ImageSyncPlanner', () {
    test('本地新增图片 → 只上传新增、不重复上传已存在', () {
      final plan = ImageSyncPlanner.plan(
        referencedImages: const ['img/a.png', 'img/b.png'],
        cloudImages: const ['img/a.png'],
        localImages: const ['img/a.png', 'img/b.png'],
        tombstones: const [],
      );
      expect(plan.toUpload, ['img/b.png']); // 只有 b 是新的
      expect(plan.toPull, isEmpty);
      expect(plan.toDeleteCloud, isEmpty);
      expect(plan.toDeleteLocal, isEmpty);
    });

    test('云端有而本地缺 → 拉取（无墓碑）', () {
      final plan = ImageSyncPlanner.plan(
        referencedImages: const ['img/c.png'],
        cloudImages: const ['img/c.png'],
        localImages: const [],
        tombstones: const [],
      );
      expect(plan.toPull, ['img/c.png']);
      expect(plan.toUpload, isEmpty);
    });

    test('显式删除（未被引用）→ 删除云端，不再被其它端拉取', () {
      final plan = ImageSyncPlanner.plan(
        referencedImages: const ['img/a.png'],
        cloudImages: const ['img/a.png', 'img/b.png'],
        localImages: const ['img/a.png'],
        tombstones: const ['img/b.png'],
      );
      expect(plan.toDeleteCloud, ['img/b.png']);
      expect(plan.toDeleteLocal, isEmpty); // 本机无该文件，无需删本地
      expect(plan.toPull, isEmpty); // b 被墓碑删除，不拉取
      expect(plan.toUpload, isEmpty);
    });

    test('删除仍被引用（文件已删）→ 删除云端，不再复活、不再拉回', () {
      final plan = ImageSyncPlanner.plan(
        referencedImages: const ['img/b.png'], // DB 仍引用
        cloudImages: const ['img/b.png'],
        localImages: const [], // 文件已被用户删除
        tombstones: const ['img/b.png'],
      );
      expect(plan.toDeleteCloud, ['img/b.png']);
      expect(plan.toDeleteLocal, isEmpty);
      expect(plan.toPull, isEmpty); // 墓碑删除，不拉回
      expect(plan.toUpload, isEmpty);
    });

    test('删除传播：其它设备仍持有文件 → 删除云端 + 删除本地文件，不重新上传', () {
      final plan = ImageSyncPlanner.plan(
        referencedImages: const ['img/b.png'],
        cloudImages: const ['img/b.png'],
        localImages: const ['img/b.png'],
        tombstones: const ['img/b.png'],
      );
      expect(plan.toDeleteCloud, ['img/b.png']);
      expect(plan.toDeleteLocal, ['img/b.png']);
      expect(plan.toUpload, isEmpty); // 不被重新上传
    });

    test('已删除的其它图仍按删除传播，不影响保留图', () {
      final plan = ImageSyncPlanner.plan(
        referencedImages: const ['img/a.png'], // a 仍被引用
        cloudImages: const ['img/a.png', 'img/b.png'],
        localImages: const ['img/a.png'],
        tombstones: const ['img/b.png'], // b 已删除
      );
      expect(plan.toDeleteCloud, ['img/b.png']);
      expect(plan.toUpload, isEmpty);
      expect(plan.toPull, isEmpty);
    });

    test('幂等：删除已完成（云端 blob 已消失）→ 不再产生任何动作', () {
      final plan = ImageSyncPlanner.plan(
        referencedImages: const ['img/b.png'],
        cloudImages: const [], // blob 已删
        localImages: const [], // 本机文件已删
        tombstones: const ['img/b.png'], // 墓碑仍在（保留一年）
      );
      expect(plan.toDeleteCloud, isEmpty, reason: '不再重复删除已消失的 blob');
      expect(plan.toDeleteLocal, isEmpty);
      expect(plan.toUpload, isEmpty);
      expect(plan.toPull, isEmpty);
    });
  });
}
