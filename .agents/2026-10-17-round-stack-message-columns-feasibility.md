# `round_stack` 增加 `message` / `message_status`：可行性与修改范围报告

> 日期：2026-10-17 ｜ 性质：**只读调研 + 实测**（未改任何生产代码、未执行 git）
> 目标：把「黄条警告 / 红条报错」统一挂到版本树的**代**上，并持久化 + 云同步
> 代码基线：`_dbVersion = 20`（v19 引入 `round_stack`，v20 把同步元数据迁出用户库）

---

## 落地状态（2026-10-17 当天已按主人决策实施）

主人拍板后**已全部落地**（一期不分批）：DB v21、提示入库、失败双写 + 失败占位代、
稀疏摘要、删除 `round_warnings.json`、新增关闭提示 / 清除失败条目的同步节点。
与本文原始建议的差异如下：

| 项 | 本文建议 | 实际落地 |
| --- | --- | --- |
| 红条 | 一期只按 `error` 着色、仍存 `books.failed_*` | **双写**：`books.failed_*`（兼容 + 同步）＋ `round_stack` 的**失败占位代**（`round_state='failed'`，内容全空、`error` 提示）；清除时机与旧行为完全一致 |
| `message_status` 默认值 | `DEFAULT ''`（推荐） | `DEFAULT ''`（照此实施） |
| 同步摘要 | 方案 C 稀疏编码 | 方案 C（逐行稀疏：无提示的行与旧编码逐字节一致，有测试锁定） |
| `round_warnings.json` | 一期保留兼容读 | **直接删除**（`FileRoundWarningsStore` / `MemoryRoundWarningsStore` / 两个测试文件一并移除，不做数据迁移） |
| 关闭提示 | 需新增触发点（待批） | **已新增**并登记白名单（`docs/sync_auto_triggers.md`），同时补上「清除失败条目」这个原本缺失的节点 |
| 提示文本上限 | 单条 ≤1000 / 整列 ≤4000 | 统一截断到 4000 字符（`RoundStackRow.clampMessage`） |

失败占位代的一处**规格外补充**：`round_state` 增加第三个取值 `'failed'`，并在
`RoundStackIndex.fromMetas` / `planChain` / `_pickInGroup` / `_normalizeGroupInTxn` /
`deleteGeneration` 回落目标 / `_adoptInTxn`（同内容复用与缺口子树删除）/ `versionLabel`
共 7 处过滤它——否则「投影插进一个空轮」「归一化把失败代设成 use」这两类问题会出现。
测试与文档均已同步（`docs/database.md` §5.3 提示与失败占位代、`docs/database_update_log.md` v21 条目）。
最终验证：`flutter analyze` 无问题；`flutter test` **1852 通过 / 1 跳过 / 0 失败**
（跑法：`flutter test`；探针可复跑：`.agents/perf/round_stack_message_size_probe_2026_10_17.py`）。

---

## 0. 一句话结论

**数据库这层：可行、低风险。** 纯加列，迁移幂等，老库/老客户端/老快照都有现成容错机制；
实测两列全空只占 **≤1.7 B/行**，典型使用下整库增量 **+0.1%~0.3%**。

**真正的成本在数据库之外的三件事**：

1. **同步指纹口径**——不把消息接进 `stackDigest`，消息改完**不会触发任何推送**，还会被对端快照整体覆盖（静默丢失）；
2. **「消息挂在代上」与「失败态没有代」的结构缺口**——红条（失败条目）今天**没有 `round_stack` 行**，它进不了 `message` 列。要么承认一期只做黄条，要么先把「失败态的载体行」设计出来（会牵动既定不变量）；
3. **关闭消息（点 ✕）要新增一个同步触发点**，否则本机关了、对端一次推送就把它带回来。

建议**分两期**：一期 = 黄条（`warning`）入库 + `info` 预留 + 红条按 `error` 着色（仍存 `books.failed_*`）；
二期再决定失败态是否在版本树里拥有载体行。

---

## 1. 现状核实（先纠正一个前提）

### 1.1 两条「条」今天分别存在哪

| | 黄条（警告） | 红条（报错） |
| --- | --- | --- |
| 模型 | `List<String>`（每轮多行） | `FailedAttempt`（`userInput` / `errorMessage` / `userImages`） |
| 归属 | **轮号** `(bookUuid, roundIndex)` | **只有书**——模型里没有轮号 / 代数（`lib/models/failed_attempt.dart:6-27`） |
| 存储 | `<local_config>/round_warnings.json`（`lib/services/round_warnings_store.dart:62-135`） | `books.failed_user_input` / `failed_error_message` / `failed_user_images`（`lib/database/book_dao.dart:127-168`） |
| 是否入库 | ❌ 不入库 | ✅ 入用户库 |
| 是否云同步 | ❌ 永不（快照只拷用户库整库字节） | ✅ 随「轮次部件」同步（`lib/services/sync/sync_fingerprint.dart:72-90` 的 `'failed'` 分量） |
| 已有测试 | `test/round_warnings_persistence_test.dart`（7 例，绿） | `test/round_generation_failure_test.dart`（9 例，绿）、`test/sync_uuid_identity_test.dart:327-380`（跨设备红条同步，绿） |

**实测基线**（本次跑的）：`flutter test test/round_warnings_persistence_test.dart test/round_generation_failure_test.dart test/round_warnings_store_test.dart` → **24 个用例全绿，exit 0**。

### 1.2 「红条报错无法持久化和同步」的可确证机制

红条**在设计上**是会入库、也会同步的（上表有绿测为证）。主人观察到的「留不住 / 另一台看不到」，就代码可确证的原因有 6 条，按嫌疑排序：

| # | 机制 | 证据 | 表现 |
| --- | --- | --- | --- |
| ① | **请求一开始就清空失败条目**，失败后才重新写入。请求期间（3 次重试 × 超时可达分钟级）它**内存和库里都是空的** | `lib/providers/round_provider.dart:1278-1279` | 请求进行中关掉 App / 断线 → 重启后红条、失败输入、失败图片**全部消失**；同一本书第二次失败会**覆盖**上一次（连图片一起） |
| ② | **失败条目每本书只有一份**（`books` 三列，单行 UPDATE），无轮级 / 代级载体 | `lib/database/book_dao.dart:155-168`、`lib/providers/round_provider.dart:119-120`（注释即写「**最近一次**」） | 两设备各失败一条 → 同一格子互相覆盖，云端只留最后推送的那份 |
| ③ | **「清除失败条目」不触发同步**（对比：删除轮次 / 删除代 / 编辑都显式触发） | 清除：`round_provider.dart:624-632`（无 `triggerSync`）；对照 `:2484` / `:2523` / `:2648` | 手动模式或长时间无其它操作时，云端长期留着旧红条，或对端旧红条被推回来 |
| ④ | **`sync_book_base.failed_fp` 是死列**（v14 遗留，`putBookBase` 只会把它写成 `''`，读取侧也从不读） | `lib/database/sync_dao.dart:185`、`:54-75`；`lib/services/sync/database_sync_runner.dart:351-364` | 失败条目没有独立的同步通道，只能整串随轮次部件走 → 精度只到「整部件」 |
| ⑤ | **冲突规则会让失败条目停住**：只有「轮次行逐行完全一致、仅失败草稿不同」才自动按纯增量流转；轮次行也不一致就进人工确认页，期间**既不上行也不下行** | `lib/services/sync/sync_merge_planner.dart:176-201`（尤其 `:188-191` vs `:200`） | 「另一台永远收不到红条」，直到用户处理冲突 |
| ⑥ | **读入口静默失败**；更关键的是黄条的**水合校验会连带删数据**：黄条键是「尚未产生的第 N+1 轮」，只要失败条目那一格空了，`round_warnings.json` 里那条记录会在下次开书时被**永久删除** | 读：`round_provider.dart:603-609`；连带删除：`:386-394` | 「红条一走，黄条跟着没」——两条信息被绑在一起同生共死 |

> 附带：文档 `docs/agent_mode.md:515-516` 仍写黄条「只在本次进程内有效…刻意不入库」，与实现（已落 `round_warnings.json`，重启会恢复）**不一致**，会把排查带偏，本次改造应顺手更正。

### 1.3 与 `round_stack` 到底有没有因果关系

**没有直接因果。** 可确证的事实：`round_stack` 的读写路径（DAO / 模型 / 服务）全文不出现 `failed` / `FailedAttempt`（`lib/services/round_stack_service.dart` 零匹配），失败态也明确「不写 `rounds`、不写 `round_stack`」（`docs/database.md:116-117`、`:172`）。

但要解释主人的体感，有两条**真实相关**的变化：

- v19/v20 之后新增的「切代 / 删除此代」两个入口都会**顺手清掉失败条目**（`round_provider.dart:701`、`:2507` 走 `_clearFailureForRoundOp`），红条被清掉的概率明显上升；
- 版本树让「历史内容都能还原」成为用户预期——既然正文可以切回上一代，「上次那条报错」自然也被期望留得住；而这个期望**今天没有载体**（1.2 的 ②）。

**结论：主人要的「把消息挂到代上并持久化 + 同步」，方向是对的——它恰好能补上 ②⑥ 这个结构缺口，但不能单独治好 ①③⑤**（那三条属于失败条目自身生命周期与同步触发点的问题，本报告一并列出，需一并处理才有效果）。

---

## 2. 目标语义（建议口径）

### 2.1 列定义（两列落**表尾**，与 `ALTER` 追加位置一致）

```sql
-- lib/database/database_helper.dart 的 _createRoundStackTable 末尾追加
  message            TEXT DEFAULT '',
  message_status     TEXT DEFAULT ''
-- v21 迁移分支（幂等）
ALTER TABLE round_stack ADD COLUMN message TEXT DEFAULT ''
ALTER TABLE round_stack ADD COLUMN message_status TEXT DEFAULT ''
```

> 用 `DEFAULT ''` 而不是 `NULL`：与仓库既有 TEXT 列习惯一致（`round_state` 之外全是 `DEFAULT ''`），
> 「默认空」由空串表达，`message_status` 的**未知 / 空值在读取时归一化为 NULL**（= 无级别）。
> 两种写法的空间开销一样（记录头各 1 B），差异只在语义清晰度——这一点请主人在 §8 拍板。

### 2.2 取值与归一化（沿用 `round_state` 的「白名单 + 读时自愈」策略）

| 输入 | 读出语义 |
| --- | --- |
| `'info'` / `'warning'` / `'error'` | 有效级别（`info` 为**预留**，暂无产生点） |
| `''` / `NULL` / 其它任意脏值（含 `'success'`、大小写变体、空格） | **NULL = 无级别** |
| `message` 去空白后为空 | 视为「无消息」，`status` 一并忽略（不渲染） |
| `message` 非空、`status` 为 NULL | 渲染为中性（与 `info` 同款视觉）；**写入侧不产生这种组合** |

**展示级别的现有可复用枚举**：`NoticeKind { info, success, warning, error }`（`lib/models/app_notice.dart:5-28`）——`message_status` 的三态正好是它的子集（建议复用字符串常量，避免第二套枚举）。

### 2.3 七条不变量（建议写进 `docs/database.md` §5.3）

1. **消息是「代」的附注，不是内容**：**不进** `contentMap()`、**不进** `contentFpOfStack / contentFpOfRound`。
   否则「加一条警告」会被采纳判定为「内容变了」→ 立刻长出一个内容相同的新代（代次爆炸 + 双设备反复推送）。
2. **消息进同步摘要**（详见 §3.3），否则永远是静默不同步。
3. 一条代一行消息；多行内容用 `\n` 合并，级别取**最高**（`error > warning > info`）。
4. 写入侧限长：单条消息 ≤ 1000 字符、整列 ≤ 4000 字符，超出截断并加省略号（防单行超大拖慢 B-tree 与快照）。
5. **不新增索引、不改已有索引**（消息不参与任何查询条件）。
6. **`metaColumns` 不加这两列**：UI 热路径另开一条**稀疏查询**（只取有消息的行）。
7. 删除 / 切换 / 采纳都**不需要特殊处理**：消息随行走，行删消息灭。

### 2.4 写入 / 读取 / 关闭三个点

| 动作 | 做法 |
| --- | --- |
| **写**（生成结束时） | `RoundStackService.attachNewGeneration(..., message:, status:)`，在**建代同一事务**里写入；来源 = `gen.agentWarnings` + Chat 模式记忆合并提示 |
| **读**（开书 / 生成结束） | `RoundStackDao.loadMessagesByBook(bookUuid)` 稀疏查（只返回 `message != ''` 的行）→ 按 `round.useStackUuid` 映射回轮号 |
| **关闭**（点 ✕） | `UPDATE round_stack SET message='', message_status='' WHERE uuid=?` + `touchBook(rounds: true)` + **触发同步**（需登记白名单，见 §4.4） |

---

## 3. 可行性分析

### 3.1 表结构与迁移：可行（有现成模板）

- 建表走共用 helper `_createRoundStackTable`（`lib/database/database_helper.dart:739-776`），**新装库自动带列**；
- 老库靠新增的 v21 分支 `_addColumnIfMissing`（`:523-531`，内部先 `PRAGMA table_info` 预检）加列，**幂等**；
- 注意一个**已有的良性机制**：v19 分支也调同一个 helper（`:297`），且 helper 是 `CREATE TABLE IF NOT EXISTS`。因此「v18 → 升到 v21」的库会在 v19 分支建表时就带上新列，随后 v21 的加列被预检跳过——**两条路径结果一致，不需要额外处理**；
- `_dbVersion` 必须 `20 → 21`（`database_helper.dart:21`），否则「新装库有列、既有库永远没有」，且既有 DB-1 用例（`test/database_migration_test.dart:1364-1411`「迁移产物 ≡ 新装库」）会直接报红；
- 列必须放在**表尾**：迁移用 `ADD COLUMN` 只能追加，而 `rounds` 的 `use_stack_uuid` 已确立了「DDL 里也要放列尾」的先例（`database_helper.dart:696-697`）。

**ALTER 的实际代价：0（不重写任何行）** —— 实测：`ALTER TABLE ... ADD COLUMN message TEXT` / `message_status TEXT` 后文件大小 **Δ 0.0 KB**。

### 3.2 空间占用：实测数据

方法：用同一套内容规模造两份库对比（脚本 `.agents/perf/round_stack_message_size_probe_2026_10_17.py`，随机种子固定，中文正文按真实量级 800~1600 字/代）。

| 场景 | 基线 | 加列后 | 增量 | 单行边际 |
| --- | --- | --- | --- | --- |
| 4800 代（20 本 × 80 轮 × 3 代），**两列全空** | 36.67 MB | 36.68 MB | **+8 KB（+0.02%）** | **+1.7 B** |
| 600 代（5 本 × 60 轮 × 2 代），两列全空 | 4.62 MB | 4.62~4.64 MB | +0~8 KB | ≤1.7 B |
| 4800 代，**12% 的代**带 60 汉字警告 | 36.67 MB | 36.79 MB | **+116 KB（+0.31%）** | 均摊 +27 B |
| 600 代，**每代** 30 汉字警告 | 4.62 MB | 4.67 MB | +40 KB（+0.84%） | +68 B |
| 600 代，**每代** 80 汉字警告 | 4.62 MB | 4.72 MB | +84 KB（+1.77%） | +143 B |
| 600 代，**每代** 400 汉字错误（最坏） | 4.62 MB | 5.18 MB | +557 KB（**+11.7%**） | +949 B |
| `ALTER` 加列本身（4800 代库） | 36.67 MB | 36.67 MB | **0 KB** | 不重写行 |

**怎么读这些数字：**

- **空消息几乎不要钱**：两列各占 1 B 记录头，实测含页对齐后 ≤1.7 B/行；这解释了为什么「默认空」是安全设计。
- **成本 = 消息文本长度 + 2 B**；页粒度 4096 B 会让小库的增量跳变（表里 600 代那两行就是这种跳变）。
- **云端要乘份数**：快照是用户库**整库字节拷贝**（`lib/services/cloud_sync_service.dart:58`），且**无压缩**，按 `keepVersions` 默认 **5** 保留 → 上表增量 ×5。最坏情况（每代都带长错误）云端多占约 **12%**；典型情况约 **+0.1~0.5%**。
- **`manifest.json` 不会变大**：消息折进 `stackDigest` 后仍是定长 sha256（64 字符），不是明文清单——这正是「进摘要而不是进清单」的收益。
- **一个必须知道的隐性成本**：消息一变，轮次部件指纹就变 → 会推**一份整库快照**（几十 MB 级，视库大小）。好消息是消息本来就在「生成结束」写入，正好搭上既有的同步节点（`docs/sync_auto_triggers.md:91`），**不额外增加推送次数**；只有「手动关闭消息」是新增的一次推送（见 §4.4）。

### 3.3 同步可行性：可以同步，但**必须选口径**

这是本改造唯一需要慎重设计的地方。三条路：

| 方案 | 改什么 | 结果 | 评价 |
| --- | --- | --- | --- |
| **A. 消息不进指纹** | 只加列 + 读写 | 本机改消息后 `rounds == unchanged` → **不推送**；等别的变更推快照时「搭车」，且随时可能被对端快照整体覆盖（`_replaceStackRows` 是**先清后插**） | ❌ 静默丢数据，不能选 |
| **B. 消息进指纹（朴素）** | `stackDigest` 的 18 列清单加 2 项 | 能同步；但**所有既有设备的摘要立刻变化**：同一份 stack，老客户端（不含消息）与新客户端（含消息）算出的哈希永远不同 → 两边每次都判「对方改了」→ **反复互推代数**（每次同步多写一份快照、旧版本保留窗口被快速消耗） | ⚠️ 可用但有跨版本抖动 |
| **C. 消息进指纹（稀疏编码）** | 同上，但**逐行按需追加**：该行消息为空 → 编码与旧算法**逐字节一致**；有消息 → 在行末追加 `[message_status, message]` | 能同步；**没有消息的书 / 行，跨版本摘要完全相等** → 绝大多数书零抖动；只有真有消息的书在「新旧客户端混用期间」才会反复推送，两端都升到新版后即消失 | ✅ **推荐** |

**推荐 C 的实现要点**（`lib/services/sync/sync_fingerprint.dart:98-136`）：

```
canonical = [ for (row in sorted) [
    ...旧 18 项,
    if (row.message 非空) row.message_status ?? '',   // 稀疏追加
    if (row.message 非空) row.message,
] ]
```

排序键 `(round_index, father_uuid, round_serial_num, uuid)` 与「排除 `round_created_at`」两条既有约定**保持不变**（有测试锁定：`test/sync_fingerprint_test.dart:469-500`）。

**冲突语义（重要，务必让用户知情）**：
- 轮次部件是**整部件胜出**，`round_stack` 只有「整本替换（先清后插）」一条落地路径（`lib/services/sync/round_stack_dao.dart:283-297`），**没有逐代合并**；
- 消息进摘要后，「本机改了消息、对端改别的」会落到 `_classifyRoundsPart:188-191` 的「轮次行完全一致 → 按纯增量推本地」，**不会弹冲突页**（好）；
- 但**两设备各改不同代的消息**会落进真冲突（`:200`）→ 弹合并决策页，而决策页的轮次粒度是**整部件二选一**（`lib/screens/database_merge_screen.dart:571-620`）→ **必丢一侧的消息**。这与既有既定语义一致（`docs/sync_auto_triggers.md:54`「不做自动并集」），但**必须在文档里写明**：消息是**最后写入者胜（LWW）**，不做逐代合并。

### 3.4 UI 可行性：低工作量

- 黄框组件 `_AgentWarningsBox`（`lib/screens/chat_screen.dart:4471-4545`）加一个 `status` 参数即可：`warning` 用现有黄色视觉、`error` 用 `theme.colorScheme.error`、`info` 中性色；
- 红条气泡 `_FailureBox`（`lib/widgets/failed_attempt_bubble.dart:148-196`）与新组件**共用同一渲染**（按 status 传参），实现「同一形态、三种级别」；
- 关闭按钮（Key `dismiss_round_warning`）改为写库 + 触发同步；
- UI 热路径**不读正文**：另开稀疏查询（§2.3 第 6 条），不打扰既有的「元数据投影刻意不含正文」约定（`lib/database/round_stack_dao.dart:19-28`）。

### 3.5 采纳 / 切换 / 删除：不用改，但有一条红线

- 采纳（`rounds` 为准收敛版本树）用内容指纹判断「复用现有代 / 新建代」（`lib/services/round_stack_service.dart:652-689`）。**只要消息不进内容指纹**：
  - 命中同内容代 → **复用该行，消息保住**；
  - 内容真变了 → 新建代，新行消息为空（正确：正文变了，旧提示已不适用）。
- 切换 / 删除代：消息随行走，无需特殊代码。
- 🔴 **红线**：一旦有人把 `message` 加进 `contentFpOfStack`（`round_stack_service.dart:581-595`），就会同时出现「消息不同 → 采纳长新代」和「`fromRound` 没带消息 → 新代消息为空」，**两处一起坏**。

### 3.6 不可行 / 需要先决策的一项：红条**今天没有载体行**

失败态的语义是「本该产生的那一轮还没产生」，所以版本树里**没有对应的行**（`docs/database.md:116-117`、`:172` 明确「失败只写 `books.failed_*`」）。因此：

- `message` 列**在物理上装不下红条**，除非先回答「失败态的载体行是谁」；
- 现有实现里，失败态那轮的黄框靠**内存 + `round_warnings.json`** 表达（`round_provider.dart:1846-1852`）。

三个可选做法（建议一期选 (a)）：

| | 做法 | 代价 |
| --- | --- | --- |
| **(a) 一期不迁红条**（推荐） | 红条继续存 `books.failed_*`，只把 UI 统一成「`error` 级别」着色；`message` 列只承载 `warning` / `info` | 混合存储（库 + 内存 + json）延续一个版本；失败态那轮的黄框继续走原机制 |
| (b) 给失败态建一行「占位代」 | 失败态在版本树里有载体 | 违反既定不变量；占位代内容与投影行不一致会干扰采纳；切代控件可能出现「失败的代」 |
| (c) 失败条目加列（如 `books.failed_status`） | 红条也带上级别 | 与 `round_stack.message` 语义分叉，等于承认两套消息系统 |

---

## 4. 修改范围

> 估行为粗略量级（±50%），仅供排期参考。

### 4.1 生产代码（必改）

| # | 文件 | 改什么 | 估行 |
| --- | --- | --- | --- |
| 1 | `lib/database/database_helper.dart` | `_createRoundStackTable` 加 2 列（表尾）；`_dbVersion` 20→21；新增 `if (oldVersion < 21)` 分支（2 × `_addColumnIfMissing`）+ 注释 | +6 / +14 |
| 2 | `lib/models/round_stack.dart` | `RoundStackRow` 加 2 字段 + 构造默认值 + `fromMap`（归一化）+ `toMap`（**条件写键**，照 `Round.toMap` 的 `use_stack_uuid` 先例 `lib/models/round.dart:100-102`）+ `copyWith`。**`contentMap()` 不加** | ~30 |
| 3 | `lib/database/round_stack_dao.dart` | 新增 `setMessage(txn, uuid, message, status)`（显式 2 列 UPDATE）；新增 `loadMessagesByBook()` 稀疏查询；`updateContent` **不加**（消息与内容分离） | ~30 |
| 4 | `lib/services/round_stack_service.dart` | `attachNewGeneration(..., message:, status:)` 透传到 `fromRound` / 建代；`contentFpOfStack` **不动** | ~15 |
| 5 | `lib/services/sync/sync_fingerprint.dart` | `stackDigest` 稀疏追加（方案 C，§3.3） | ~10 |
| 6 | `lib/providers/round_provider.dart` | `_setRoundWarnings` → 改写为「落库到该代」；新增按轮读取消息的缓存（替代 `gen.roundWarnings`）；`dismissRoundWarnings` → 清行 + `triggerSync`；`_dropRoundWarningsFrom` 语义简化（删轮删行天然覆盖）；失败态那轮仍走原 json 机制 | ~70 |
| 7 | `lib/screens/chat_screen.dart` | `_AgentWarningsBox` 加 `status`（三态视觉），与 `_FailureBox` 共用渲染；失败气泡传 `error` | ~45 |
| 8 | `lib/main.dart` | 视 §8 决策：保留 `FileRoundWarningsStore` 注入（兼容读取）或移除 | ~5 |
| 9 | `lib/services/round_warnings_store.dart` | 保留（仅用于失败态那条 + 旧数据一次性导入）或删除（连带 2 个测试文件） | 0 或 -171 |

**~205 行净改动，8~9 个文件**——属于中等偏小的改动面。

### 4.2 零改动但要补测试的路径（靠模型 `toMap` 自动携带）

以下路径全是「bare SELECT + 模型 `toMap()` 重插」，**代码不用改**，但每一处都要补「消息随行不丢」的用例：

`lib/services/sync/remote_snapshot_applier.dart`（整本复制 `:307`、部件下发 `:319`）、
`lib/services/database_merge_service.dart`（导入内容部件 `:469`、整本导入 `:656`、`copyWith(bookUuid:)`）、
`lib/services/sync/sync_local_snapshot.dart:86`、`lib/providers/cloud_sync_provider.dart:1206`（图片引用集：只读图片列，**不受影响**）。

⚠️ 反向风险点：`upsertRow` / `replaceBookStack` 用 `INSERT OR REPLACE` / 先清后插，**`toMap` 里漏列会静默把消息清成默认值**（不报错，`lib/database/round_stack_dao.dart:271-297`）。这是「必须把两列写进 `toMap`」的原因。

### 4.3 测试

**必改（不加就报红）——只有 1 处**：

| 文件 | 原因 |
| --- | --- |
| `test/database_migration_test.dart:1214-1239` | 该用例（v18→升级）**硬编码断言 `round_stack` 20 列的名字与顺序**，加列后直接失败。原因：v19 分支与 onCreate 共用同一 helper，从 v18 升上来时表**已带新列** → 断言必须补两行 |

**必加新用例**：

| 文件 | 补什么 |
| --- | --- |
| `test/database_migration_test.dart` | **v20→v21** 用例（`v20 → ALTER` 路径）：新增列、幂等重跑、降级回退再升、既有行零改写；并按既有 `_columnSpec` 口径（`:1400-1409`，`rounds.use_stack_uuid` 的先例）比对「ALTER 产物 ≡ 新装库」的类型/非空/默认值 |
| `test/sync_fingerprint_test.dart` | 稀疏编码等价断言：**无消息时新旧摘要逐字节相同**；有消息时摘要变化；`round_created_at` 仍不参与（既有断言 `:469-500` 保持） |

**需改锚（因黄条改存库，不是因加列）**：

| 文件 | 原因 |
| --- | --- |
| `test/round_warnings_persistence_test.dart` | 断言对象从 `FakeRoundWarningsStore.data` 改到 stack 行（`:93-95` 还显式断言「round 表不带警告字段」） |
| `test/round_warnings_store_test.dart` | 视 §8 决策：删除 / 缩到「一次性导入兼容读取」 |
| `test/agent_round_test.dart:1028`、`:1057`、`:1098` | 用例名与注释写死「仅内存」「不带任何警告字段」，需改为持久化口径 |
| `test/agent_timeline_ui_test.dart:521` | 黄框的预置方式从「注入 store」改为「预置 stack 行」 |

**已核实「不需要改」**（避免无谓改动）：

| 文件 | 为什么不用改 |
| --- | --- |
| `test/round_stack_dao_test.dart` / `test/round_stack_model_test.dart` | 二者都不硬编码完整列清单，走 `fromMap(toMap())` 往返与单键断言；DAO 用例直接跑**真实 `DatabaseHelper`**（`:29` 注入临时库路径），列增加不影响 |
| 三份夹具 DDL 副本（`test/helpers/merge_db.dart:98-123`、`test/remote_snapshot_applier_test.dart:808-833`、`test/sync_local_snapshot_test.dart:105-132`） | 它们用**显式列名 Map** 插行（如 `:882` `db.insert('round_stack', row)`），新列自动取默认值，不会 `no such column`；只有想断言消息时才需扩展 |

**建议新增用例组**（新文件 `test/round_stack_message_test.dart`）：

1. 消息落库 / 读取 / 换代保留 / 删轮随行消失 / 切代跟随该代；
2. 消息**不进**内容指纹：同内容代仍复用（防止代次爆炸）；
3. 同步搬运保真：远端下发、整本复制、导入备份三路各一例；
4. 跨版本摘要等价：**无消息的 stack，新旧编码逐字节相同**（锁定方案 C）；
5. 关闭消息 → 行清空 + 触发同步；
6. 脏值 / 超长 / 多行合并取最高级别。

### 4.4 文档（4 份必改 + 2 份禁改）

| 文档 | 改什么 |
| --- | --- |
| `docs/database.md` | §1 版本 20→21；§3 `round_warnings.json` 去留；§4 表清单；§5.3 两列 + 语义 + 7 条不变量；§7 指纹口径（消息是否参与）；§9 测试锚点 |
| `docs/database_update_log.md` | 追加 v21 条目（模板 `:265-280`）+ §1 总表一行 + 头部「最新版本」指针 |
| `docs/sync_auto_triggers.md` | ① 新增「关闭消息」触发点（**白名单是闭集**，`docs/sync_auto_triggers.md:101-104` 明确「除表内节点外不得引入触发」）；② 写明消息的 LWW 语义与「整部件取舍」 |
| `docs/agent_mode.md` | 更正 `:515-516` 与 `:207-208` 的过时描述（黄条已本地持久化） |
| ⛔ `release.yaml` / 根目录 `update_log.md` | **AGENTS.md 禁止改动**，需主人明确授权 |

> 注意区分：**根目录 `update_log.md` 禁改**，而 `docs/database_update_log.md` 按 `docs/database.md` §8.8 是**必须同步追加**的台账。

---

## 5. 兼容与容错矩阵

### 5.1 数据库侧

| 场景 | 结果 | 依据 |
| --- | --- | --- |
| 新装库 | ✅ 直接带两列 | 共用 `_createRoundStackTable`（`:739`）+ onCreate `:49` |
| v20 老库升级 | ✅ `ALTER` 加列，**不重写行**（实测 Δ0 KB） | 新增 v21 分支 + `_addColumnIfMissing`（`:523`） |
| v18/v19 更老库升级 | ✅ v19 分支建表时即带新列，v21 预检跳过 | helper 共用 + `CREATE TABLE IF NOT EXISTS` |
| **降级回退再升级**（2.5 → 2.4 → 2.5） | ✅ 幂等：列已存在则跳过，不会 `duplicate column name` | `_columnExists` 预检（`:513-520`）——这是 v9 时代实测过的「库永久打不开」事故的修复，必须保持 |
| 老数据行 | ✅ 取默认 `''`，不做数据迁移 | 同 v18 `memory_summary_rounds` 口径 |
| 新装库 ≡ 迁移库 | ✅ 类型 / 非空 / 默认值一致；**列顺序**靠「放表尾」保证一致 | `docs/database.md` §8.4 |

### 5.2 老客户端（2.4 及更早的 2.x）读写新库

| 场景 | 结果 | 说明 |
| --- | --- | --- |
| 老客户端**打开**新库 | ✅ 不报错 | sqflite 在 `options.version < oldVersion` 时什么都不做，只把 `user_version` 写回低版本（`docs/database.md:38-39`） |
| 老客户端**读** stack 行 | ✅ 忽略未知列 | 读取等价 `SELECT *`，但模型按**列名**取值（`lib/models/round_stack.dart:66-89`） |
| 老客户端**写**新行 | ✅ 新列取默认空 | 写入的列集由 `toMap()` 决定，不含新列 → 取 `DEFAULT ''` |
| 老客户端 **`INSERT OR REPLACE` / 先清后插**既有行 | ⚠️ **会静默清空**该行消息 | `round_stack_dao.dart:271-297`：REPLACE = 删旧行插新行，缺列取默认值。属可接受的降级（丢的是诊断附注，不是正文），但**必须写进文档** |
| 老客户端参与同步 | ⚠️ 该书**有消息**时会代数互推（每次同步多写一份快照） | 稀疏编码（方案 C）已把抖动限制在「真有消息的书」；两端都升级后消失 |

### 5.3 老快照 / 老备份 / 跨库搬运

| 场景 | 结果 | 依据 |
| --- | --- | --- |
| 远端快照**没有 `round_stack` 表** | ✅ 保留本地版本树（含消息），不动 | `hasTable` 守卫（`remote_snapshot_applier.dart:312`、`:320`） |
| 远端快照**有表但没有新列**（2.4 推的快照） | ✅ 读取按名取值 → 消息视为空；**整体替换会清掉本机消息**（先清后插） | 同上 + `replaceBookStack` 语义 |
| 老备份库导入（合并页） | ✅ 老备份无表 → 保留本地 stack；有表无列 → 消息读作空 | `database_merge_service.dart:96-103`、`:469`、`:656` |
| 调试页 | ✅ 自动多显示 2 列（唯一字面 `SELECT *`，`debug_database_service.dart:145`） | 无影响 |

### 5.4 数据容错

| 情况 | 处理 |
| --- | --- |
| `message_status` 脏值 / 大小写 / 空格 / `'success'` | 读时归一化为 NULL（白名单），不报错、不弹窗 |
| `message` 为空但 `status` 非空 | 视为无消息（不渲染）；可顺带在归一化时清 `status` 自愈 |
| 超长消息（模型输出的巨长报错） | 写入侧截断（建议 1000 / 4000 字符上限），防单行过大 |
| 非法 JSON / 老 `round_warnings.json` | 老实现本身已容错（`round_warnings_store.dart:138-170`）；兼容期读取失败视为无缓存 |
| 消息里意外含图片路径 | ⚠️ 图片平面的引用集**不会**收集它 → 会被当垃圾删除。**一期约定：消息只放纯文本**（若要放图，需同步改 `cloud_sync_provider._referencedImages`） |

---

## 6. 风险清单

| 风险 | 等级 | 缓解 |
| --- | --- | --- |
| 把消息误当「内容」（进 `contentFpOfStack`）→ 采纳长新代、代次爆炸 | 🔴 高 | 写用例锁定「消息不进内容指纹」；`contentMap()` 明确不加 |
| `toMap()` 漏列 → 所有搬运路径静默丢消息 | 🔴 高 | 模型四件套一起改 + 搬运路径用例 |
| 消息不进摘要 → 永远静默不同步、还会被对端覆盖 | 🔴 高 | 采用方案 C 稀疏编码 |
| 关闭消息不触发同步 → 对端推送把它带回来 | 🟡 中 | 新增触发点并登记白名单（需主人许可，因为是闭集） |
| 混用新旧客户端时该书代数互推 | 🟡 中 | 稀疏编码把影响限制在「有消息的书」；文档写明 |
| 消息变更 = 每次一份整库快照 | 🟡 中 | 消息在生成结束时写入，搭既有节点；只有「关闭」是新推送 |
| 两设备各改不同代消息 → 冲突页 + 整部件取舍丢一侧 | 🟡 中 | 已在 `docs/` 写明 LWW；不做逐代合并（与该部件既有语义一致） |
| 浅色/深色主题下三态颜色对比不足 | 🟢 低 | 复用 `NoticeKind` 既有配色（`lib/models/app_notice.dart:5-28`）+ `narrColors` |
| 失败态那条黄框仍走 json，形成「双存储」 | 🟡 中 | 一期接受并写明；二期随红条入代一并统一 |

---

## 7. 分期建议与验收标准

### 一期（建议本次做）

1. v21 迁移：两列落表尾 + 幂等 + 新装 ≡ 迁移；
2. 模型 / DAO / 服务：消息读写、关闭、随行搬运；
3. `stackDigest` 稀疏纳入（方案 C）；
4. UI 三态渲染（`warning` / `error` / `info` 预留）；
5. 黄条改存 `round_stack.message`（`warning`）；**红条继续 `books.failed_*`，仅按 `error` 着色**；失败态那轮的黄框沿用原机制；
6. 顺手修 §1.2 里与失败条目相关的可确证问题：③「清除失败条目」补 `triggerSync`（①⑤ 属行为设计，另议）；
7. 文档四份 + 测试（§4.3）。

**验收标准（可执行）**
- `flutter test` 全绿；新增 v20→v21 迁移用例（幂等 / 回退再升 / 既有行零改写 / DDL 一致）；
- 无消息的 stack：新旧摘要**逐字节相同**（用例锁定）；
- 消息不进内容指纹：连续两次同内容采纳**不新增代**（用例锁定）；
- 双设备模拟：A 改消息 → B 拉到；A 关闭 → B 跟随清空（不复活）；
- 老库（v20 dump 或夹具）升级后：老行消息为空、正文零变化；
- 空间实测复核：`ALTER` 后文件大小不变、空消息库增量 < 0.05%。

### 二期（需另行评审）

把失败态也挂到「代」上（§3.6 的 (b)/(c)），同时统一 `round_warnings.json` 的去留。这一步会牵动「失败不写 `rounds` / `round_stack`」的既定不变量与「切代清失败态」的语义，**建议单独出方案**。

---

## 8. 需主人拍板的 6 件事

1. **红条一期怎么办**：先按 `error` 着色、仍存 `books.failed_*`（推荐），还是本次就做「失败态载体行」？
2. **`message_status` 的默认值**：`DEFAULT ''`（推荐，与仓库习惯一致）还是默认 `NULL`？
3. **消息是否进同步摘要**：采用方案 C 稀疏编码（推荐），还是接受方案 B 的跨版本抖动？
4. **`round_warnings.json`**：一期保留（兼容读 + 失败态用，推荐）还是直接删除？
5. **「关闭消息」是否新增同步触发点**：（推荐新增）——白名单是闭集，需主人明确许可并同步改 `docs/sync_auto_triggers.md`。
6. **消息长度与合并口径**：单条 ≤1000 / 整列 ≤4000 字符、多行 `\n` 合并、级别取最高（推荐值，可调）。

---

### 附：本次实测与调研的可复现信息

- 空间探针：`.agents/perf/round_stack_message_size_probe_2026_10_17.py`（Python `sqlite3`，固定随机种子；原始输出 `.agents/perf/size_probe_output_2026_10_17.txt`）
- 基线测试：`flutter test test/round_warnings_persistence_test.dart test/round_generation_failure_test.dart test/round_warnings_store_test.dart` → 24 passed
- 关键证据文件：`lib/database/database_helper.dart`、`lib/models/round_stack.dart`、`lib/database/round_stack_dao.dart`、`lib/services/round_stack_service.dart`、`lib/services/sync/sync_fingerprint.dart`、`lib/services/sync/sync_merge_planner.dart`、`lib/providers/round_provider.dart`、`lib/services/round_warnings_store.dart`、`lib/database/book_dao.dart`
