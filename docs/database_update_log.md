# 数据库变更日志（NarrChat）

> **文档定位**：**只追加**的数据库台账——按 DB 版本（`user_version`）记录每一次 schema 变更：
> 改了什么、**随哪个 app 版本发布**、有哪些**破坏性 / 易踩坑**的注意点、迁移保障与测试锚点。
> - **数据库说明（表 / 列 / 索引 / 不变量与边界语义）**：见 `docs/database.md`（随变更就地更新）
> - **最新版本**：`19`（未发布，预计随 2.4.0）——最新条目即 §2 首条
> - **权威来源**：`lib/database/database_helper.dart` 的 `migrate()` 与 `_dbVersion`；历史提交可 `git log` 复核
> - app 面向用户的更新说明在 `update_log.md`（**未经明确许可不改**）；本文件只记数据库维度

---

## 0. 记录约定

- **只追加**：新变更在 §1 总表加一行、在 §2 顶部插入一条；**旧条目不回改**（除纠错，且要在条目内注明更正日期与原因）。
  条目本身也是"可持久追踪"的：写清当时的判断依据（提交号、日期、发布版本），不写"目前/暂时"这类会过期的话。
- **版本号**：`DatabaseHelper._dbVersion`，只在 schema 变化时 +1；一次 app 发版可跨多个 DB 版本。
- **"随版本发布"**：以 git tag 上该提交的 `_dbVersion` 为准（例如 `v2.0.0` 的库版本是 16）；
  未打 tag 的区间写"未单独发版（随 X）"或"未发布"。
- 标记含义：
  - 🔴 **破坏性 / 高风险**：可能丢数据、让库打不开、或让老客户端行为异常——变更前必须逐条评估；
  - 🟡 **兼容性注意**：跨版本回退、跨设备（老客户端）读写需要特别核对；
  - 🟢 **纯增量**：只加表 / 加列，不动既有数据。
- 每条都要写清：**变更 / 破坏性与注意 / 迁移保障 / 测试**（模板见 §5 checklist）。

---

## 1. 版本总表

| DB 版本 | 引入提交 | 日期 | 随 app 版本发布 | 一句话摘要 |
| --- | --- | --- | --- | --- |
| 1–3 | `16f11c0` | 2026-08-05 | ≤ 1.0.2（初始提交即 `_dbVersion = 3`） | 初始三表：`books` / `rounds` / `world_book_entries` |
| 4 | `3947c69` | 2026-08-08 | ≤ 1.0.2 | `books.writing_requirements`（文笔要求） |
| 5 | `0dff8fe` | 2026-08-09 | 1.0.2 / 1.1.0 / 1.1.2 | Mod 功能：`mods` + `book_mods` |
| 6 | `331edeb` | 2026-08-10 | 未发布 | `rounds.is_truncated`（历史中间版本） |
| 7 | `331edeb` | 2026-08-10 | 未发布 | `rounds.error_message`（历史中间版本） |
| 8 | `331edeb` | 2026-08-10 | 1.1.4 / 1.2.0 / 1.2.1 / 1.3.0 | 失败条目迁到 `books.failed_*`；**重建 `rounds`** 移除 v6/v7 列 |
| 9 | `2a3f105` | 2026-08-16 | **1.3.1** | `rounds.model_name`（每轮实际模型名） |
| — | `ff1bee7` | 2026-08-16 | 1.3.1 | 🟡 不加版本号：加列前预检列存在性（幂等修复，见 §3.1） |
| 10 | `72c41f3` | 2026-08-24 | 未单独发版（随 2.0.0） | `rounds.user_images` / `ai_images`（对话图片） |
| 11 | `3ae79a9` | 2026-08-25 | 未单独发版（随 2.0.0） | `books.failed_user_images`（失败条目图片） |
| 12 | `0f5c305` | 2026-08-28 | 未单独发版（随 2.0.0） | 云同步基础：写时间戳 / 软删列 + `sync_state` / `sync_book_base` / `sync_mod_base` |
| 13 | `0f5c305` | 2026-08-28 | 未单独发版（随 2.0.0） | `books` / `mods` 引入 `uuid` 并回填；同步表改 uuid 主键 |
| 14 | `0f5c305` | 2026-08-28 | 未单独发版（随 2.0.0） | `sync_book_base` 拆子部件指纹列（info / roles / base_setting / prompts / failed） |
| 15 | `a678874` | 2026-08-28 | **从未发布** | 图片删除改全局墓碑（该迁移分支随后被移除） |
| 16 | `65f7e7c` | 2026-08-29 | **2.0.0 / 2.1.0 / 2.1.1** | 🔴 `uuid` 即身份：重建 `books` / `mods` / `rounds` / `world_book_entries` / `book_mods`；清理遗留墓碑表 |
| 17 | `3cd241b` | 2026-09-10 | **2.2.0** | 🔴 重建 `rounds`：Token 列改可空 + 新增 `cached_tokens_in` |
| 18 | `d440029` | 2026-10-01 | **2.3.0** | `books.memory_summary_rounds`（记忆总结压缩档位） |
| 19 | `d2e5d9a` | 2026-10-05 | **未发布**（预计 2.4.0） | `round_stack` 版本树 + `rounds.use_stack_uuid`（修改还原） |

---

## 2. 逐版本条目

### v19 · 2026-10-05 · `d2e5d9a` · **未发布**（预计随 2.4.0）

**变更**
- 新表 `round_stack`（"版本树"：每一轮的历次生成各一行）+ 三索引
  `ix_stack_group` / `ix_stack_father` / `ix_stack_book`。
- `rounds` 增列 `use_stack_uuid TEXT DEFAULT ''`（本行对应的版本树行 = "当前应用代"；空 = 待采纳）。
- `BookDao.softDeleteBook` / `deleteBook` 事务内显式清 `round_stack`（外键级联兜底）。

**破坏性与注意**
- 🟢 纯增量：既有列语义不变、既有行不改写；老客户端（v18）打开 v19 库**不报错**
  （sqflite 把 `user_version` 写回 18，表/列/数据原样保留）。
- 🟡 老客户端只动 `rounds`（生成 / 编辑 / 删轮）→ 新客户端在①联网同步②导入 db③启动指纹变化
  三处跑"采纳"把版本树收敛回 `rounds` 口径；**老客户端绝不看到被隐藏的代**（隐藏数据只在
  `round_stack`，老客户端不读它）。
- 🟡 **双存储**：每代一份全文；随整库快照上云（`keepVersions` 默认 5）→ 存储乘性增长。
- 🟡 投影重建会改变 `rounds.id`：任何以 `rounds.id` 为键的内存缓存（RAW 时间线）必须随
  每次 `loadRounds` 清空。
  - **2026-10-05 更新（本条要求作废）**：RAW 时间线改为**按"代"（`use_stack_uuid`）保存**
    （`_rawByGeneration`），另用「行 id → 代键」索引（`_rawKeyByRoundId`，随投影更新重建）
    对外维持按行 id 取用的接口——因此**只有换书才清理**（重载 / 编辑 / 切代都不必清）。
    原因：投影重建本来就换行 id，按 id 存 + 每次全清会让「入口随数据一起消失」（表现为
    RAW 入口被取消）。口径见 `docs/database.md` §5.3，测试见
    `test/round_return_versions_test.dart` 的 RAW 归属用例。
- **刻意不建**：`father_uuid` 自引用外键（删除是物理删除，自引用会阻碍删父行 / 级联掉要保留的分支）、
  `round_state='delete'` 墓碑态、`format` 列、`round_stack.updated_at`。
- 归属：`round_stack` **不新增同步部件**，与 `rounds` 一起构成「轮次部件」（摘要 `stackDigest` 折入）。

**迁移保障**
- v19 = `CREATE TABLE IF NOT EXISTS round_stack`（表 + 索引同一 helper）+ `_addColumnIfMissing`
  → 幂等：`2.3 → 2.4 → 回退 2.3 → 再升 2.4` 不产生 `table already exists` / `duplicate column name`。
- 新装库与迁移库**逐字复用同一 DDL helper**；`rounds.use_stack_uuid` 写在 `CREATE TABLE` 列尾，
  与 `ALTER TABLE ADD COLUMN` 的落位一致（类型 / 非空 / 默认值一致）。
- 启动指纹（`db_fingerprint.json`，`size + mtimeMs`）发现库被外部替换 → 全量采纳一次（幂等）。

**测试**：`test/database_migration_test.dart`（v18→v19 新增内容、幂等重跑、降级回退、迁移产物 ≡ 新装库、
既有行零改写）、`test/round_stack_*_test.dart`、`test/db_fingerprint_store_test.dart`。

### v18 · 2026-10-01 · `d440029` · **2.3.0**

**变更**：`books` 增列 `memory_summary_rounds INTEGER NOT NULL DEFAULT 0`（0 = 关闭；档位 5 / 10）。
**注意**：🟢 仅加列，历史行取默认 0（不做数据迁移）；库内出现档位外数值时读出按 0 执行并在下次保存自愈回写 0。
**测试**：`test/database_migration_test.dart`（v16→v18、v18 幂等、逐列定义一致）、`test/book_dao_test.dart`。

### v17 · 2026-09-10 · `3cd241b` · **2.2.0**

**变更**
- 🔴 **重建 `rounds`**：`tokens_in` / `tokens_out` 去掉 `NOT NULL DEFAULT 0`（改可空），新增
  `cached_tokens_in`。SQLite 无法取消列上的 `NOT NULL`，只能 `*_new` 重建。
**注意**
- 🟢 数据无损：仅建表形态变化，行数据（含旧值 `0`）原样搬迁；`0` 保留"真实消耗 0"语义，`NULL` 专表"无数据"。
- 🟡 幂等靠"`cached_tokens_in` 是否存在"判断：v16 分支重建出的表已是该形状 → 跳过；
  库被降级回 v16 后重跑也不会重复建列。
- 🟡 重建后索引需手工重建（`idx_rounds_book_index`，随旧表 DROP 消失）。
**测试**：`test/database_migration_test.dart`（v16→v17、重跑幂等、rounds DDL 与新装库一致）。

### v16 · 2026-08-29 · `65f7e7c` · **2.0.0 / 2.1.0 / 2.1.1**

**变更**
- 🔴 `books` / `mods` 去掉本地 int 主键，`uuid` 成为唯一身份；子表 `rounds` /
  `world_book_entries` / `book_mods` 的 `book_id` / `mod_id` 改为 `book_uuid` / `mod_uuid`（TEXT）。
- 无条件 `DROP TABLE IF EXISTS sync_pending_del` / `sync_image_revived`（图片墓碑早已文件化）。
- 原有 `books` / `mods` 记录保留；无 uuid 的旧行补发 v4 uuid；重复 uuid 保留最小 id 行原值、其余重分配。

**破坏性与注意**
- 🔴 **外键顺序陷阱（顺序不可改）**：库以 `PRAGMA foreign_keys = ON` 打开，而 `onUpgrade` 在事务内执行、
  事务内无法关闭外键，`DROP TABLE` 会先隐式 DELETE 并触发子表 `ON DELETE CASCADE`。固定顺序：
  ① 预清洗 uuid（补空 / 去重）→ ② 建全部 `*_new`（新子表的外键**只能**指向 `books_new` / `mods_new`；
  指向旧 `books` 的 uuid 列会 `foreign key mismatch`）→ ③ 拷贝（父先子后，子表 JOIN 旧父表换 uuid，
  父行不存在的孤儿行随 JOIN 丢弃）→ ④ 按子→父 DROP 旧表 → ⑤ RENAME（先父后子）→ ⑥ 重建索引。
- 🔴 不可逆：旧客户端（≤ v15）**无法**打开 v16 库（表结构已变），此版本为跨设备兼容的分水岭。
- 🟡 子表保留自增 `id`（仅本地行号，同步从不引用）。
**测试**：`test/database_migration_test.dart`（v9/v15→v16 全链路、uuid 预清洗、外键指向与级联、
孤儿行丢弃、DDL 一致）。

### v15 · 2026-08-28 · `a678874` · **从未发布**

**变更**：图片删除改为全局墓碑机制（迁移里移除数据库待删表）。
**注意**：🟡 该版本在开发期内被 v16 直接取代（现行 `migrate()` 中**没有 v15 分支**）；
v16 分支已无条件清理那两张遗留表，因此"升级到 v16 后库内必无墓碑表"是无条件不变量。

### v12 / v13 / v14 · 2026-08-28 · `0f5c305` · **未单独发版（随 2.0.0）**

**变更**
- v12：`books` 加 `settings_updated_at` / `rounds_updated_at` / `deleted_at`；`rounds` 加 `updated_at`；
  `world_book_entries` 加 `updated_at`；`mods` 加 `deleted_at`；建同步三表（`sync_state` /
  `sync_book_base` / `sync_mod_base`）。
- v13：`books` / `mods` 加 `uuid`（NOT NULL DEFAULT `''`）并回填（**含软删 / 墓碑行**）；
  开发期遗留的旧同步表（`title` / `name` 主键）重建为 uuid 主键。
- v14：`sync_book_base` 增 5 个子部件指纹列（`info_fp` / `roles_fp` / `base_setting_fp` /
  `prompts_fp` / `failed_fp`），旧行按 `settings_fp` 整书回填（读为空即退化为旧语义，直到下次同步重写）。

**注意**
- 🟡 v13 当时 `uuid` 仍不是主键（v16 才升），所以 `idx_books_uuid` / `idx_mods_uuid` 是那个阶段的产物；
  v16 重建表后它们已消失，现行 schema 中不存在。
- 🟡 同步表只存合并元数据、非用户资产，必要时可安全重建。
**测试**：`test/database_migration_test.dart`（v11→v12、v12→v13、v13→v14）。

### v10 / v11 · 2026-08-24 / 2026-08-25 · `72c41f3` / `3ae79a9` · **未单独发版（随 2.0.0）**

**变更**：v10 `rounds` 加 `user_images` / `ai_images`（NOT NULL DEFAULT `'[]'`，JSON 相对路径数组）；
v11 `books` 加 `failed_user_images`（失败条目图片，随重试复用）。
**注意**：🟢 仅加列；图片本体在文件系统（`user_data/img/`），库里只存相对路径。

### v9 · 2026-08-16 · `2a3f105` · **1.3.1**

**变更**：`rounds` 加 `model_name TEXT DEFAULT ''`（`{{model}}` 解析后的实际模型名）。
**注意**：🟢 仅加列；这是**版本回退事故**的发生版本（1.3.1 → 回退 1.3.0 → 再升 1.3.1 时
`ALTER TABLE ADD COLUMN model_name` 报 `duplicate column name` → 库永久打不开），修复见 §3.1。
**测试**：`test/database_migration_test.dart`（"版本回退遗留"用例锁定该场景）。

### v6 / v7 / v8 · 2026-08-10 · `331edeb` · v8 随 **1.1.4 / 1.2.0 / 1.2.1 / 1.3.0**

**变更**
- v6 / v7：历史中间版本曾在 `rounds` 加失败列（`is_truncated` / `error_message`），**未发布**；
  现行分支只用于给"从更老开发库升上来"的表补齐列，以便随后重建。
- v8：失败处理重构——失败条目从 `rounds` 轮次行迁移为 `books` 上的独立条目
  （`failed_user_input` / `failed_error_message`），并**重建 `rounds`** 移除 v6/v7 两块失败列。
**注意**：🔴 重建 `rounds`（v8 时代的表以 `book_id` 引用 `books.id`）；当时 `books` 仍是 int 主键。
失败态语义自此固定为：**失败只写 `books.failed_*`，不写 `rounds`**（v19 之后同样"不写 `round_stack`"）。

### v4 / v5 · 2026-08-08 / 2026-08-09 · `3947c69` / `0dff8fe` · ≤ **1.0.2**

**变更**：v4 `books` 加 `writing_requirements`（文笔要求，区别于文笔参考 `writing_style`）；
v5 建 `mods` + `book_mods`（自定义提示词内容包与书籍关联）。
**注意**：🟢 仅加列 / 加表。

### v1 / v2 / v3 · 2026-08-05 · `16f11c0` · ≤ **1.0.2**（初始提交即 `_dbVersion = 3`）

**变更**：初始 `books` / `rounds` / `world_book_entries`；v2 分支重建早期 `world_book_entries`
（老形状 → 现行形状）；v3 加 `books.role_hierarchy_detail`。
**注意**：🟡 v1/v2 分支只为修开发期库存在，实际发布的库版本从 3 起。

---

## 3. 非版本号变更（不改 schema，但影响迁移行为）

### 3.1 `ff1bee7`（2026-08-16，随 1.3.1）· 迁移幂等修复 🔴

**问题**：老客户端（低版本）打开新库时 sqflite 只把 `user_version` 写回低版本，**列已存在**；
再次升级时 `ALTER TABLE ... ADD COLUMN` 报 `duplicate column name` → 整个库无法打开且每次启动都失败。

**修复**：所有 `ADD COLUMN` 迁移改为先 `PRAGMA table_info` 预检（`_addColumnIfMissing`），
`CREATE TABLE` 一律 `IF NOT EXISTS`。

**沉淀为红线**（见 §4）：**迁移必须幂等；迁移内绝不抛异常**。

### 3.2 `3ea4a54`（2026-09-03，随 2.1.0）· `currentDbVersion` 注解调整 🟢

移除 `@visibleForTesting` 并补注释（调试页需要读取"代码期望版本"）；无 schema 变化。

---

## 4. 迁移红线（每次改 schema 前逐条过）

1. 🔴 **幂等**：`IF NOT EXISTS` + `_addColumnIfMissing`；否则"降级回退再升级"会把库打成永久打不开。
2. 🔴 **迁移内绝不抛异常**：`onUpgrade` 失败 = 每次启动都失败，用户无法自救。
3. 🔴 **新装库 ≡ 迁移库**：DDL 复用同一 helper（`@S@` / `@B@` 占位），`onCreate` 与 `migrate` 不各写一份。
   （列顺序允许不同：老库靠 `ADD COLUMN` 落到表尾；类型 / 非空 / 默认值必须一致。）
4. 🔴 **FK 顺序**：`foreign_keys = ON` + `onUpgrade` 事务内 → 重建表时必须
   "建 `*_new`（外键只指向 `*_new`）→ 拷贝 → 子→父 DROP → 父→子 RENAME → 重建索引"。
5. 🔴 **表级约束变更只能重建**（SQLite 不能改 `NOT NULL` / 主键）。
6. 🟡 **不改既有列语义、不静默改写既有行**；需要迁移数据时写清规则（如 v13 的 uuid 回填 / 去重）。
7. 🟡 **版本号与发版解耦**：一次发版可跨多个 DB 版本；`_dbVersion` 只在 schema 变化时 +1。
8. 🟡 **2.x 内不删表、不删列**：回滚策略是"代码回退 → `user_version` 写回旧值、残留结构不被读写"。
9. 🟡 涉及同步的列/表要同步评估：部件指纹（`SyncFingerprint`）、共基（`sync_*_base`）、
   快照搬运与**老快照守卫**（远端无表时保留本地）。

---

## 5. 追加一条变更记录的流程（checklist）

1. `_dbVersion` +1，并在 `migrate()` 末尾追加 `if (oldVersion < N) { ... }`（幂等、只增）。
2. 同步更新 `onCreate` 路径（复用同一 helper），保证新装库与迁移库等价。
3. 跑 `flutter analyze` 与 `flutter test`；在 `test/database_migration_test.dart` 补：
   N-1 → N 新增内容、**迁移产物 ≡ 新装库 DDL**、**幂等重跑**、**降级回退后再升**、**既有行零改写**。
4. 更新 `docs/database.md` 的 §5（数据字典）/ §6（索引）/ §4（表清单）与 §9（测试锚点）。
5. 在本文件 §1 总表追加一行，并在 §2 写一条条目（含：变更 / 破坏性与注意 / 迁移保障 / 测试）。
6. 若涉及同步：核对 `SyncFingerprint` / 快照搬运 / 合并搬运 / 老快照守卫，并补 `test/sync_*` 用例。
7. 更新头部「最新版本」指针；**不要**回改历史条目（纠错需注明更正日期与原因）。

### 条目模板

```markdown
### vN · YYYY-MM-DD · `<短提交>` · 随 <app 版本> 发布 / 未发布

**变更**
- …

**破坏性与注意**
- 🔴/🟡/🟢 …

**迁移保障**
- 幂等 / 新装库 ≡ 迁移库 / 回退再升 / 老客户端兼容 …

**测试**：`test/…`（锁定哪条不变量）
```
