# 下一代数据库设计临时文档

在 v3.0 版本时，数据库按此文档进行破坏性更新，在升级至 v3.0 版本后的数据结构无法被之前的版本应用。

此文档在确认落地后删除，除非用户确认，否则 Agent 不应编辑此文档

下一代更新目标：
- 信源唯一、避免大双写
- 优化体验、与现代 AI 对话软件交互方案对齐
- 优化性能
- 更优雅、现代，清除历史债务，可保证自此长期无数据库方面的破坏性变更
- 统一时间戳使用 DATETIME 的当前用户时区，统一 ISO 8601 文本格式与毫秒精度，避免双时间戳维护，减少维护心智负担

## 结构

文件应以下结构：

```
user_data/
  narrchat_library.db
  books/
    narrbook_<book_uuid>.db

local_config/
  local_db/
    narrchat_sync.db
```

其中 narrchat_sync.db 保持本地用于同步。三库共享版本号。

### narrchat_library.db

此库用于记录书籍内容和 mods，分表如下：

#### meta

数据库信息，仅一行

| 列 | 类型 | 约束 | 说明 |
| --- | --- | --- | --- |
| `master_uuid` | TEXT | PK | 全局uuid（父） |
| `database_version` | INTEGER | NOT NULL | 数据库版本 |

#### books

书籍表，用于书籍目录、软删墓碑，以及可重建的标题/分类缓存

| 列 | 类型 | 约束 | 说明 |
| --- | --- | --- | --- |
| `book_uuid` | TEXT | PK | **主键** 跨设备稳定身份；**无第二个自增 id** |
| `title` | TEXT | NOT NULL | 书名（同步中仅供展示／同名匹配，从不作身份） |
| `category` | TEXT | DEFAULT `''` | 分类 |
| `created_at` | DATETIME | NOT NULL | 创建时间戳，更新时若无则设置为当前时间 |
| `updated_at` | DATETIME | NOT NULL | 更新时间戳，设置更新和轮次更新或其它均列入此 |
| `deleted_at` | INTEGER | NULL | 软删墓碑（同步删除传播用；硬删走 `BookDao.deleteBook`） |

其中的 `title` `category` `created_at` `updated_at` 为缓存用途，与 narrbook.db 冲突时以 narrbook.db 为准

#### mods

自定义 mod 表

| 列 | 类型 | 约束 | 说明 |
| --- | --- | --- | --- |
| `mod_uuid` | TEXT | PK | **主键** mod 的 uuid |
| `name` | TEXT | NOT NULL | mod 名 |
| `description` | TEXT | DEFAULT `''` | 说明 |
| `pre_prompt` | TEXT | DEFAULT `''` | 前置词 |
| `post_prompt` | TEXT | DEFAULT `''` | 后置词 |
| `system_prompt` | TEXT | DEFAULT `''` | 系统提示词 |
| `world_book` | TEXT | DEFAULT `''` | 世界书 |
| `created_at` | DATETIME | NOT NULL | 创建时间戳，更新时若无则设置为当前时间 |
| `updated_at` | DATETIME | NOT NULL | 更新时间戳，设置更新和轮次更新或其它均列入此 |
| `deleted_at` | INTEGER | NULL | 软删墓碑 |

### narrbook_<book_uuid>.db

此库用于单本书，是单本书的唯一信源

#### book_meta

此书信息，仅一行

| 列 | 类型 | 约束 | 说明 |
| --- | --- | --- | --- |
| `master_uuid` | TEXT | NOT NULL | 继承于 library |
| `database_version` | INTEGER | NOT NULL | 数据库版本 |
| `book_uuid` | TEXT | PK | 用于校验：跨设备稳定身份；与数据库对应文件名和 library 内的表应保持一致 |
| `title` | TEXT | NOT NULL | 书名（同步中仅供展示／同名匹配，从不作身份），*以此为准* |
| `category` | TEXT | DEFAULT `''` | 分类 *以此为准* |
| `created_at` | DATETIME | NOT NULL | 创建时间戳，更新时若无则设置为当前时间 *以此为准* |
| `updated_at` | DATETIME | NOT NULL | 更新时间戳，设置更新和轮次更新或其它均列入此 *以此为准* |
| --- | --- | --- | 方便人类阅读的分隔符，以下为书籍设置 |
| `base_setting` | TEXT | DEFAULT `''` | 基础设定 |
| `writing_requirements` | TEXT | DEFAULT `''` | 文笔要求 |
| `writing_style` | TEXT | DEFAULT `''` | 文笔参考范文 |
| `global_pre_prompt` | TEXT | DEFAULT `''` | 全局前置提示 |
| `global_post_prompt` | TEXT | DEFAULT `''` | 全局后置提示 |
| `history_rounds` | INTEGER | NOT NULL DEFAULT 1 | 提示词携带的历史轮数 |
| `memory_summary_rounds` | INTEGER | NOT NULL DEFAULT 0 | 记忆总结压缩档位（0 = 关闭） |
| `role_hierarchy` | TEXT | DEFAULT `''` | 角色层级 |
| `role_hierarchy_detail` | TEXT | DEFAULT `''` | 角色层级详细描述格式 |

#### world_book

此书所用到的世界书，原单一库的 `world_book_entries` 表的拆分

| 列 | 类型 | 约束 | 说明 |
| --- | --- | --- | --- |
| `uuid` | TEXT | PK | 世界书条目的 uuid |
| `keys` | TEXT | NOT NULL | 用于触发的关键词 |
| `content` | TEXT | DEFAULT `''` | 世界书注入提示词的内容 |
| `is_using` | BOOL | DEFAULT false | bool 值，用于储存是否启用 |
| `created_at` | DATETIME | NOT NULL | 创建时间戳 |
| `updated_at` | DATETIME | NOT NULL | 更新时间戳 |

#### use_mods

记录启用的 mod ，原单一库的 `book_mods` 拆分

| 列 | 类型 | 约束 | 说明 |
| --- | --- | --- | --- |
| `mod_uuid` | TEXT | PK | **主键** mod 的 uuid |
| `sort_order` | INTEGER | NOT NULL DEFAULT 0 | 激活的顺序们 |

仅“已启用的” mod 会进入此表，对于不在此书启用的 mod 和已被删除（无论是内置还是用户设置的）均直接在此表内删除，找不到对应的 uuid 的视为不启用，在后续同步时清理条目。

`mod_uuid` 对于预置 mod，预置 mod 采用以下格式：`preset::<id>` 的格式，自动识别

#### round_stack

唯一轮次记录表，也是此次数据库更新的重点，并附加说明：

数据父子逻辑模型：library(db) -> book(db) -> 分支 branch（表协助管理） -> 轮 round（逻辑分层） -> 代(row)

**极其极其极其重要**

| 列 | 类型 | 约束 | 说明 |
| --- | --- | --- | --- |
| `uuid` | TEXT | PK | **主键** 本代身份（跨设备稳定，参与同步摘要） |
| `father_uuid` | TEXT | DEFAULT NULL | 上一轮**当时活动代**的 uuid；`NULL`/空串 = 根（链首），当其不为 `NULL` 且此 uuid 不存在时视为同等被删除 |
| `branch_uuid` | TEXT | DEFAULT '' | 分支的 uuid ，空或NULL为默认分支 |
| `round_index` | INTEGER | NOT NULL | 本代所属轮号 |
| `round_serial_num` | INTEGER | NOT NULL | 本轮第 X 代（可跳步；物理删除后允许复用） |
| `is_using` | BOOL | NOT NULL | 当前分支的当前轮次内是否启用本代 |
| `operated_at` | DATETIME | NOT NULL | 这里默认是创建时间，但存在一些用户手动编辑的场景，对于用户手动编辑的场景也用此来记录 |
| `message_status` | TEXT | DEFAULT '' | info 蓝框 / warning 黄框 / error 红框，留空默认为 info，任何截断均报 error |
| `message` | TEXT | DEFAULT '' | 信息提示，包括蓝框信息、黄框警告、红框报错均走此通道，空白则不显示提示框 |
| `model_name` | TEXT | DEFAULT `''` | 本轮实际模型名 |
| `tokens_in` | INTEGER | NULL | Token 用量-输入部分（包含缓存）；**`NULL` = 无数据**，`0` = 真实 0 |
| `tokens_cached_in` | INTEGER | NULL | Token 用量-输入缓存命中；**`NULL` = 无数据**，`0` = 真实 0 |
| `tokens_out` | INTEGER | NULL | Token 用量-输出部分；**`NULL` = 无数据**，`0` = 真实 0 |
| --- | --- | --- | 方便人类阅读的分隔符，以下为内容 |
| `raw_response` | TEXT | DEFAULT `''` | AI 返回的原始内容（非全流程 RAW），这里一般为空，等待未来可能红框时不解析保留它，当前解析后始终为空 |
| `user_input` | TEXT | DEFAULT `''` | 轮次内容 - 用户输入 |
| `ai_narrative` | TEXT | DEFAULT `''` | 轮次内容 - AI 返回的正文部分 |
| `world_state` | TEXT | DEFAULT `''` | 轮次内容 - 世界状态 |
| `character_state` | TEXT | DEFAULT `''` | 轮次内容 - 角色状态 |
| `memory_summary` | TEXT | DEFAULT `''` | 轮次内容 - 记忆总结 |
| `current_time` | TEXT | DEFAULT `''` | 轮次内容 - 当前时间（这里指剧情内的时间，属于内容的一部分） |
| `recommended_action` | TEXT | DEFAULT `''` | 轮次内容 - 推荐下一步 |
| `user_images` | TEXT | NOT NULL DEFAULT `'[]'` | 图片相对路径 JSON 数组用户输入 |
| `ai_images` | TEXT | NOT NULL DEFAULT `'[]'` | 图片相对路径 JSON 数组 AI 输出的图像 |

#### branches

书籍分支，这是跟随 V3 新加入的部分，和代数不同的是：

- 其为一个可查看、可命名、可独立管理和删除的分支，用来给用户写 IF 线，与其它分支共享设定。
- 每个书都有一个不可删除不可重命名的默认分支
- 每个分支的头位的 father uuid 应为 NULL，其分支的父级应由 branchs 表记录，分支的 father 被删除后不影响分支本身
- UI 上，拉到分支的最上面会看到一个提示，提示内容为此为 x 分支 x 轮 x 代内容（uuid：），点击跳转；若此代已被删除直接提示“已被删除”，若此代不处于 use 状态提示“当前不被使用，当前轮使用代为 x 代，是否跳转”
- branch 被删除时其子分支不会被删除，被删除时其在 round stack 表的行全部都被删除
- 当 branch 的父被删除时，向模型拼合 branch 的父快照提供一轮级参考
- 此处的 father row 指的是对应 round stack 的代（uuid）而非轮次

以下为此表列信息：

| 列 | 类型 | 约束 | 说明 |
| --- | --- | --- | --- |
| `branch_uuid` | TEXT | PK | **主键** 分支的 UUID |
| `father_row` | TEXT | DEFAULT `''` | 父行的 UUID |
| `father_row_index` | INTEGER | DEFAULT 1 | 父行的轮次数 |
| `father_branch` | TEXT | DEFAULT `''` | 父分支的 UUID，NULL 或 '' 视为其父分支为默认分支 |
| `branch_name` | TEXT | NOT NULL | 分支的名称，用户自行命名 |
| `father_row_shot` | TEXT | DEFAULT `''` | 父行的快照，包含父行的内容部分，使用 json 存储 |
| `created_at` | DATETIME | NOT NULL | 创建时间戳 |
| `updated_at` | DATETIME | NOT NULL | 更新时间戳 |

此表不记默认分支

### 索引

建设时自动调整，不在此文档声明

## 云同步和本地存储的导入和导出

云同步适配数据库格式，调整为一个同步列表。同步代数每个 book 和 library 数据库分别持有，互不影响，library 跟随最近的一次同步而同步，除了对 mod 的修改（不涉及 book 数据库变更）否则同步优先级为先同步 book 数据库，当队列内的 book 数据库都推送完成，再同步 library 数据库

### 云同步设置页 UI 表现

设置页 UI 调整为每 book 和 library 各一个入口，各自可还原，入口顺序为先 library 再按 book 更新日期决定由新到旧从上到下，最下面是已删除书。

当合并/还原时检查 book 与 library 的交集部分，理论上对于交集部分的 uuid 不会冲突，对于其它的冲突部分以 book 的库为准

### 云同步云端命名

云端命名为 `<名称>_shot-g<代数的数字>.db`，时间由 webDav 返回的信息管理，不放在文件名上

### 云同步管理删除文件

对于已删除的 book，标识已删除作为设置页列表的最末尾，同步时不主动同步已删除的 book 数据库（其 library 墓碑继续同步），提供按钮物理删除 book，对于未完全删除的 book 可拉取还原，取消墓碑继续并入同步推送。

### 云同步合并冲突决策执行

当出现冲突时，单本书仅能选择保留本地还是导入云端，不再区分设置和轮次，默认选择 book meta 表的 update time 更新的那一方，用户可自行调整

### 本地导出和导入

仅支持导出/导入一个完整的 user_data 组，打包命名为 narrchat.zip，导入时分别对 mod 和 book 走合并流程

## 更新兼容

不兼容 1.x 和 2.x 版本，在更新 3.0.0 版本时一次性将用户现有数据库更新为新版，旧版数据库重命名为 `narrchat.db.r2.bak` 以备用，用户可自行在存储管理页导出或删除它。

## 调试页

调试页也应做配套，调试页应可查看（只读）全部的内容，包括 local_config/ 和 user_data/ ，调试页配备简易的 jsonView 阅读器和 sqliteView 阅读器