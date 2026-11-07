# 数据库（R3，schema 23）

> 上一个版本（单库 `narrchat.db`）已归档到 [`docs/old/database_r2.md`](old/database_r2.md)。
> 新一代设计的原始提案在 [`docs/000temp_database_next.md`](000temp_database_next.md)。

## 为什么拆库

R2 是一张库装下所有东西：书、轮次、世界书、Mod、索引缓存、同步状态。问题是
"改一本小书"和"同步一本书"都会碰到整库，书一多就越来越重。

R3 按**访问边界**拆开：目录库只回答"有哪些书"，每本书自己的数据在自己库里，
列表页永远不用为了显示书名去开 N 个库。

## 文件布局

```
user_data/                          ← 用户数据（会云同步）
  narrchat_library.db               目录库：书籍身份 + 墓碑（含删除时轮号）+ master uuid
  narrchat_mods.db                  Mod 库：用户自定义 Mod
  books/narrbook_<书uuid>.db        每本书一个库：设置 / 轮次 / 分支 / 世界书 / 启用 Mod
  img/                              图片（内容寻址：<sha256>.<ext>）

local_config/local_db/              ← 本地数据（不云同步）
  sync.db                           云备份的单元状态、冲突、图片墓碑
  library_cache.db                  目录副本（列表页读它，不开书库）
```

**关键约定**：`user_data/` 整个目录 = 一次云备份的单位集合。
`local_config/` 里没有任何用户数据，丢了最多重新同步。

## 一本书的数据在哪

| 数据 | 位置 | 谁是信源 |
| --- | --- | --- |
| 书是否存在 / 是否被删 / 删除时间与删除时轮号 | `library.books` | 目录库 |
| 书名、各种设置 | 书库的 `book_meta` | **书库**（目录与缓存都跟它对齐） |
| 列表页显示用的行 | `library_cache.book_index` | 副本，丢了能自愈重建 |
| 轮次、分支、世界书、启用的 Mod | 书库 | 书库 |

缓存是**纯副本**：`listBooks` 发现"目录里有、缓存里没有"会按目录逐本补齐，
所以导入备份后不会出现"书全没了"的假象。

## 轮次模型：分支 → 轮 → 代

```
branch（分支，默认分支不落表，用 branch_uuid = ''）
  └── round（逻辑轮，用 round_index 表示第几轮）
        └── generation（一行 = 一次生成结果，身份是 uuid）
```

- **分组键 = `(branch_uuid, round_index, father_uuid)`**：
  「同一个上文下重新生成的几个版本」才算同一组。所以"切上一轮到旧版本 → 下一轮跟着切回"
  是天然成立的，不需要额外同步逻辑。
- **活动链靠 `father_uuid` 回溯**，不看 `round_index`。`round_index` 只是给人看的编号。
- `is_using` = 组内当前选中的那一个；同组至多一个 1，读的时候会归一化自愈。
- 重新生成**不删旧代**：新代进同组并设为选中，旧代留着可以 `← / →` 切回。

### 失败与中断（方案 A）

失败**不是一个特殊占位**，就是链上的一条普通轮次：

- `message_status = 'error'`，`message` 存提示文案（空则「已中断」）；
- 用户输入与原图保留，RAW 按代 uuid 归位，点开红条仍能看请求/返回；
- **错误代不能衍生下一轮，也不能 fork** —— 先「重新生成」或删除该轮。

这样"删除失败条目""清空失败"这些概念就都消失了，链上是什么就是什么。

### 分支

- 默认分支不落表（`branch_uuid = ''`），永远排第一；
- fork 只建分支行，不复制轮次；子分支首轮 `round_index = 父代 roundIndex + 1`；
- 给模型拼上文时按 `branches.father_row` 跨分支上溯（**分叉点父代本身也算上文**），
  受 `history_rounds` 截断；父代已删时用 `father_row_shot` 兜底一轮；
- 删除分支保留子分支，父信息靠 `father_snapshot` 兜底；
- 建/改名/删分支都刷新 `updated_at` 并触发云同步（见下）。

## 两条容易踩的规则

**1. `father_uuid` 必须显式给。**
它的默认值是 `null`，而 `null` 的意思是"链首"。少传一次，那一轮就**另起一条根**，
症状是"数据没丢但看不见"——活动链只解析得出最后一轮。这条曾经真出过 bug。

**2. 刷新 `updated_at` ⟺ 触发云同步。**
只有这两种状态：要么都做（改设置 / 插轮 / 改正文 / 改提问 / 删轮 / 建改名删分支 /
改世界书 / 改 Mod），要么都不做（切版本 / 切分支 —— 它们只改 `is_using` 与 `branch_working`，
不产生新内容）。破坏这个等价关系就会出现"改了东西没上云"或"没改也疯狂同步"。

## 时间戳

固定长度 UTC 文本 `YYYY-MM-DDTHH:MM:SS.sssZ`，可以直接按字符串比较排序。
格式化与解析在 `lib/utils/timestamp_format.dart`，**不要自己拼格式**。

## 不用 WAL

云备份的单位是"一个 `.db` 文件"，WAL 会让文件分成三份（`.db` / `-wal` / `-shm`），
快照时容易拿到不一致的组合。所以统一用默认日志模式。

## 云备份（详见 `sync_auto_triggers.md`）

- **单位 = 一个 DB 文件 = 一代**：`<base>_shot-g<N>.db` + `manifest_<base>.json`；
- **备份列表按「库」分组**：顶层固定 `Library 库` → `Mod 库` → `书籍《书名》库`
  （书籍按最新一代的上传时间新 → 旧），点进二级页才列代次、做整份还原；
  已删除的书不占活书列表，末尾单独一个「已删除」入口 →「书籍回收站」；
- **摘要只按文件内容算**，且排除所有时间戳、`branch_working`、meta 身份列 ——
  否则"只是打开看了一下"也会被当成内容变更；
- **摘要 SQL 的列名一律加引号**：裸写 `current_time` 会被 SQLite 当成
  `CURRENT_TIME` 关键字（查询时刻的墙上时间），摘要每秒都变，同步就会"没改也
  +1 代"（v3.0 修过的 bug，`order` / `key` / `group` 这类保留字同理）；
- **保留份数以云端 `sync_config.json` 为唯一权威**：面板打开 / 刷新 / 每次数据面
  同步前都会读一次；读不到时本轮**不修剪**（宁可多留，绝不误删），展示框保持
  「—」而不是把默认值伪装成云端真值；
- **冲突只给整本书一个选择**（替换本地 / 保留本地 / 保留云端），不再逐部件合并；
- 不迁移旧版本云端快照，也不做"检测到旧数据"的提示。

## 删除一本书（回收站）

删除只清本机，云端留一份「最新同步」的快照，供回收站还原：

1. `library.books` 写 `deleted_at` + `deleted_round_index`（删除时全书最大轮号；
   目录行保留，供其它设备传播删除）；
2. 本机清掉：`books/narrbook_<uuid>.db`（含 sqlite 旁挂文件）、
   `library_cache` 的索引 / 高度 / 图片引用；
3. 云端整理：每本书只留最新同步的一代快照（更早的代删掉），清单只在指向
   保留代时留下；这本书不再参与推拉。自动同步开着时交给数据面（先推 library
   墓碑，再整理）；否则删除时立即尽力整理一次，失败由下一次同步兜底；
4. 墓碑随 library 同步到其它设备；其它设备拉到后清本机残留，并把云端整理成
   同一份最新代；
5. 云同步 → 云端备份列表末尾「已删除」→「书籍回收站」：每本书一行
   （书名 / UUID / 删除时间 + 轮次），可以「还原此书」（下载保留的那一代、
   清墓碑、书回到列表）或「彻底删除」（二次确认，删云端最后一份备份；
   library 墓碑保留，条目消失）；
6. 从未同步过、云端没有快照的书不进回收站（本地墓碑保留）；
7. 旧版本只打墓碑、没删文件的，启动时按墓碑扫一遍本机残留。

图片**不做引用回收**：书删了也不删图片 blob（可能被其它书 / 历史代引用），
与图片平面的既有规则一致。

## 读 R2 迁移

`lib/database/migration/r2_to_v3.dart` 负责一次性迁移：

1. 把旧库改名 `narrchat.db` → `narrchat.db.r2.bak`（若已存在则 `.after-downgrade.bak`）；
2. 旧库先按老链路升到 v21，再逐本重建书库；
3. 进度写 `local_config/migration_state.json`，失败的书可以在启动后重试；
4. 删掉旧的 `narrchat_sync.db`。

迁移只跑一次，跑完在 `migration_state.json` 里记 `done`。

## 代码地图

| 文件 | 作用 |
| --- | --- |
| `lib/database/db_schema.dart` | 五个库的 DDL **唯一来源** + 版本常量 |
| `lib/database/db_open.dart` | 开库、读版本、表/列存在性检查 |
| `lib/database/{library,mods,cache,sync}_store.dart` | 目录库 / Mod 库 / 缓存 / 同步状态 |
| `lib/database/book_db.dart` | 单本书库，**唯一写入口**（`updated_at`、`is_using` 归一化、提示截断都在这里收口） |
| `lib/database/book_db_pool.dart` | 书库连接池 |
| `lib/repositories/*.dart` | 上层门面：书 / 轮次 / 世界书 / Mod |
| `lib/services/cloud_backup/backup_book_purge.dart` | 删书后的云端处理：保留最新一代 / 彻底删除（只认墓碑驱动） |
| `lib/screens/book_recycle_bin_page.dart` | 书籍回收站：每本已删书一行，还原 / 彻底删除 |
| `lib/services/app_stores.dart` | 组装根：解析路径 → 迁移 → 开库 |
| `lib/services/app_repositories.dart` | 应用级仓库集合，provider 从这里拿数据入口 |
