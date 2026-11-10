# 数据库（R3，schema 24）

> 本文是当前数据库设计指南。上一个版本（单库 `narrchat.db`）已归档到
> [`docs/old/database_r2.md`](old/database_r2.md)。

R3 随 v3.0 做破坏性更新，升级后的结构不能交给 1.x / 2.x 使用；旧数据只在升级时一次性迁移，
见[读 R2 迁移](#读-r2-迁移)。

## 设计目标

- **信源唯一**：不做大范围双写，目录、书内数据和本地缓存各有清楚边界。
- **按书拆分**：改一本书、同步一本书，不再牵动整库。
- **对齐现代 AI 对话交互**：原生支持多代切换、失败代和 IF 分支。
- **清理历史债务**：统一身份、时间戳和同步规则，尽量避免再次破坏性变更。

## 总体约定

- 业务主键统一使用 TEXT UUID，不设第二个自增 id；预置 Mod 使用 `preset::<id>`。
- 时间戳一律用 TEXT 保存定长 UTC ISO 8601 文本 `YYYY-MM-DDTHH:MM:SS.sssZ`，
  毫秒补零，可直接按字符串比较排序。格式化与解析统一走
  `lib/utils/timestamp_format.dart`，不要自行拼接，也不要用 `datetime()` / `strftime()`
  参与索引查询。
- 布尔一律用 INTEGER 的 `0` / `1`，并声明 `NOT NULL`。
- `user_data/` 下各库共用 `PRAGMA user_version = 24`；`local_config/` 下各库独立管理版本。
  `meta` / `book_meta` 里的 `database_version` 只是迁移后写入的调试镜像，不能用来判断版本。
- 索引按实际查询在 DDL 中建设和调整，本文不逐项列索引。
- 下文是结构和行为指南；具体 DDL 的唯一来源是 `lib/database/db_schema.dart`。

## 文件布局

```text
user_data/                          ← 用户数据（会云备份）
  narrchat_library.db               目录库：书籍身份 + 墓碑 + master uuid
  narrchat_mods.db                  Mod 库：用户自定义 Mod
  books/narrbook_<book_uuid>.db     每本书一个库：设置 / 轮次 / 分支 / 世界书 / 启用 Mod
  img/                              图片（内容寻址：<sha256>.<ext>）

local_config/local_db/              ← 本地数据（不云备份）
  sync.db                           云备份的单元状态与共基
  library_cache.db                  列表、搜索、高度和图片引用等本地缓存
```

`user_data/` 整个目录是一组完整的用户数据。`local_config/` 只放程序自动管理的派生数据和状态，
丢了最多重新同步或重建，不能成为用户数据的唯一信源：

- `sync.db` 保存各同步单元的本地状态与共基。
- `library_cache.db` 缓存书籍 UUID、书名、分类、时间、设置、封面（
  `book_cover_img` 副本）、图片引用和聊天高度等，
  避免列表、搜索等高频跨书操作每次都打开全部书库。

## 数据信源

| 数据 | 位置 | 谁是信源 |
| --- | --- | --- |
| 书是否存在 / 是否被删 / 删除时间与删除时轮号 | `library.books` | 目录库 |
| 书名、分类、创建与更新时间、书籍设置 | 书库的 `book_meta` | **书库**（目录与缓存跟它对齐） |
| 列表页显示用的行 | `library_cache.book_index` | 副本，丢了能重建 |
| 轮次、分支、世界书、启用的 Mod | 对应书库 | 书库 |
| 用户自定义 Mod | `narrchat_mods.db` | Mod 库 |

缓存是**纯副本**，不能把缓存值反向写成信源。`listBooks` 发现“目录里有、缓存里没有”时，
会按目录逐本补齐，所以导入备份后不会出现“书全没了”的假象。

首页按「更新时间」排序读取缓存里的 `updated_at` 时，会先比较书库文件 mtime 与缓存记录的
`db_mtime_ms`：变过的书才打开书库，用 `book_meta.updated_at` 校正缓存（顺带校正
`last_round_at`），没变过的书直接用缓存值。这样既不会每次排序都开 N 个库，也不会把
设置 / 轮次 / 世界书 / Mod 变更后的旧时间当成最新时间。

## 表结构

### `narrchat_library.db`

目录库只记录书籍目录和删除墓碑，不存书内内容。

#### `meta`

数据库信息，仅一行。

| 列 | 类型 | 约束 | 说明 |
| --- | --- | --- | --- |
| `master_uuid` | TEXT | PK | 全局 UUID（父身份） |
| `database_version` | INTEGER | NOT NULL | 数据库版本镜像，仅调试用 |

#### `books`

| 列 | 类型 | 约束 | 说明 |
| --- | --- | --- | --- |
| `book_uuid` | TEXT | PK | 跨设备稳定身份，无第二个自增 id |
| `title` | TEXT | NOT NULL | 目录展示用书名，**不是书名信源** |
| `deleted_at` | TEXT | NULL | 软删墓碑，用于同步传播删除 |
| `deleted_round_index` | INTEGER | NULL | 删除时全书最大轮号，供回收站展示 |

### `narrchat_mods.db`

保存用户自定义 Mod；预置 Mod 由程序内置，不落 `mods` 表。
`meta` 与目录库同名表结构一致，其中 `master_uuid` 继承目录库。

#### `mods`

| 列 | 类型 | 约束 | 说明 |
| --- | --- | --- | --- |
| `mod_uuid` | TEXT | PK | Mod 的跨设备稳定身份 |
| `name` | TEXT | NOT NULL | Mod 名 |
| `description` | TEXT | DEFAULT `''` | 说明 |
| `pre_prompt` | TEXT | DEFAULT `''` | 前置词 |
| `post_prompt` | TEXT | DEFAULT `''` | 后置词 |
| `system_prompt` | TEXT | DEFAULT `''` | 系统提示词 |
| `world_book` | TEXT | DEFAULT `''` | 世界书 |
| `created_at` | TEXT | NOT NULL | 创建时间 |
| `updated_at` | TEXT | NOT NULL | 更新时间 |
| `deleted_at` | TEXT | NULL | 软删墓碑 |

### `narrbook_<book_uuid>.db`

每本书一个库，是这本书的唯一信源；库文件本身已经划定了书的边界，书内各表不再重复保存
`book_uuid`（单行表 `book_meta` 的身份校验列除外）。

#### `book_meta`

此书信息和设置，仅一行。`book_uuid` 必须与文件名、目录库中的身份一致。

| 列 | 类型 | 约束 | 说明 |
| --- | --- | --- | --- |
| `master_uuid` | TEXT | NOT NULL | 继承目录库的全局 UUID |
| `database_version` | INTEGER | NOT NULL | 数据库版本镜像，仅调试用 |
| `book_uuid` | TEXT | PK | 跨设备稳定身份，用于校验，不作同名匹配 |
| `title` | TEXT | NOT NULL | **书名信源**；同步展示或同名匹配不作身份判断 |
| `category` | TEXT | DEFAULT `''` | 分类 |
| `created_at` | TEXT | NOT NULL | 创建时间 |
| `updated_at` | TEXT | NOT NULL | 设置、轮次等内容变更时刷新 |
| `base_setting` | TEXT | DEFAULT `''` | 基础设定 |
| `writing_requirements` | TEXT | DEFAULT `''` | 文笔要求 |
| `writing_style` | TEXT | DEFAULT `''` | 文笔参考范文 |
| `global_pre_prompt` | TEXT | DEFAULT `''` | 全局前置提示 |
| `global_post_prompt` | TEXT | DEFAULT `''` | 全局后置提示 |
| `history_rounds` | INTEGER | NOT NULL DEFAULT 1 | 提示词携带的历史轮数 |
| `memory_summary_rounds` | INTEGER | NOT NULL DEFAULT 0 | 记忆总结压缩档位，0 = 关闭 |
| `role_hierarchy` | TEXT | DEFAULT `''` | 角色层级 |
| `role_hierarchy_detail` | TEXT | DEFAULT `''` | 角色层级详细描述格式 |
| `book_cover_img` | TEXT | NULL | 书籍自定义封面的图片相对路径（`img/<哈希>.<扩展名>`，与 `user_images` 的元素同格式）；NULL = 没有自定义封面 |

#### `world_book_entries`

原单库的世界书条目按书拆分到这里。

| 列 | 类型 | 约束 | 说明 |
| --- | --- | --- | --- |
| `uuid` | TEXT | PK | 世界书条目 UUID |
| `keyword` | TEXT | NOT NULL | 触发关键词 |
| `content` | TEXT | DEFAULT `''` | 注入提示词的内容 |
| `is_using` | INTEGER | NOT NULL DEFAULT 0 | 是否启用 |
| `created_at` | TEXT | NOT NULL | 创建时间 |
| `updated_at` | TEXT | NOT NULL | 更新时间 |

#### `use_mods`

原单库的 `book_mods` 按书拆分到这里，只记录本书已启用的 Mod。

| 列 | 类型 | 约束 | 说明 |
| --- | --- | --- | --- |
| `mod_uuid` | TEXT | PK | 自定义 Mod UUID 或 `preset::<id>` |
| `sort_order` | INTEGER | NOT NULL DEFAULT 0 | 启用顺序 |

未启用或已删除的 Mod 不在此表保留；找不到对应 UUID 时视为未启用，并在后续同步时清理残留条目。

#### `round_stack`

唯一的轮次记录表，没有额外投影表。一行是一“代”，逻辑层级为：

```text
library（目录库）→ book（书库）→ branch（分支）→ round（逻辑轮）→ generation（一行）
```

身份、状态与用量列：

| 列 | 类型 | 约束 | 说明 |
| --- | --- | --- | --- |
| `uuid` | TEXT | PK | 本代身份，跨设备稳定并参与同步摘要 |
| `father_uuid` | TEXT | DEFAULT NULL | 上一轮**当时活动代**的 UUID；NULL / 空串 = 链首 |
| `branch_uuid` | TEXT | DEFAULT `''` | 分支 UUID；NULL / 空串 = 默认分支 |
| `round_index` | INTEGER | NOT NULL | 本代所属轮号，主要用于展示 |
| `round_serial_num` | INTEGER | NOT NULL | 本轮第几代，可跳步；物理删除后允许复用 |
| `is_using` | INTEGER | NOT NULL | 是否为同组当前选中的代 |
| `operated_at` | TEXT | NOT NULL | 创建或最后一次手动编辑时间 |
| `message_status` | TEXT | DEFAULT `''` | `info` 蓝框 / `warning` 黄框 / `error` 红框；空 = info |
| `message` | TEXT | DEFAULT `''` | 信息、警告或错误文案；空白不显示提示框 |
| `model_name` | TEXT | DEFAULT `''` | 本代实际模型名 |
| `tokens_in` | INTEGER | NULL | 输入 Token（含缓存）；NULL = 无数据，0 = 真实 0 |
| `tokens_cached_in` | INTEGER | NULL | 命中缓存的输入 Token；NULL / 0 语义同上 |
| `tokens_out` | INTEGER | NULL | 输出 Token；NULL / 0 语义同上 |

内容列：

| 列 | 类型 | 约束 | 说明 |
| --- | --- | --- | --- |
| `raw_response` | TEXT | DEFAULT `''` | AI 原始返回；通常解析后为空，失败时可保留用于排查 |
| `user_input` | TEXT | DEFAULT `''` | 用户输入 |
| `ai_narrative` | TEXT | DEFAULT `''` | AI 返回正文 |
| `world_state` | TEXT | DEFAULT `''` | 世界状态 |
| `character_state` | TEXT | DEFAULT `''` | 角色状态 |
| `memory_summary` | TEXT | DEFAULT `''` | 记忆总结 |
| `current_time` | TEXT | DEFAULT `''` | 剧情内当前时间，属于内容而非数据库时间戳 |
| `recommended_action` | TEXT | DEFAULT `''` | 推荐下一步 |
| `user_images` | TEXT | NOT NULL DEFAULT `'[]'` | 用户输入图片的相对路径 JSON 数组 |
| `ai_images` | TEXT | NOT NULL DEFAULT `'[]'` | AI 输出图片的相对路径 JSON 数组 |

任何截断都记为 `error`。`father_uuid` 非空但指向的行不存在时，本代视为父代已删、不可达；
不要给 `father_uuid` 加自引用外键，否则物理删除父行会被外键阻止。

#### `branches`

记录可查看、可命名、可独立管理和删除的 IF 分支；各分支共享书籍设定。

| 列 | 类型 | 约束 | 说明 |
| --- | --- | --- | --- |
| `branch_uuid` | TEXT | PK | 分支 UUID |
| `father_row` | TEXT | DEFAULT `''` | 分叉来源的**代** UUID，不是轮号 |
| `father_row_index` | INTEGER | NOT NULL DEFAULT 1 | 分叉来源代的轮号 |
| `father_branch` | TEXT | DEFAULT `''` | 父分支 UUID；NULL / 空串 = 默认分支 |
| `branch_name` | TEXT | NOT NULL | 用户命名的分支名 |
| `father_row_shot` | TEXT | DEFAULT `''` | 来源代内容部分的 JSON 快照 |
| `branch_working` | INTEGER | NOT NULL DEFAULT 0 | 本机是否激活；全 0 = 默认分支激活 |
| `created_at` | TEXT | NOT NULL | 创建时间 |
| `updated_at` | TEXT | NOT NULL | 更新时间 |

默认分支不落此表，固定使用 `branch_uuid = ''`，不可删除或重命名。`branch_working` 是本机会话状态，
不进同步摘要。

## 轮次与分支行为

### 轮、代与活动链

- **分组键 = `(branch_uuid, round_index, father_uuid)`**：只有“同一个上文下重新生成的几个版本”
  才算同组。因此切上一轮到旧版本后，下一轮能跟着切回对应链路，不需要另写同步逻辑。
- **活动链靠 `father_uuid` 回溯，不看 `round_index`**；轮号只是给人看的编号。
- `is_using` 表示组内当前选中的代；同组至多一个 1，不建唯一索引，读取时归一化自愈。
- 重新生成**不删旧代**：新代进同组并设为选中，旧代保留，可用 `← / →` 切回。
- 书籍设置的「其它设置 → 删除未启用的代」按组只保留当前选中的代（一组一个都没有
  时保留序号最大的胜出者），其余旧代物理删除；因父代被删而不可达的后代一并删除。
  活动链与各分支行不受影响，属内容变更（刷新 `updated_at` 并触发云备份）。

### 失败与中断（方案 A）

失败不是特殊占位，而是链上的普通一代：

- `message_status = 'error'`，`message` 存提示文案，空则显示“已中断”；
- 保留用户输入与原图，RAW 按代 UUID 归位，点开红条仍能看请求 / 返回；
- 错误代不能衍生下一轮、不能 fork，也不能基于它继续按要求修改；先重新生成或删除该轮。

这样不再需要“删除失败条目”“清空失败”等另一套数据概念。

### 分支

- 默认分支永远排第一。两种建分支方式：普通分叉**只建分支行、不复制轮次**；
  「从此代拷贝链至新的分支」会把目标代及其整棵子代树**物理复制**过去（见下）。
- 子分支首轮 `round_index = 父代 round_index + 1`，链首代的 `father_uuid = NULL`；
  跨分支父级只由 `branches` 记录。
- **拷贝链**（界面入口：AI 气泡右键「从此代拷贝链至新的分支」）：
  - 复制范围 = 目标代 + 同一分支里**轮号更大的全部代**（含各轮未激活代与
    隐藏版本线）；**目标代同轮的兄弟代不复制**，更早的轮次靠 branch father 继承。
  - `father_row` = 目标代的**父代**；目标代是新分支唯一的根代，后续轮的代按
    原父代重映射。这样新分支第 N 轮只有被点那一代，从第 N+1 轮起才展开版本树。
  - 原父代不在拷贝集合里的代（典型：目标代兄弟代的孩子）挂到新分支活动链上
    轮号更小的最近一代，作为该轮的一个未激活版本，代序号追加到该组末尾；
    既不会产生悬空行，对应轮的 `←/→` 也能切到它。
  - 新分支活动链与源分支从目标代起完全一致：活动链成员强制选中，其它代未激活；
    隐藏版本线内部保留原来的选中关系，切过去后还能按原样续上。
  - 复制出的代使用全新 `uuid`，`round_index` / 内容 / `operated_at` 原样保留；
    被挂回来的孤儿使用新分配的代序号。
  - 新分支默认**不激活**（对话框里选「点击跳转」才切过去）；源分支一行不改。
  - 拷贝的是目标代及之后的链；更早的上文仍通过 `father_row` 从源分支继承，因此
    删掉源分支后，拷贝分支的上文会按 `father_row_shot` 降级为快照一轮（与普通分支一致）。
  - RAW 是内存态（按代 uuid 归属），不随拷贝带过去；图片只共享路径，不复制文件。
  - 与普通建分支一样属内容变更：刷新 `book_meta.updated_at`、触发一次云备份；
    分支行与全部代在同一事务里写入，失败不会留下半条分支。
  - 分支头卡片对**根分支**（非默认分支但 `father_row` 为空）显示「从第 1 轮开始」，
    没有父级可跳，因此不提供「点击跳转」；分支列表副标题同样写「从第 1 轮开始」。
- 给模型拼上文时按 `branches.father_row` 跨分支上溯，**分叉点父代本身也算上文**，
  受 `history_rounds` 截断；父代已删时用 `father_row_shot` 兜底一轮。
- 分支顶部展示来源分支、轮、代和 UUID，并支持点击跳转。来源代已删时提示“已被删除”；
  来源代不是当前使用代时，应说明当前使用的是哪一代，再让用户选择是否跳转。
- 删除分支会物理删除该分支在 `round_stack` 的全部行，但保留子分支；子分支不受影响，
  父级信息仍靠快照兜底。
- 建、改名、删分支（含拷贝链）都刷新书的 `updated_at` 并触发云备份。

## 两条容易踩的写入规则

**1. `father_uuid` 必须显式给。**

它的默认值是 NULL，而 NULL 的意思是“链首”。少传一次，那一轮就会另起一条根，
症状是“数据没丢但看不见”——活动链只解析得出最后一轮。这条曾经真出过 bug。

**2. 刷新 `updated_at` ⟺ 触发云备份。**

只有这两种状态：要么都做（改设置 / 插轮 / 改正文 / 改提问 / 删轮 / 建改名删分支 /
改世界书 / 改 Mod），要么都不做（切版本 / 切分支——它们只改 `is_using` 与
`branch_working`，不产生新内容）。破坏这个等价关系，就会出现“改了没上云”或
“没改也疯狂同步”。

## 不用 WAL

云备份的单位是一个 `.db` 文件。WAL 会把数据分到 `.db` / `-wal` / `-shm`，
快照容易拿到不一致的组合，最新数据也可能还留在旁挂文件里。因此统一使用默认日志模式。

## 云备份与导入导出

### 备份单元与队列

- **单位 = 一个 DB 文件 = 一代**：`<base>_shot-g<N>.db` + `manifest_<base>.json`。
  文件名不含时间，时间以 WebDAV 返回的信息为准。
- **云端目录**：数据文件（快照 / 清单 / `sync_config.json`）放在设置里的文件夹
  （默认 `narrchat`），图片 blob 与 `img_tombstones.json` 放在它的 `img` 子目录
  （默认 `narrchat/img`）。WebDAV 根目录不放任何文件；文件夹在首次同步时自动建出。
- Library、Mods 和每本书分别持有同步代数，互不影响；数据库同步队列按先来后到处理。
- **备份列表按库分组**：顶层固定 `Library 库` → `Mod 库` → `书籍《书名》库`，
  书籍按最新一代上传时间从新到旧排列。点进二级页才列代次、做整份还原。
- 已删除的书不占活书列表，末尾单独一个“已删除”入口，进入“书籍回收站”。
- **摘要只按文件内容计算**，排除所有时间戳、`branch_working`、meta 身份列，
  避免“只是打开看了一下”也被当成内容变更。
- **云端清单同时记内容指标**：`latestRoundIndex`（最新轮号）、
  `roundGenerationCount`（`round_stack` 行数 = 代数）、`contentUpdatedAt`、
  `savedAt`、`deviceId`。清单只多字段不改结构，旧清单缺字段时按「未知」处理。
- **摘要 SQL 的列名一律加引号**：裸写 `current_time` 会被 SQLite 当成 `CURRENT_TIME`
  关键字，导致摘要随墙上时间变化；`order` / `key` / `group` 等保留字同理。
- **保留份数以云端 `sync_config.json` 为唯一权威**：面板打开 / 刷新 / 每次数据面同步前
  都读一次；读不到时本轮不修剪，宁可多留也不误删，展示框保持“—”而不伪装成云端真值。
- 同步提示分别说明 Library 和 Mods 的状态，书籍合并显示“同步了 x 本书”。
- 本机没有、云端有清单的库（换设备后的第一轮，或本机文件被手动删掉）会自动下载
  对应快照补建文件，不再出现“列表里有书、打开报缺文件”。
- 不迁移旧版本云端快照，也不做“检测到旧数据”的提示。

### 合并与还原

- **书籍冲突先 PK 再问人**：三轴是代数（`round_stack` 行数）、最新轮次（最大轮号）、
  更新时间（`book_meta.updated_at`）；三轴全部指向同一侧就自动采用，否则留给用户
  整本二选一（替换本地 / 保留本地 / 保留云端），不逐部件合并。
- **Mod 库按新者居上**：云端清单的 `contentUpdatedAt` 与本地最近一次 Mod 修改时间比，
  较新的一侧直接采用；持平或读不出来才问用户。
- **书架按行自动合并**（不整库二选一）：按 `book_uuid` 取并集，只有一侧有的行原样
  保留；两侧都活就留活；都墓碑取较新的 `deleted_at`；一侧活一侧墓碑比较墓碑删除时间
  与活侧书库内容时间，活侧更新才留活，时间未知时墓碑胜。这样本地离线新增的书不会
  丢、删除能正常传播、回收站还原也不会被旧墓碑反杀。两侧 `master_uuid` 不一致时
  不硬合并，降级成人工选择。
- 书架合并后把本机基线改成云端这一代，并补跑一轮把合并结果推成新代；随后按合并后的
  目录补齐「云端有、本机没有」的书单元。
- 冲突没被处理时留在 `CloudSyncProvider.conflicts`：同步中弹三选一对话框，选
  「冲突决策」会在本轮结束后自动打开冲突决策页；入口同时出现在云同步面板与首页
  同步状态章。
- 合并或还原时检查书库与目录库的交集。UUID 是稳定身份，书名、设置等书内数据冲突时
  以书库为准，目录和缓存再向它对齐。
- 还原已删除的书时，下载保留的备份、清除目录墓碑，并重新纳入同步推送。

### 本地导出与导入

只支持导出 / 导入一组完整的 `user_data/`（包含图片），打包命名为 `narrchat.zip`。
导入时分别合并 Library、Mods 和各书库；书内信源与整本书冲突仍按上面的规则处理。

## 删除一本书（回收站）

删除只清本机，云端留一份“最新同步”的快照，供回收站还原：

1. `library.books` 写 `deleted_at` + `deleted_round_index`；目录行保留，供其它设备传播删除。
2. 本机清掉 `books/narrbook_<uuid>.db`（含 SQLite 旁挂文件）、`library_cache` 的索引 /
   高度 / 图片引用。
3. 云端每本书只留最新同步的一代快照，更早的代删掉，清单只在指向保留代时留下；
   这本书不再参与推拉。自动同步开启时交给数据面（先推 Library 墓碑，再整理）；
   否则删除时立即尽力整理一次，失败由下一次同步兜底。
4. 墓碑随 Library 同步到其它设备；其它设备拉到后清本机残留，并把云端整理成同一份最新代。
5. “云同步 → 云端备份列表末尾 → 已删除 → 书籍回收站”中，每本书一行
   （书名 / UUID / 删除时间 + 轮次）。可以“还原此书”，或二次确认后“彻底删除”；
   彻底删除只删云端最后一份备份，Library 墓碑保留，条目消失。
6. 从未同步过、云端没有快照的书不进回收站，本地墓碑保留。
7. 旧版本只打墓碑、没删文件的，启动时按墓碑扫一遍本机残留。

图片**不做引用回收**：书删了也不删图片 blob，因为它可能被其它书或历史代引用。

## 读 R2 迁移

`lib/database/migration/r2_to_v3.dart` 负责一次性迁移：

1. 把旧库改名 `narrchat.db` → `narrchat.db.r2.bak`（若已存在则 `.after-downgrade.bak`）；
   备份可由用户在存储管理页导出或删除。
2. 旧库先按老链路升到 v21，再逐本重建书库。
3. 进度写 `local_config/migration_state.json`，失败的书可以在启动后重试。
4. 删掉旧的 `narrchat_sync.db`。

迁移只跑一次，完成后在 `migration_state.json` 里记 `done`。

## 调试页

调试页应能只读查看 `local_config/` 和 `user_data/` 的全部内容，并提供简易 JSON 查看器和
SQLite 查看器，便于核对实际数据、版本镜像和同步状态。

## 代码地图

| 文件 | 作用 |
| --- | --- |
| `lib/database/db_schema.dart` | 五个库的 DDL **唯一来源** + 版本常量 |
| `lib/database/db_open.dart` | 开库、读版本、表 / 列存在性检查 |
| `lib/database/{library,mods,cache,sync}_store.dart` | 目录库 / Mod 库 / 缓存 / 同步状态 |
| `lib/database/book_db.dart` | 单本书库，**唯一写入口**（`updated_at`、`is_using` 归一化、提示截断在这里收口） |
| `lib/database/book_db_pool.dart` | 书库连接池 |
| `lib/repositories/*.dart` | 上层门面：书 / 轮次 / 世界书 / Mod |
| `lib/services/cloud_backup/backup_book_purge.dart` | 删书后的云端处理：保留最新一代 / 彻底删除（只认墓碑驱动） |
| `lib/screens/book_recycle_bin_page.dart` | 书籍回收站：每本已删书一行，还原 / 彻底删除 |
| `lib/services/app_stores.dart` | 组装根：解析路径 → 迁移 → 开库 |
| `lib/services/app_repositories.dart` | 应用级仓库集合，Provider 从这里拿数据入口 |
