# 数据库变更日志

> 本文件只记**数据结构**的变更。功能层面的更新见 `update_log.md`。
> R2 及更早的账号在 [`docs/old/database_update_log_r2.md`](old/database_update_log_r2.md)。

## schema 24 —— 书籍自定义封面（当前）

`user_data` 下的库版本从 23 升到 24。

### 新增字段

- 书库的 `book_meta` 增加 `book_cover_img TEXT`：书籍自定义封面的图片相对路径，
  格式与 `round_stack.user_images` 数组里的元素一致（`img/<哈希>.<扩展名>`）。
  允许为 NULL，NULL = 没有自定义封面，首页继续走默认封面样式。
  目前只落库，不进内容摘要、也不进列表缓存。

### 迁移

- `BookDb` 打开旧书库时执行
  `ALTER TABLE book_meta ADD COLUMN book_cover_img TEXT`；老书这一列保持 NULL。
- 书库是一本一个文件，所以每本老书在第一次打开时各自补一次列；加列前先查
  `PRAGMA table_info`，重复执行不会报 duplicate column。
- 目录库 / Mod 库的表结构没变，只把 `database_version` 镜像写成 24。

### 行为变化

- 保存书籍设置时沿用书库里已有的封面，不会把它冲成 NULL（封面进模型，
  但界面选择封面还没做）。

## schema 23 —— 删除书籍回收站（上一版）

`user_data` 下四个库的版本从 22 升到 23。

### 新增字段

- `narrchat_library.db` 的 `books` 增加 `deleted_round_index INTEGER`：
  删除一本书时记录全书最大轮号（0 = 删除时还没有轮次；NULL = 老墓碑没记）。
  只用于云同步「书籍回收站」的展示，不参与内容摘要。

### 迁移

- `LibraryDb` 打开旧库时执行
  `ALTER TABLE books ADD COLUMN deleted_round_index INTEGER`；老墓碑保持 NULL。
- 书库 / Mod 库的表结构没变，只把 `database_version` 镜像写成 23。

### 行为变化

- 删除书籍不再清空云端：云端只留最新同步的一代快照（更早的代删掉），
  在云同步列表末尾「已删除」→「书籍回收站」里还原或彻底删除。
- 「彻底删除」删掉云端最后一份备份与本机同步记录，`library` 墓碑保留。

## schema 22 —— V3 拆库（上一版）

一次性从"单库 `narrchat.db`"换成"分库 + 分支/代"。**不兼容旧库**，靠启动时的
一次性迁移（`r2_to_v3`)把老数据搬过来，老库改名成 `.r2.bak` 留档。

### 库的拆分

| 老 | 新 |
| --- | --- |
| `narrchat.db` 的 `books` | `user_data/narrchat_library.db` 的 `books`（只留身份 + 墓碑） |
| `narrchat.db` 的 `mods` | `user_data/narrchat_mods.db` 的 `mods` |
| `narrchat.db` 的 `rounds` / `round_stack` / `book_mods` / `world_book` / 书设置列 | `user_data/books/narrbook_<uuid>.db` |
| `narrchat.db` 的 `book_index` | `local_config/local_db/library_cache.db` |
| `narrchat_sync.db` | `local_config/local_db/sync.db`（整库重写，不迁移） |

### 轮次表合并成一张

老的 `rounds`（投影）+ `round_stack`（版本树）两张表合成一张 `round_stack`：

```sql
CREATE TABLE round_stack (
  uuid            TEXT PRIMARY KEY,
  father_uuid     TEXT,            -- NULL/空串 = 链首
  branch_uuid     TEXT NOT NULL DEFAULT '',
  round_index     INTEGER NOT NULL,
  round_serial_num INTEGER NOT NULL,
  is_using        INTEGER NOT NULL DEFAULT 0,
  operated_at     TEXT NOT NULL,
  message_status  TEXT NOT NULL DEFAULT '',   -- ''/info/warning/error
  message         TEXT NOT NULL DEFAULT '',
  ...正文列
);
```

不建 `father_uuid` 自引用外键：删父行时会被外键挡住，不可达行靠"父查不到 = 不可达"
规则清理。`branch_uuid` 也不指向分支表，默认分支用空串表示（不进表）。

### 新增/改动字段

- `books`：去掉书设置的全部列（搬到书库的 `book_meta`），只留 `uuid` / `title` /
  `created_at` / `updated_at` / `deleted_at`。
- `book_meta`（新表）：`book_uuid` / `master_uuid` / `database_version` + 全部书设置列。
- `branches`（新表）：`uuid` / `name` / `father_uuid` / `father_snapshot` /
  `created_at` / `updated_at` / `deleted_at`。`branch_working` 存在 `book_meta` 上。
- `use_mods`（代替 `book_mods`）：只有 `mod_uuid` + `sort_order`，**只记录已启用**。
  预置 Mod 的引用串是 `preset::<key>`。
- `world_book`：主键从自增 `id` 改成 `uuid`，多一列 `is_using`（原来叫 `is_active`）。
- Mod：`mods.db` 里主键列名是 `mod_uuid`，读的时候别名成 `uuid` 复用同一个模型。

### 时间戳

全部改成固定长度 UTC 文本 `YYYY-MM-DDTHH:MM:SS.sssZ`（原来是 epoch 毫秒整数或本地时间串）。
好处是能直接按字符串比较排序，跨时区也不会错。

### 迁移注意

- 迁移前先把旧库按老链路升到 v21，再搬数据；
- 世界书条目用确定性 uuid v5 生成身份（同一本书重复迁移得到同一批 uuid）；
- 迁移失败的书单独记在 `migration_state.json`，不阻塞其它书，启动后可重试。

## schema 21 及更早

见 [`docs/old/database_update_log_r2.md`](old/database_update_log_r2.md)。
