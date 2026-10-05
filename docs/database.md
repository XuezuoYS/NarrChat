# 数据库说明（NarrChat）

> **文档定位**：**持久追踪**的数据库说明书——表 / 列 / 索引 / 数据字典、业务不变量与边界语义、
> 迁移工程约定、同步与备份中的数据库、测试锚点。**随每次 schema 变更就地更新**，不是某个版本的快照。
> - **变更历史、逐版本注意事项、迁移红线**：见 `docs/database_update_log.md`（只追加台账）
> - **权威来源**：`lib/database/database_helper.dart`（DDL 与迁移）、`lib/database/*_dao.dart`（读写）
> - 表中形如 `（v12 加列）` 的标记是**引入版本**（便于回溯），细节见变更日志
> - 若本文与代码不一致：**以代码为准**，并回来修本文与变更日志

---

## 1. 概览

| 项 | 值 |
| --- | --- |
| 引擎 | SQLite（Android/iOS：`sqflite` 原生插件；Windows/Linux/macOS：`sqflite_common_ffi`，见 `DatabaseHelper._open()`） |
| 当前 schema 版本 | **19**（`DatabaseHelper._dbVersion` / `currentDbVersion`；随每次 schema 变更就地更新，历史见 `docs/database_update_log.md`） |
| 库文件 | `<系统文档目录>/NarrChat/user_data/narrchat.db`（`AppPaths.userDatabasePath()`；测试可注入 `DatabaseHelper.debugDatabasePathOverride`） |
| 访问入口 | `DatabaseHelper.instance.database`（单例，`onConfigure` 里 `PRAGMA foreign_keys = ON`） |
| 表数量 | 9 张业务/同步表 + `sqlite_sequence` |
| 恢复点 | 云端快照 `narrchat_snapshot_g<gen>_<yyyyMMdd_HHmmss>.db`（`keepVersions` 默认 **5**） |

数据分层的硬约定（见 `AGENTS.md`）：

| 类别 | 位置 | 是否云同步 |
| --- | --- | --- |
| 用户数据 | `user_data/narrchat.db`（书籍、轮次、版本树、Mod、世界书） | ✅ 走云同步（部件级） |
| 本地数据 | `local_config/*.json`（见 §3） | ❌ 不云同步 |
| 令牌（AI / WebDAV） | 系统密钥库（`flutter_secure_storage`） | ❌ 禁止明文、禁止入云 |

---

## 2. 版本号与降级行为（重要）

- `user_version` 即 schema 版本，代码期望值 = `DatabaseHelper.currentDbVersion`（19）。
  调试页「数据库检查」会并列展示「代码期望版本 vs `user_version`」，用于定位回退问题。
- **老客户端（低版本）打开新库不会报错**：sqflite 在 `options.version < oldVersion` 时**什么都不做**，
  随后把 `user_version` 写回低版本 → schema 与数据原样保留。
  这带来两条硬要求（见 §5）：
  1. **迁移必须幂等**：再次升级时列/表可能已存在；
  2. **绝不能在迁移里抛异常**：`onUpgrade` 失败 = 每次启动都失败，用户无法自救。
- 库的版本号与 app 版本解耦：**一次发版可能跨多个 DB 版本**（例如 2.0.0 从 v9 直接升到 v16）。
  对应关系见 `docs/database_update_log.md` 的总表。

---

## 3. 数据库之外的"数据库相关文件"

| 文件 | 位置 | 作用 |
| --- | --- | --- |
| `app_settings.json` | `local_config/` | 本地设置（AI / UI / 实验性开关等），`LocalConfigService` |
| `round_warnings.json` | `local_config/` | 轮次常驻「黄框」警告（本地提示，不入库、不云同步），`FileRoundWarningsStore` |
| `db_fingerprint.json` | `local_config/` | 库文件基线（`size` + `mtimeMs` + `updatedAt`），`DbFingerprintStore`：启动发现不一致 → 全量采纳一次（**不做整库哈希**） |
| `img_tombstones.json` | `local_config/` + 云端 | 图片删除墓碑（工作副本 + 云端同一文件），`ImgTombstones` |
| `manifest.json` | 云端（WebDAV 根） | 同步清单：代数、各部件指纹、图片清单 |
| `sync_config.json` | 云端 | 同步配置（`keepVersions`，默认 5） |
| `narrchat.db` 快照 | 云端 | `narrchat_snapshot_g<gen>_<yyyyMMdd_HHmmss>.db`，按 `keepVersions` 保留份数 |

---

## 4. 表清单

| 表 | 主键 | 用途 | 云同步部件 |
| --- | --- | --- | --- |
| `books` | `uuid` | 书籍：设置、失败条目、写时间戳、软删墓碑 | 设置部件 / 轮次部件（失败列与时间戳） |
| `rounds` | `id`（自增） | **轮次投影**（读权威）：当前生效的每一轮 | 轮次部件 |
| `round_stack` | `uuid` | **版本树**：每一轮的历次生成（"代"） | 轮次部件（摘要折入） |
| `world_book_entries` | `id`（自增） | 世界书条目 | 设置部件 |
| `mods` | `uuid` | 用户 Mod（提示词内容包） | Mod 部件 |
| `book_mods` | `id`（自增） | 书籍 ↔ Mod 挂载与顺序（含预置 Mod） | 设置部件 |
| `sync_state` | `id`（恒 1） | 本机同步状态：设备 id、上次同步时间/代数、进行中标记、上次阶段/错误 | ❌ 本地 |
| `sync_book_base` | `uuid` | 三向合并共基（per-book 各部件指纹） | ❌ 本地 |
| `sync_mod_base` | `uuid` | 三向合并共基（per-mod 指纹） | ❌ 本地 |

> 图片删除墓碑**不在数据库**（已文件化，见 §3）；早期开发库的 `sync_pending_del` /
> `sync_image_revived` 两张表在 v16 迁移里被无条件 `DROP`，现行 schema 从不创建它们。

---

## 5. 逐表数据字典

> 括号内为迁移新增列的落位提示：**迁移用 `ALTER TABLE ADD COLUMN`，列会追加到表尾**；
> 因此「老库迁移产物」与「全新安装库」的**列顺序可能不同**（类型 / 非空 / 默认值必须一致，测试用例按此口径断言）。

### 5.1 `books`（身份 = `uuid`）

| 列 | 类型 | 约束 | 说明 |
| --- | --- | --- | --- |
| `uuid` | TEXT | PK | 跨设备稳定身份；**无第二个自增 id** |
| `title` | TEXT | NOT NULL | 书名（同步中仅供展示／同名匹配，从不作身份） |
| `category` | TEXT | DEFAULT `''` | 分类 |
| `base_setting` | TEXT | DEFAULT `''` | 基础设定 |
| `writing_requirements` | TEXT | DEFAULT `''` | 文笔要求（v4 加列） |
| `writing_style` | TEXT | DEFAULT `''` | 文笔参考范文 |
| `global_pre_prompt` | TEXT | DEFAULT `''` | 全局前置提示 |
| `global_post_prompt` | TEXT | DEFAULT `''` | 全局后置提示 |
| `history_rounds` | INTEGER | NOT NULL DEFAULT 1 | 提示词携带的历史轮数 |
| `memory_summary_rounds` | INTEGER | NOT NULL DEFAULT 0 | 记忆总结压缩档位（0 = 关闭；v18 加列） |
| `role_hierarchy` | TEXT | DEFAULT `''` | 角色层级 |
| `role_hierarchy_detail` | TEXT | DEFAULT `''` | 角色层级详细描述格式（v3 加列） |
| `failed_user_input` | TEXT | DEFAULT `''` | 失败条目：用户输入（v8 加列） |
| `failed_error_message` | TEXT | DEFAULT `''` | 失败条目：失败原因（v8 加列） |
| `failed_user_images` | TEXT | NOT NULL DEFAULT `'[]'` | 失败条目图片（JSON 数组，v11 加列） |
| `settings_updated_at` | INTEGER | NOT NULL DEFAULT 0 | 设置部件写时间戳（epoch ms，v12 加列） |
| `rounds_updated_at` | INTEGER | NOT NULL DEFAULT 0 | 轮次部件写时间戳（epoch ms，v12 加列） |
| `deleted_at` | INTEGER | NULL | 软删墓碑（同步删除传播用；硬删走 `BookDao.deleteBook`） |

失败条目（`failed_*`）**严格沿用旧行为**：生成失败/中断只写这三列，**不写 `rounds`、不写 `round_stack`**；
任何轮次操作（生成 / 编辑 / 切换 / 删除）先清空它。

### 5.2 `rounds`（轮次投影 = 读权威）

| 列 | 类型 | 约束 | 说明 |
| --- | --- | --- | --- |
| `id` | INTEGER | PK AUTOINCREMENT | 本地行标识，**同步从不引用**（投影重建会换 id） |
| `book_uuid` | TEXT | NOT NULL, FK → `books.uuid` ON DELETE CASCADE | 所属书 |
| `round_index` | INTEGER | NOT NULL | 轮号（**允许断裂**：删中间轮后不重编号；第零轮 = 初始状态，不展示为气泡） |
| `user_input` / `ai_narrative` / `world_state` / `character_state` / `memory_summary` / `current_time` / `recommended_action` | TEXT | DEFAULT `''` | 轮次内容 |
| `tokens_in` / `tokens_out` / `cached_tokens_in` | INTEGER | NULL | Token 用量；**`NULL` = 无数据**，`0` = 真实 0（v17 起可空） |
| `model_name` | TEXT | DEFAULT `''` | 本轮实际模型名（v9 加列） |
| `user_images` / `ai_images` | TEXT | NOT NULL DEFAULT `'[]'` | 图片相对路径 JSON 数组（v10 加列） |
| `created_at` | DATETIME | NULL | **ISO8601 文本**；首页「最近对话」取 `MAX(created_at)` |
| `updated_at` | INTEGER | NOT NULL DEFAULT 0 | 编辑刷新（epoch ms；只写不读） |
| `use_stack_uuid` | TEXT | DEFAULT `''` | **v19 加列**：本行对应的 `round_stack` 行（当前应用代）；`''` = 待采纳 |

- 一轮**最多一行**（`RoundDao.upsertProjectionRow` 先按 `(book_uuid, round_index)` 删再插）。
- 类型陷阱：`created_at` 是 **ISO8601 文本**，而版本树的 `round_created_at` 是 **epoch ms**；
  两者互转只在 `RoundStackRow.fromRound` / `toRound` 一处完成（`ms <= 0` ↔ `NULL`）。

### 5.3 `round_stack`（版本树；v19 引入）

| 列 | 类型 | 约束 | 说明 |
| --- | --- | --- | --- |
| `uuid` | TEXT | PK | 本代身份（跨设备稳定，参与同步摘要） |
| `book_uuid` | TEXT | NOT NULL, FK → `books.uuid` ON DELETE CASCADE | 所属书 |
| `father_uuid` | TEXT | NULL | 上一轮**当时活动代**的 uuid；`NULL`/空串 = 根（链首）。**刻意不建自引用外键** |
| `round_index` | INTEGER | NOT NULL | 本代所属轮号 |
| `round_serial_num` | INTEGER | NOT NULL | 分组内序号（可跳步；物理删除后**允许复用**） |
| `round_state` | TEXT | NULL | `'use'` = 分组内选中记忆；`NULL` = 闲置（无第三态，删除即物理删除） |
| `round_created_at` | INTEGER | NOT NULL DEFAULT 0 | 本代创建时间（epoch ms；**不参与任何指纹**；0 = 无） |
| 内容列 | — | 与 `rounds` 同形 | `user_input` … `recommended_action`、`tokens_*`、`model_name`、`user_images`、`ai_images` |

**不变量与规则**（实现见 `lib/services/round_stack_service.dart`）：

1. **读权威在 `rounds`**：所有读取路径（开书 / 生成 / 提示词 / 侧栏 / 老客户端）只依赖 `rounds`；
   `round_stack` 只在切换、采纳、元数据查询时参与。
2. **锚定**：`rounds[i].use_stack_uuid` 指向第 `i` 轮的"当前应用代"；空锚点 = 待采纳。
3. **父子一致**：某轮的父锚点 = **最近存在的更早一轮**的当前代 uuid（**轮号可断裂**，
   例：轮号 `1,2,50` 时第 50 轮的父是第 2 轮）；仅当**前面不存在任何轮次**时才为 `NULL`（根）。
4. **分组唯一 use**：同一 `(book_uuid, round_index, father_uuid)` 内至多一个 `'use'`
   （由归一化自愈保证；**不建数据库唯一索引**，因为要求容忍脏数据并自愈）。
5. **序号复用**：同分组内 `round_serial_num` 唯一即可，物理删除后会复用旧号；身份一律靠 `uuid`。
6. **根是合法行**：`father_uuid IS NULL`（或空串）表示"本代没有父"，**不参与孤儿清理**；
   孤儿规则只作用于"**非空但查不到**"的父亲引用（视为该父已删除 → 本代不可达 → 物理清理）。
   **休眠根**：曾为根、后来该轮被重新挂到更早一轮之下的代会保留在库中但不可达（占存储、参与摘要），
   刻意不回收——"前面的轮次被删掉后它又会重新可达"。
7. **活动链（`planChain`）**：从某代起逐轮向下取"分组内 `use`，无 `use` 取最大序号，分组为空则链结束"；
   **跳过轮号空洞**（`1 → 2 → 50`）。链结束时后续轮次从视图消失（属分支模型既定语义）。
8. **采纳（`rounds` 为准）**：只在三处触发——① 联网同步；② 导入 db 文件；③ 启动时库指纹变化。
   采纳 = 内容比对 → **同内容复用现有代（不新建）/ 未命中新建代** + 缺口子树删除 + 归一化 + 孤儿清理。
   `loadRounds` 每次都调，但走**廉价路径**（只读元数据列，仅"空锚点 / 悬空锚点"才真正工作）。
9. **归一化只允许三处执行**：采纳末尾、切换开始前（单分组）、删除收尾。
   **绝不进 build / 流式帧**；结果必须"同输入同输出"（否则多设备互相推送抖动）。
10. **失败态不写这两张表**（只写 `books.failed_*`）。
11. **边界语义（已知且刻意，不是 bug）**：
    - **"视图消失"是分支模型的既定语义**：活动链在某处结束时，其后轮次从视图消失，但**内容仍在版本树里**，
      切回原父即原样回来（"随父一起切换"）。
    - **轮号断裂下"刷新本轮"**：删掉该轮起的投影行后，新代按投影尾号 +1 落位（可能回落到空洞处），
      原轮号的那一代会被**遮蔽**（保留在库、不可达）；如需彻底消除，需给生成路径加"显式轮号"。
    - **老客户端删轮**：只删"匹配到的父"下的子树，父不匹配的其它分支保留（切回那个父时后续轮次仍会出现）。
    - **同一父分组内序号可跳步**（物理删除后复用旧号）：对外只暴露"第 x 代 / 最新第 y 代"，不写"共 N 版"。

**投影重建**（切换后）：单事务内 `DELETE rounds WHERE book_uuid=? AND round_index>=i`
→ 按活动链插入（内容取版本树行、`use_stack_uuid` = 该行 uuid、`created_at` = `round_created_at`、
`updated_at` = now）→ `touchBook(rounds: true)`。
**注意**：投影重建会改变 `rounds.id`，因此 `DatabaseHelper` 之外的内存缓存**不得以 `rounds.id`
为键**。RAW 时间线的落法：本体按**代**保存（`use_stack_uuid`，`_rawByGeneration`），另用
「行 id → 代键」的索引（`_rawKeyByRoundId`，随每次投影更新重建）对外维持按行 id 取用的接口；
因此**重载 / 编辑 / 切代都不再需要清空 RAW**，只有**换书**才整体清理（跨书误配防护）。
（v19 早期实现是"每次 `loadRounds` 全清"，代价是入口随数据一起消失——见
`test/round_return_versions_test.dart` 的 RAW 归属用例。）

### 5.4 `world_book_entries`

`id` PK AUTOINCREMENT；`book_uuid`（NOT NULL, FK → `books.uuid` CASCADE）；`keyword` NOT NULL；
`content` DEFAULT `''`；`is_active` NOT NULL DEFAULT 1；`created_at` DATETIME；`updated_at` NOT NULL DEFAULT 0（v12 加列）。

### 5.5 `mods` / `book_mods`

- `mods`：`uuid` PK；`name` NOT NULL；`description` / `pre_prompt` / `post_prompt` / `system_prompt` / `world_book` DEFAULT `''`；`created_at` / `updated_at` DATETIME；`deleted_at` INTEGER（软删墓碑，v12 加列）。
- `book_mods`：`id` PK AUTOINCREMENT；`book_uuid`（FK → `books.uuid` CASCADE）；`preset_key`（预置 Mod 用键）；`mod_uuid`（用户 Mod，**预置行为 NULL**，FK → `mods.uuid` CASCADE）；`sort_order` NOT NULL DEFAULT 0；`is_enabled` NOT NULL DEFAULT 1。

### 5.6 同步辅助表（都是**本地**数据，不入云）

- `sync_state`：单行（`id INTEGER PRIMARY KEY CHECK (id = 1)`）；`device_id` / `last_synced_at` /
  `last_generation` / `sync_in_flight` / `last_phase` / `last_error`。
- `sync_book_base`：`uuid` PK + `title`（仅展示）+ 各部件共基指纹
  （`info_fp` / `roles_fp` / `base_setting_fp` / `prompts_fp` / `failed_fp` / `settings_fp` /
  `rounds_fp` / `worldbook_fp` / `bookmods_fp`）+ 四个写时间戳。
  **`rounds_fp` 里折进了 `round_stack` 摘要**（见 §6）。
- `sync_mod_base`：`uuid` PK + `name` + `fingerprint` + `updated_at`。

---

## 6. 索引

| 索引 | 表 | 定义 | 用途 |
| --- | --- | --- | --- |
| `idx_rounds_book_index` | `rounds` | `(book_uuid, round_index)` | 开书读轮次 / 按轮定位 |
| `idx_world_book_book_uuid` | `world_book_entries` | `(book_uuid)` | 世界书按书读 |
| `idx_book_mods_book_uuid` | `book_mods` | `(book_uuid)` | 书-Mod 挂载按书读 |
| `ix_stack_group` | `round_stack` | `(book_uuid, round_index, father_uuid, round_serial_num)` | **分组查询 / 序号分配**（切换与归一化的热路径；`EXPLAIN QUERY PLAN` 用例锁定） |
| `ix_stack_father` | `round_stack` | `(father_uuid)` | 按父检索（后代 / 孤儿） |
| `ix_stack_book` | `round_stack` | `(book_uuid, round_index)` | 按书 + 轮号批量读 |

主键各自带 `sqlite_autoindex_*`。**没有** `idx_books_uuid` / `idx_mods_uuid`：v13 曾在 uuid 还是普通列时建过，
v16 把 uuid 升为 PK 后（重建表）它们已消失——新装库与迁移库都不存在，无需依赖。

---

## 7. 同步 / 备份中的数据库

**部件划分**：① 书籍设置（`books` 设置列 + `world_book_entries` + `book_mods`）；
② 轮次（`rounds` + `books.failed_*` + **`round_stack` 摘要**）；③ Mod（`mods`）。
`round_stack` **不另立同步部件**，与 `rounds` 同属「轮次部件」（版本链与轮次世系强耦合）。

- **指纹**：`SyncFingerprint.roundsWithFailed(rows, bookRow, {stackRows})` 的聚合串含
  `rounds` / `failed` / 新增的 `stack` 键；`stackDigest` 按 `(round_index, father_uuid, round_serial_num, uuid)`
  稳定排序后 sha256，**排除 `round_created_at`**（时间戳会随保存刷新）。
  老客户端只读 `rounds` 键，多余键天然忽略 → 相容。
- **快照兼容**：远端快照 / 老备份库可能**没有 `round_stack` 表** → 先 `sqlite_master` 守卫，
  缺表时**保留本地**版本树，交由采纳按 `rounds` 收敛。
- **整本复制 / 部件下发**：有该表时连版本树一起复制或整体替换（先清后插，按 `round_index ASC`）。
- **本地库导入（备份合并）**：「内容部件采用导入」与「整本导入」都会搬运版本树；
  老备份无表 → 保留本地 stack；合并决策页每侧显示只读代次标签（`versionLabel`）。
- **图片平面**：`cloud_sync_provider._referencedImages()` 把 `round_stack` 的图片也计入引用集，
  避免"只被历史代引用"的图被图片同步当垃圾删除（切回旧代会裂图）。
- **自动同步触发**：生成、删除轮次触发；**采纳与切换不触发**（采纳的调用方本身就是触发节点；
  切换只改投影锚点、内容权威未变，靠下一次节点带走）。白名单见 `docs/sync_auto_triggers.md`。

**存储代价与容量（既定事实，不随版本变动）**：

- **双存储**：`round_stack` 每代各存一份全文（与 `rounds` 的"当前代"重复），并随整库快照上云
  （`keepVersions` 默认 5）→ 存储随"改写次数"乘性增长，这是本功能的**已知代价**。
- **暂不做裁剪**：结构已预留——`round_created_at`（按时间淘汰）+ `round_state`（是否在用）。
  将来引入裁剪时**只动版本树**，不改 `rounds`（读权威不变），且必须保持"切换可得旧代"的语义边界。
- **序号复用**：物理删除后 `max+1` 会复用旧号（身份靠 `uuid`），不引入分配器。
- **无自引用外键**：无数据库级引用完整性，正确性靠"根守卫 + 孤儿规则 + `purgeOrphans`"（见 §5.3）。

---

## 8. 迁移工程约定（写新迁移前必读）

1. **只增不改**：默认只 `CREATE TABLE IF NOT EXISTS` + `ADD COLUMN`；
   不改既有列语义、不改写既有行（`rounds` 的两次重建见更新日志的 v8 / v16 / v17）。
2. **幂等**：`IF NOT EXISTS`；加列前用 `_addColumnIfMissing`（`PRAGMA table_info` 预检）。
   理由：老客户端会把 `user_version` 写回低版本，再次升级时列/表可能已存在。
3. **迁移内绝不抛异常**：一旦抛，`onUpgrade` 每次启动都失败 → 库永久打不开。
4. **新装库 ≡ 迁移库**：DDL 必须复用同一 helper（`@S@` / `@B@` 占位符机制），
   `onCreate` 与 `migrate` 不许各写一份。列顺序允许不同（老库靠 `ADD COLUMN` 落到表尾）。
5. **表级约束变化只能重建**（SQLite 不能改 `NOT NULL`）：`*_new` 建表 → 拷贝 → 子表先 DROP →
   RENAME 父→子；`PRAGMA foreign_keys = ON` 下事务内无法关闭外键，外键**只能指向 `*_new` 表**。
6. **版本号与发版解耦**：一次发版可跨多个 DB 版本；`_dbVersion` 只在 schema 变化时 +1。
7. **不改** `release.yaml` / `update_log.md`（未经明确许可）。
8. 每次 schema 变更都要：更新本文 §1（版本号）/ §4–§6（表 / 字典 / 索引）/ §9（测试锚点）
   + 在 `docs/database_update_log.md` 追加一条（含总表与条目）+ 补迁移测试。

---

## 9. 测试锚点

| 测试文件 | 覆盖 |
| --- | --- |
| `test/database_migration_test.dart` | 逐版本迁移分支、**迁移产物 ≡ 新装库 DDL**、幂等重跑、**降级回退后重升**、数据零改写、外键顺序陷阱 |
| `test/round_stack_dao_test.dart` | 分组读写、序号分配 / 复用、use 落库、物理删除、整体替换排序、根口径（`NULL` ≡ 空串）、索引命中（`EXPLAIN QUERY PLAN`）、删书无孤儿、删软墓碑清 stack |
| `test/round_stack_model_test.dart` | 版本树模型 ↔ 库列互转（时间戳 ms ↔ ISO、空父亲归一化、`use` 状态）、`Round.useStackUuid` 往返 |
| `test/round_stack_service_test.dart` | 归一化、活动链、投影重建、生成 / 原地改 / 切换 / 删除 / 孤儿清理、断裂轮号上溯与跳空洞 |
| `test/round_stack_adoption_test.dart` | 采纳：复用同内容代、新建代、删除匹配到的父、缺父一律新建、链式重建、幂等、根懒建、断裂轮号 |
| `test/sync_*_test.dart` / `test/remote_snapshot_applier_test.dart` / `test/database_merge_*_test.dart` | 摘要指纹、读取快照、整本复制 / 部件下发 / 老快照守卫、合并搬运与代次标签 |
| `test/round_return_versions_test.dart` / `test/chat_round_version_test.dart` / `test/round_version_stepper_test.dart` / `test/floor_jump_test.dart` | Provider 版本索引 / 切换 / 失败态还原、UI 控件与滚动锚点、楼层跳转高度缓存失效 |

跑法：`flutter test`（全量）；单文件 `flutter test test/<文件>`。

