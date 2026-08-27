import 'package:flutter_test/flutter_test.dart';
import 'package:narrchat/services/sync/sync_image_planner.dart';

/// 图片同步规划测试：内容寻址 + 显式删除传播 + "再添加复活不被吃掉"。
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
      expect(plan.revived, isEmpty);
    });

    test('云端有而本地缺 → 拉取', () {
      final plan = ImageSyncPlanner.plan(
        referencedImages: const ['img/c.png'],
        cloudImages: const ['img/c.png'],
        localImages: const [],
        tombstones: const [],
      );
      expect(plan.toPull, ['img/c.png']);
    });

    test('显式删除且未被引用 → 删除云端，不再被其它端拉取', () {
      final plan = ImageSyncPlanner.plan(
        referencedImages: const ['img/a.png'],
        cloudImages: const ['img/a.png', 'img/b.png'],
        localImages: const ['img/a.png'],
        tombstones: const ['img/b.png'],
      );
      expect(plan.toDeleteCloud, ['img/b.png']);
      expect(plan.toPull, isEmpty); // b 被墓碑删除，不拉取
      expect(plan.revived, isEmpty);
    });

    test('被引用时就算之前删除 → 复活：撤销墓碑并重新上传（不被吃掉）', () {
      final plan = ImageSyncPlanner.plan(
        referencedImages: const ['img/b.png'], // 再次添加后重新被引用
        cloudImages: const ['img/a.png'],
        localImages: const ['img/b.png'],
        tombstones: const ['img/b.png'], // 之前被删除
      );
      expect(plan.revived, ['img/b.png']);
      expect(plan.toUpload, ['img/b.png']);
      expect(plan.toDeleteCloud, isEmpty); // 不再删除
    });

    test('已删除且其它设备仍在本地引用 → 按删除传播，仍不复活', () {
      final plan = ImageSyncPlanner.plan(
        referencedImages: const ['img/a.png'], // a 仍被引用
        cloudImages: const ['img/a.png'],
        localImages: const ['img/a.png'],
        tombstones: const ['img/b.png'], // b 已删除
      );
      expect(plan.toDeleteCloud, ['img/b.png']);
      expect(plan.toUpload, isEmpty);
    });
  });
}
