import '../models/book_meta.dart';
import '../models/branch.dart';
import '../models/round_generation.dart';
import '../models/world_book_row.dart';

/// `use_mods` 的一行：只记录**已启用**的 Mod。
class UseModRow {
  const UseModRow({required this.modUuid, this.sortOrder = 0});

  /// `mods.db` 的 `mod_uuid`；预置 Mod 为 `preset::<id>`。
  final String modUuid;

  /// 置入顺序，**顺序有意义**（影响提示词拼合顺序）。
  final int sortOrder;

  factory UseModRow.fromRow(Map<String, Object?> row) {
    return UseModRow(
      modUuid: (row['mod_uuid'] as String?) ?? '',
      sortOrder: (row['sort_order'] as int?) ?? 0,
    );
  }

  Map<String, Object?> toRow() => {
    'mod_uuid': modUuid,
    'sort_order': sortOrder,
  };
}

/// 书库元信息（`book_meta`，单行）。
abstract class BookMetaStore {
  Future<BookMeta> read();

  /// 写设置列并刷新 `updated_at`。
  Future<void> writeSettings(BookMeta meta);

  /// 只刷新 `updated_at`（轮次 / 分支 / 世界书 / Mod 挂载等变更后调用）。
  Future<void> touch();

  /// 直接指定 `updated_at`（迁移、云备份还原用，不取当前时间）。
  Future<void> setUpdatedAt(DateTime updatedAt);
}

/// 轮次（`round_stack`，唯一轮次表，一行即"一代"）。
abstract class RoundStore {
  /// 全书轻量索引：不含任何正文列。活动链、进度、跳转都基于它。
  Future<List<RoundMeta>> listMeta();

  /// 按轮号区间取正文（内容窗口）。
  ///
  /// `firstRoundIndex` / `lastRoundIndex` 为闭区间；都为 null 表示全书。
  Future<List<RoundGeneration>> listGenerations({
    int? firstRoundIndex,
    int? lastRoundIndex,
  });

  Future<RoundGeneration?> generation(String uuid);

  Future<List<RoundGeneration>> generations(Iterable<String> uuids);

  /// 插入一代。`is_using = true` 时会先把同组其它代置 0。
  Future<void> insert(RoundGeneration generation);

  /// 整批写入（迁移 / 导入专用）。
  ///
  /// 只在一个事务里插行 + 刷新一次 `updated_at`，**不做逐条组内归一化**——
  /// 调用方负责保证「同组至多一个 `is_using`」。逐条插入几千轮会慢到不可接受。
  Future<void> importAll(List<RoundGeneration> rows);

  /// 写正文列（白名单校验，禁止误改身份 / 轮号 / 组内序号）。
  Future<void> updateContent(String uuid, Map<String, Object?> content);

  /// 写元信息列（`message` / `message_status` / `operated_at` 等）。
  Future<void> updateMeta(String uuid, Map<String, Object?> fields);

  /// 组内选中切换：同组其它代置 0，[uuid] 置 [isUsing]（默认设为选中）。
  Future<void> setUsing(String uuid, {bool isUsing = true});

  /// 物理删除；不级联，子树由服务层决定。
  Future<void> delete(Iterable<String> uuids);

  /// 全书代数（调试 / 测试用）。
  Future<int> count();

  /// 全书最大轮号（删除书籍时记进 library 墓碑；空书返回 0）。
  ///
  /// 只读一列聚合，不拉正文。
  Future<int> maxRoundIndex();

  /// 最近一代的操作时间（列表"最近对话"排序用）；空书返回 null。
  ///
  /// 只读一列聚合，不拉全书正文。
  Future<DateTime?> lastRoundAt();

  /// 是否有任何一代的图片列（`user_images` / `ai_images`）引用了 [imagePath]。
  ///
  /// 供「封面被清掉 / 换掉后回收孤儿图片」判断：历史代、非活动分支都算引用，
  /// 宁可多留一张图，也不删别的剧情还在用的图。
  Future<bool> containsImage(String imagePath);
}

/// 分支（`branches`，默认分支不记表）。
abstract class BranchStore {
  Future<List<Branch>> list();

  Future<Branch?> get(String branchUuid);

  Future<void> upsert(Branch branch);

  /// 把 [branchUuid] 设为当前激活分支（其余置 0）；传空串即切回默认分支。
  Future<void> setWorking(String branchUuid);

  /// 删除分支行（该分支的轮次由服务层一并删除）。
  Future<void> delete(String branchUuid);
}

/// 世界书条目。
abstract class WorldBookStore {
  Future<List<WorldBookRow>> list();

  Future<void> upsert(WorldBookRow row);

  Future<void> delete(String uuid);

  /// 整批替换（迁移 / 导入 / 同步还原专用，单事务）。
  Future<void> replaceAll(List<WorldBookRow> rows);
}

/// 书内启用的 Mod 与顺序。
abstract class UseModStore {
  Future<List<UseModRow>> list();

  /// 整体替换（关闭 / 删除 Mod 时的清理由调用方拼出最终清单）。
  Future<void> replaceAll(List<UseModRow> rows);
}

/// 单本书的存储门面。
///
/// 这是**唯一**接触单本书库的入口：provider 只依赖本接口，测试可注入替身，
/// 真实实现是 [BookDb]。子 store 各自只做一件事，避免出现一个什么都管的巨类。
abstract class BookStore {
  String get bookUuid;

  BookMetaStore get meta;

  RoundStore get rounds;

  BranchStore get branches;

  WorldBookStore get worldBook;

  UseModStore get useMods;

  Future<void> close();
}
