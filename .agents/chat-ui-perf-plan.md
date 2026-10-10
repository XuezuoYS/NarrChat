# 对话页（ChatScreen）UI 性能优化方案 — v3（含 L0 实测数据）

> 状态：**P0-① / P0-② / P0-③ 已落地**（见 §8 / §9 / §10）；P0-④ 待办。
> 环境：Flutter 3.47.5（framework 6a19cca56）/ Dart 3.13.4；目标平台 Windows + Android。
> 证据来源：本仓库源码 + Flutter SDK 源码（`C:\Language\Flutter\flutter`）+
> flutter_markdown 0.7.7+1 源码（pub cache）+ **本轮 L0 实测探针**（`.agents/perf/`）。

---

## 0. L0 实测数据（本轮，可复现）

探针：`flutter test .agents/perf/chat_cost_probe_test.dart`、`.../markdown_build_probe_test.dart`
（两次运行结果一致；下表为实测值）。

| 编号 | 测量项 | 结果 |
|---|---|---|
| **M1** | 单个 AI 气泡内的 `MarkdownBody` 数（= 全量 Markdown 构树次数） | **6 次**（1 正文 + 5 推荐行动选项）；用户气泡 0 次 |
| **M1b** | 单个 AI 气泡内的 `SelectionArea` 数 | **2 个** |
| **M2** | 「滚动到底部」链路（120 轮，117 短 + 3 长） | **越界帧 45/80**；最大越界 **390.7px**；位置变化 **57 帧**；**68 帧后才稳定**；收敛 **1306ms**；最终误差 0.00px |
| **M2b** | 滚动 30 帧（向上揭示历史条目） | 74–91ms，**2.5–3.1 ms/帧**（debug 测试环境） |
| **M3** | 流式每 chunk 成本曲线（60 轮底稿，每 chunk 8 字） | 800 字 **7.0ms** → 8000 字 **15.0ms**（**2.15x**）；一次 8000 字回复的增量开销合计 **≈10.7s** |
| **M4** | 成本归因（同一探针内） | 空转帧 0.033ms；**一帧固有开销（动画在跑、无通知）4.68ms**；空增量通知 4.48ms（⇒ 通知本身 ≈0）；离底后空增量 3.95ms（⇒ 每帧 `jumpTo` 链路 ≈**0.5ms**）；**与正文长度线性相关的净工作 ≈ 2.3ms@800 字 → 10.3ms@8000 字** |
| **M5** | `flutter_markdown` 的 `_kBlockTags` 全局列表（递增扫描：每步灌入 500 次构树，共 20000 次；同一步内 A/B + 纯文本对照） | 大文档单次构树耗时**全程平稳**（500 条时 4.55ms → 20000 条时 2.46ms，早期高值纯属 JIT 预热；全程 2.0~2.7ms）；比值 7.43→9.27 的"上升"**全部来自对照组自身继续变快**（0.61→0.22ms）→ **该缺陷不咬人** |
| **M5b** | 单点前后对比（早先版本，三次独立运行） | 净倍数 1.04x / 1.11x / 1.48x → 噪声与效应同量级，**不足以支撑"主因"结论** |

### L0 结论（含一处**推翻**）

1. **【假设被推翻】** 我原先判断「`flutter_markdown` 的 `_kBlockTags` 无界增长是越聊越卡的主因」——
   **实测不成立**。该缺陷在代码里真实存在（`builder.dart:253-257` 无去重 `add`、
   `:36` 用 `List.contains`），但 M5 的递增扫描显示：把列表灌到 **2 万条**，
   大文档的单次构树耗时**没有任何上升趋势**（markdown 平，对照更平）。
   原因：`_isBlockTag` 只对**元素**调用（本文档约 ~20~50 次/次构树），且多数标签
   （`p`/`h*`/`li`/`ul`/`ol`…）在列表前 18 项就命中；未命中项的 `String ==` 先比长度、极快。
   → **降级为 P3**，仅保留「数量级哨兵」断言（阈值 2.0）。
2. **【确认】流式生成的真实可优化成本是「与正文长度线性相关的那部分」**：
   2.3ms@800 字 → 10.3ms@8000 字，而一个 8000 字回复要付约 **10 秒** CPU。
   这部分正是「每 chunk 全量重解析 + 全量重排」。→ 仍是 P0 首选。
3. **【确认】通知/重建路径与每帧 `jumpTo` 都不贵**（≈0ms / ≈0.5ms）。
   M4 里那 4.68ms「一帧固有开销」是 **debug 测试环境的整帧管线成本**（含 1400×900
   全屏重绘 + 侧栏），release 真机会低很多，**不能**当作应用层工作来看待；
   真正的应用层工作只有「内容相关」那一项。
4. **【确认】落底「多弹一段」是几何层面的确定性缺陷**：80 帧里有 45 帧 `pixels > maxScrollExtent`，
   最大越界 390.7px（≈ 视口高度的 43%），要 68 帧 / 1.3 秒才稳定 → 与用户描述完全对应。
5. **【确认】滚动历史本身不慢**（2.5–3.1ms/帧，debug 环境下限），
   但每个新揭示的气泡要付 6 次 Markdown 构树（M1）→ 这是「滚动时的常数放大」。
6. **仍未测**：Windows profile 真机 timeline（需要可交互 DevTools + 一本真实长书）。
   这一步留待你确认后做（见 §3 L0 剩余项）。

> ⚠️ 所有绝对 ms 都来自 `flutter test`（debug、Ahem 测试字体、无 GPU 光栅），
> **只用于横向比较与趋势**；可靠的信号是**次数、比值、越界像素、增长趋势**。

---

## 1. 逐症状根因（数据支撑版）

### 症状 1「打开书自动到底部 → 往下多弹一段 + 卡顿」→ 已复现（M2）
机制（SDK 源码级）：
- 懒加载列表的 `maxScrollExtent` 是**外推估算**（`widgets/sliver.dart:1129-1143`；
  `widgets/scroll_metrics.dart:86-96` 文档明说「可能是估算值并随布局变化」）；
- `ScrollController.jumpTo` **不做范围检查，且跳转后立刻启动 ballistic 活动**
  （`widgets/scroll_controller.dart:227-238`）→ 越界即触发 `ScrollSpringSimulation`
  回弹（`widgets/scroll_physics.dart:894-913`）；
- 当前 [chat_screen.dart:482-528](lib/screens/chat_screen.dart#L482-L528) 在估算值上
  `jumpTo` 并接一个最多 10 帧的逐帧补滚循环（每帧 `scheduleFrame()`）；
- 期间底部留白还在从 0 长到真实输入面板高度（[chat_screen.dart:2196](lib/screens/chat_screen.dart#L2196)、
  `:2512-2521` 帧末才测出）→ `maxScrollExtent` 二次变化 → 继续补滚。
→ 实测：45/80 帧越界、最大 390.7px、57 次位置变化、1.3s 才稳定。

### 症状 2「生成时卡顿」→ 已量化（M3/M4）
- 每 chunk「全量解析 + 全量重排」→ 成本随正文线性上升（2.3→10.3ms）；
- **不是**通知/重建路径的锅（M4：≈0ms），**不是** `_kBlockTags` 的锅（M5：+4~11%）；
- 另叠加 M1 的常数放大（每个气泡 6 次构树）在滚动/收尾时生效。

### 症状 3「滚动条乱动」→ 机制明确（SDK 源码级）
前进方向列表在底部追加内容时 **`pixels` 不会被自动推进**
（`widgets/scroll_position.dart:642-682`；`widgets/scroll_physics.dart:620-636` 注释里
明确说「新增内容时刻意不跳到 max extent」）→ 只能靠脚本每帧 `jumpTo` 拉回，
于是拇指比例在「内容增长」与「拉回」之间来回振荡；`maxScrollExtent` 又随估算阶跃变化。
自绘拇指几何还不区分方向（`narr_chat_scrollbar.dart:48-57, 70-93`）。

---

## 2. 已确认的方案方向（你已拍板）
1. 验收基准：**两者都要，量化以 Windows 桌面为主**。
2. **接受 `reverse: true` 底部锚定**（`pixels==0` 即底部 → 删除 `jumpTo(max)` 与补滚循环）。
3. 流式正文：**按块增量渲染**（已封闭块冻结、只重排尾部残块）。
4. `SelectionArea`：**收敛为「列表外一个」**（顺带修好「跨气泡无法选中」）。
5. 常驻 UI：**不动观感**（AI 操作栏、时间线块保持现状）。
6. 长会话：**不限制轮数**。
7. 节奏：**先只做 L0** ← 本文件 §0 即 L0 交付物。

---

## 3. 修订后的优先级（据 L0 数据）

### P0（收益/风险比最高，先做）
1. ~~**流式正文按块增量渲染**~~ → **已落地**（见 §8；实测合计 6.3x、末段 7.4x，无空行内容无回归）。
2. ~~**推荐行动改为一次解析**~~（M1：6 次 → 1~2 次构树/气泡）→ **已落地**（见 §9；
   实测 MarkdownBody 6 → 1、揭示一个旧气泡的构建成本 1.88x）。
3. ~~**底部锚定 `reverse: true`**（消除 M2 的 45/80 越界帧与 1.3s 收敛）~~
   → **已落地**（见 §10；实测越界帧 **0/80**、最大越界 **0.0px**、到底后**零补滚**）。
   顺带修掉一个此前未意识到的缺陷：**离底阅读时内容被推走**（新增
   `lib/widgets/reading_anchor.dart` 把「视口下方长高」补回滚动偏移，实测位移 -225px → 0px）。
4. **`SelectionArea` 收敛**：主收益是**修正跨气泡选中的设计缺陷**（`selectable_region.dart:189-192`），
   成本收益待 P0 落地后再补测（当前无法在不改产线代码的前提下测准）。

### P1
5. 流式通知合帧节流（虽实测通知本身≈0ms，但**每 chunk 强制一整帧**在真机 release 下仍有意义；
   且能顺带减少 P0 未覆盖的零星重建）。
6. 时间线子块 widget 复用（未变化的思考/工具块复用同一 widget 实例，跳过子树 rebuild）。
7. 底部留白不再依赖帧末测量（避免 `maxScrollExtent` 二次变化，配合 reverse 后此项收益变小）。
8. 楼层跳转偏移建模 O(n·m) → 有序结构；测量表加 LRU 上限。

### P3（据 L0 降级）
- ~~`_kBlockTags` 无界增长的处置（迁移 fork / vendored patch）~~ →
  **实测 2 万条累积下大文档构树耗时无上升趋势，不值得为它引入自维护副本或迁移依赖**；
  仅保留数量级哨兵断言。若将来真要做，顺手在 vendored copy 里改一行即可。
- `flutter_markdown` 已 discontinued → 作为**长期**技术债记录，不与本次优化绑定。
- 自研 Markdown 渲染内核：仍是最彻底的方案（可同时解决解析/构树/重排），但工作量大，
  等 P0 落地后再评估「收益是否还值得」。

---

## 4. `reverse: true` 落地要点（SDK 已核实）
- offset 0 = 底部；index 0 被强制锚在 layoutOffset 0（`widgets/sliver.dart:994-995`）；
  在 index 0 插入新子项**不改变 `pixels`**（`rendering/sliver_list.dart:175-195, 223-259`）；
  `animateTo(0)` 即「滚到底部」；`getOffsetToReveal` 支持 `AxisDirection.up`
  （`rendering/viewport.dart:1166-1174`）。
- 必改：条目 `ValueKey` + `findChildIndexCallback`（否则 index 偏移会重建元素/丢状态：
  `widgets/sliver.dart:969-1058`、`scroll_delegate.dart:517-542`）；
  自绘滚动条**方向感知**（`ScrollThumbGeometry` 的拇指位置与拖动数学）；
  `_isNearBottom` 语义（`pixels <= threshold`）；楼层跳转测量坐标系；
  以及断言 `offset ≈ max` 的测试（`chat_auto_scroll_test.dart` 多处、`floor_jump_test.dart:183,232`）。
- ➡️ **以上已全部落地**，逐条实测与新增项（阅读位置补偿、手势方向、易主取舍）见 §10。

## 5. 验收标准（建议写进 PR）
1. 落底：**越界帧 = 0**，位置变化帧 ≤ 2，稳定帧数 ≤ 5（当前 45 / 57 / 68）。
   → ✅ **已达成**（P0-③ 落地后实测：越界帧 **0/80**、最大越界 **0.0px**、
   到底之后**零次**位置变化；「位置变化帧」在带 300ms 动画的路径上必然有 ~20 帧，
   故该条按「动画结束后不再变动」判定，见 §10）。
2. 流式 8000 字：每 chunk 净工作不再随长度线性上升（目标 8000 字 ≤ 800 字的 1.5 倍）；
   总增量开销 ≤ 2s 量级（当前 ≈10.7s）。
3. 单个 AI 气泡 `MarkdownBody` 数 ≤ 2（当前 6）→ ✅ **已达成**（P0-② 落地后实测 **1**）。
4. 滚动 30 帧 ≤ 当前基线；历史气泡不重复解析。
   → ✅ 2.85ms/帧（基线 2.5–3.1ms，P0-③ 前后同量级，无回归）；历史气泡不重复解析见 §8。
5. `flutter test` 全绿；`chat_stream_rebuild_scope_test.dart` 的实例同一性约束不破。
   → ✅ P0-③ 落地后 **1752 passed / 1 skipped**。

## 6. 回归面
| 改动 | 风险 | 验证 |
|---|---|---|
| reverse 列表 | 自绘滚动条方向、楼层跳转坐标、抽屉横滑、`offset≈max` 测试语义 | ✅ `narr_chat_scrollbar_test`（新增 reverse 几何 2 例）/`floor_jump_test`（20 例全绿）/`chat_auto_scroll_test`（7 例）/`chat_round_version_test` + §10 实测；桌面手工待你复验 |
| 离底阅读位置补偿 | 与用户拖拽/惯性/动画冲突、贴底语义被破坏、误补偿 | ✅ `reading_anchor_test`（11 例）+ `chat_auto_scroll_test`「离底阅读…不推走已读内容」+ 探针 D6/D7 + `reading_drift_probe_test` |
| 流式按块渲染 | 未闭合代码块、光标位置、结尾排版跳变 | `markdown_preview_test` + 新增单测 + 长代码块手工 |
| 推荐行动单次解析 | 双击插入、选中、序号/符号列对齐 | `recommended_action_insert_test`/`recommended_action_view` + 手工 |
| 单个 SelectionArea | 跨气泡选中、选择时自动滚动、右键菜单抑制 | `markdown_preview_test:118`、`token_usage_pill_test:197` + 手工复制 |
| 通知节流 | `done`/取消路径延迟、`pumpAndSettle` 语义 | `waitSendDone` 脚手架 + 现有流式测试 |

## 7. L0 剩余项（需你确认后做）
1. **Windows profile 真机 timeline**：`flutter run --profile -d windows`，用一本
   200 轮级别的真实书抓「打开落底 / 生成一整轮 / 来回滚动」三段；需要可交互 DevTools
   或改成 `integration_test` + `traceAction` 的自动化采集（要加 dev 依赖并跑桌面构建）。
2. 若要更强的归因：在 debug 下加 `--dart-define=NARRCHAT_PERF_LOG` 埋点
   （itemBuilder 次数 / 构树次数 / `jumpTo` 次数），默认关闭。
3. ~~探针提升为回归测试~~ → **已做**：落底越界/零补滚（`chat_auto_scroll_test.dart`
   「贴底生成：连续增量不改变滚动偏移」）、每气泡构树次数（`recommended_action_view_test.dart`）、
   离底阅读不漂移（`chat_auto_scroll_test.dart` + `reading_anchor_test.dart`）已进 `test/`；
   耗时类留在 `.agents/perf/` 手工运行。`chat_cost_probe_test.dart` 的 L0-1 断言已按
   「越界帧 = 0 且到底后零补滚」反转（不再钉住缺陷）。

---

## 8. P0-① 落地记录：流式正文按块增量渲染（已完成）

**状态**：已落地；`flutter analyze` 干净、`flutter test` 全绿（1733 passed / 1 skipped）。

### 8.1 改动面（2 新增 + 2 处接线/抽取）
| 文件 | 作用 |
|---|---|
| [lib/utils/streaming_markdown_blocks.dart](../../lib/utils/streaming_markdown_blocks.dart)（新） | 纯函数块切分 `splitStreamingMarkdownBlocks`（无损、单调） |
| [lib/widgets/streaming_markdown.dart](../../lib/widgets/streaming_markdown.dart)（新） | `StreamingMarkdown`：冻结块 widget 复用 + 单一 `SelectionArea` |
| [lib/screens/chat_screen.dart](../../lib/screens/chat_screen.dart#L4647) | `_narrativeText`：`MarkdownPreview('$content▍')` → `StreamingMarkdown(data: content, trailing: '▍')` |
| [lib/widgets/markdown_preview.dart](../../lib/widgets/markdown_preview.dart#L167) | 抽出 `GitHubMarkdownStyle.blockSpacing`（块间隔单一真源） |

**机制**：每帧只把「已由空行封闭的块」解析一次并把 widget 实例存进 state；父级重建时
**同一实例**被 `Element.updateChild` 同一性短路跳过 → 该子树不 rebuild、`MarkdownBody`
不重新解析、`RenderParagraph` 不重新排版。只有尾部残块随增量重建。块间距用
`blockSpacing` 手工补出（与 `MarkdownBody` 内部一致）；整段正文仍只有**一个**
`SelectionArea`（在各冻结块**之外**），跨块连续选中不受影响。

**切分规则（安全边界）**：只在空行处切；且空行**上一行必须自成一块**——
普通段落行 / ATX 标题行 / 已闭合围栏结束行；列表项、引用、表格行、前导空白续行之后
一律不切（松散列表等跨块耦合）；段内单换行绝不切（软换行→段间空行会造成可见跳变）；
围栏代码块与可跨空行的原始 HTML 块内部不切；链接/脚注引用定义出现后停止切分。

### 8.2 实测（`.agents/perf/streaming_block_probe_test.dart`，单独运行）
**微基准 A/B（隔离宿主，同内容序列，扣空转底噪；每 chunk 8 字 × 1000 次）**

| 内容形态 | 指标 | 现状＝整段 `MarkdownPreview` | P0-①按块增量 | 倍数 |
|---|---|---|---|---|
| 空行分段（每 6 chunk 一个空行） | 首批（800 字） | 6.7–7.0 ms/次 | **1.5–1.6 ms/次** | 4.4x |
|  | 末批（8000 字） | 36.1 ms/次 | **4.6–4.9 ms/次** | **7.4x** |
|  | 末/首增长 | 5.1–5.4x | 3.0–3.2x | — |
|  | 合计 1000 次增量 | **19.7 s** | **3.1 s** | **6.3x** |
| 单段无空行（`'字'×8`，无块边界） | 合计 1000 次增量 | 7.19 s | 7.20 s | 1.00x（无收益、**无回归**） |

**端到端结构事实（对话页真实链路，60 轮底稿 + 8332 字流式正文）**

| 内容形态 | 已冻结块 | 每帧真正重建的尾部残块 |
|---|---|---|
| 空行分段 | **166** | **33 字**（+光标） |
| 单段无空行 | 0 | 8001 字（与现状同路径） |

**归因对照（同探针内）**
- 给每个冻结块外挂 `RepaintBoundary`：3053 ms vs 3125 ms → **无收益，已撤销**；
- 同一路径关掉选中容器（`selectable: false`）：3214 ms → **1913 ms（−40%）**，
  但**增长倍数不变**（都是 3.17x）→ 残余增长不是 `SelectionArea` 造成，而是
  「屏幕上 N 个文本块」的平台级遍历/合成成本（P0-④ / P1 再评估）。

### 8.3 与 §5 验收标准的对照
| 标准 | 结果 |
|---|---|
| 1 落底越界帧 = 0 / 位置变化 ≤2 / 稳定 ≤5 帧 | 未做（P0-③） |
| 2 8000 字净工作 ≤ 800 字的 1.5 倍 | **未完全达成**：空行分段 3.0–3.2x（但斜率降到 1/8：末批便宜 7.4x、合计 6.3x）；单段无空行 1.00x（不适用）。残余为平台级遍历成本，非解析成本 |
| 3 单气泡 `MarkdownBody` ≤2 | 未做（P0-②） |
| 4 滚动 30 帧 ≤ 基线 | 未测（留到 P0-②/P0-③ 之后） |
| 5 全绿 + 流式重建范围同一性不破 | ✅ 1733 passed / 1 skipped；`chat_stream_rebuild_scope_test` 原用例通过，并新增生产接线用例 |

### 8.4 测试
- [test/streaming_markdown_blocks_test.dart](../../test/streaming_markdown_blocks_test.dart)（11 例）：无损 / 单调（逐字增长扫描）/ 段内换行不切 /
  列表·引用·表格不切 / 围栏（未闭合与已闭合）/ 原始 HTML 块 / 引用定义屏障 / CRLF / 标题可切。
- [test/streaming_markdown_test.dart](../../test/streaming_markdown_test.dart)（9 例）：冻结块 widget 实例与 `MarkdownBody` 实例同一（= 未重建未重解析）/
  尾部不误冻结 / 缓存失效（换轮、base 变化）/ **渲染文本与整段解析逐块等价** / 光标只在尾部 /
  单选区 / 空数据。
- [test/chat_stream_rebuild_scope_test.dart](../../test/chat_stream_rebuild_scope_test.dart)：新增「流式正文按块增量渲染：已封闭段落不随增量重建」（生产接线）。

### 8.5 已知不覆盖（刻意保守，宁可少冻结也不改观感）
1. **无空行的单段正文**（含段内单换行）不切分 → 与现状逐毫秒一致（1.00x）。要做只能牺牲
   内联 md 保真（尾部走纯文本）或改软换行语义，代价是可见排版跳变，故不做。
2. 跨空行的自定义块语法内部（GitHub Alerts 的行首 `>` 情形已被「上一行需自成一块」拒绝；
   `<script>` / `<pre>` / `<!--` 等按围栏同等处理）。
3. 链接 / 脚注引用定义之后不再切分（定义是文档级语义，必须留在尾部）。
4. 残余「N 个文本块」的每帧遍历成本（上表归因）——需要换渲染结构或收敛选中容器，属 P0-④/P1。

---

## 9. P0-② 落地记录：推荐行动改为一次解析（已完成）

**状态**：已落地；`flutter analyze` 干净、`flutter test` 全绿（1737 passed / 1 skipped）。

### 9.1 改动面（1 处渲染路径 + 1 处公共 API 收敛）
| 文件 | 作用 |
|---|---|
| [lib/widgets/recommended_action_view.dart](../../lib/widgets/recommended_action_view.dart) | 选项行 `MarkdownPreview(option.content)` → `Text.rich(MarkdownPreview.buildInlineSpans(...))`；补「为什么不再走 MarkdownPreview」的说明 |
| [lib/widgets/markdown_preview.dart](../../lib/widgets/markdown_preview.dart#L450) | 新增公开 `MarkdownPreview.buildInlineSpans`（内联 Markdown → `InlineSpan`，共享一份 `md.Document`）；把 `_AlertBlockBuilder` 用过的私有 `_inlineSpans` / `_spans` 收敛成同一个 `_nodesToSpans`（去掉重复的内联渲染实现） |

**一次解析口径**（与方案 §3-P0-2 的对应关系）：
- 选项内容按提示词契约是**单行**文本（`recommended_action_parser` 逐行剥离标记），块级解析本就是多余 → 改为
  **内联解析**（`md.Document.parseInline`，与 `MarkdownPreview` 共用同一套 `extensionSet`），再用 `Text.rich` 排版；
- **非列表文本仍交给 `MarkdownPreview`**（块级结构、表格、引用等不能丢）；
- 于是单个 AI 气泡的构树次数 = **正文 1 + 非列表文本段数**（选项 0）。

### 9.2 实测
**结构（`.agents/perf/chat_cost_probe_test.dart` L0-3，同时已把断言从「钉住缺陷」反转为修复后期望）**

| 指标 | 改造前 | 改造后 |
|---|---|---|
| 单个 AI 气泡 `MarkdownBody`（M1） | 6（正文 1 + 选项 5） | **1**（正文 1 + 选项 0） |
| 单个 AI 气泡 `SelectionArea` | 2 | 2（未变，P0-④ 的目标） |

**微基准（`.agents/perf/recommended_action_probe_test.dart`，单独运行）**
交替渲染两组内容以逼出「从零构建一个旧气泡（正文 + 5 选项）」的成本，4 批 × 200 次：

| batch | 现状（每项一个 `MarkdownBody`，探针内按原实现重建） | P0-② 一次解析 | 倍数 |
|---|---|---|---|
| 0 | 6.35 ms | 3.02 ms | 2.10x |
| 3（预热后） | 2.84 ms | 1.68 ms | 1.69x |
| **平均** | **4.11 ms** | **2.18 ms** | **1.88x** |

（探针同时断言页面 `MarkdownBody` 数：现状 6 → P0-② 1。）

### 9.3 观感 / 行为保持
- 既有用例全绿：`chat_bubble_test`（符号列、双击插入、单击不插入、长按框选复制、触屏双击、
  未接线不绑手势）、`recommended_action_insert_test`（落点三分支 + 焦点 + 不发送）；
- 符号列宽 / 间距 / 手势 / 选中语义一律未动；非列表文本的块级渲染未动；
- **已知微差（少见情形）**：选项行内的**行内代码**此前由 `_InlineCodeBuilder` 画圆角容器，
  现在走内联 span 的底色（与 GitHub Alerts 内部同款）。仅当某条选项里出现 `` `code` `` 时
  有一档底色差异；
- 链接：`onTapLink` 本就为空（此前只有一个 no-op 识别器），现在不再建识别器，交互结果不变。

### 9.4 测试
- [test/recommended_action_view_test.dart](../../test/recommended_action_view_test.dart)（新增 4 例）：① 选项行零 `MarkdownBody`（构树次数 = 非列表文本段数）、
  ② 非列表文本仍走块级解析、③ 选项内行内 Markdown 保真（粗体 / 行内代码 / 链接 / 继承 `base`）、
  ④ **单个 AI 气泡构树次数 ≤ 2（P0-② 验收）**。
- 交互层沿用既有 `chat_bubble_test.dart` / `recommended_action_insert_test.dart`（不重复覆盖）。

---

## 10. P0-③ 落地记录：底部锚定 `reverse: true`（已完成）

**状态**：已落地；`flutter analyze lib test .agents/perf` 干净、`flutter test` 全绿
（**1752 passed / 1 skipped**，其中 P0-③ 新增/改写 14 例）。

### 10.1 改动面（1 新增 + 3 处改动）
| 文件 | 作用 |
|---|---|
| [lib/screens/chat_screen.dart](../../lib/screens/chat_screen.dart) | 消息列 `reverse: true` + 逻辑序号反转 + 条目身份 Key + `findChildIndexCallback`；删除「jumpTo(估算 max)+逐帧补滚」；`_isNearBottom`/`_autoFollowIfNeeded`/通知语义改为 `pixels <= 阈值`；楼层跳转偏移模型按 reverse 反向；代次切换补偿改符号；接入阅读锚点 |
| [lib/widgets/narr_chat_scrollbar.dart](../../lib/widgets/narr_chat_scrollbar.dart) | `ScrollThumbGeometry.thumbTop`/`pointerOffset` 增加 `axisDirection`（默认正向，反向镜像拇指位置与拖动方向）；两处调用传入 `pos.axisDirection` |
| [lib/widgets/reading_anchor.dart](../../lib/widgets/reading_anchor.dart)（新） | 离底阅读期间「视口下方条目长高」的实高测量（`ReadingAnchorItem` + 布局阶段上报）与滚动物理补偿（`ReadingAnchorScrollPhysics`） |

**核心机制**
1. **贴底不再需要脚本**：`reverse: true` 下 offset 0 即底部，新内容插在坐标起点，框架自身
   保持 `pixels`（`rendering/sliver_list.dart:175-195`）。`_scrollToBottom` 只 `jumpTo/​animateTo(minScrollExtent)`，
   `_settleScrollToBottom` 整套收敛循环删除。
2. **条目身份 Key + `findChildIndexCallback`**：末尾追加条目会让所有已有条目的**视图下标 +1**，
   只有键能让框架把元素（连同 State）搬到新下标。
3. **楼层跳转坐标系反转**：条目顶边偏移 = `pixels + viewportDimension − 视口内 y`；
   「首个可视项」判据用「顶边 − 高度 < 视口顶」；锚点推算正负号反向；前导 padding 是
   `_composerHeight + 8`；`getOffsetToReveal` 取 **alignment 1.0**（reverse 下视口顶是 trailing 边）。
4. **离底阅读位置补偿**（新增发现，见 10.3）。

### 10.2 实测（探针逐个单独运行）
**落底链路（`.agents/perf/chat_cost_probe_test.dart` L0-1：120 轮，从顶部点「滚动到底部」）**

| 指标 | 改造前（M2） | P0-③ 落地后 |
|---|---|---|
| 越界帧（>0.5px） | **45/80** | **0/80** |
| 最大越界 | **390.7px** | **0.0px** |
| 位置变化 | 57 帧 | 20 帧（= 300ms 动画本身），**到达底部后 0 帧** |
| 收敛 | 68 帧 / 1306ms | 首次到底部于第 21 帧（动画结束），其后无变动 |
| 最终误差 | 0.00px | 0.00px |

**合成宿主语义核对（`.agents/perf/reverse_anchor_probe_test.dart`，单独运行）**

| 编号 | 事实 |
|---|---|
| D1 | 贴底追加条目：12 帧 `pixels` 恒为 0、无越界；新条目底边距视口底 = 200（= `padding.bottom`，语义不变） |
| D2/D3 | **离底时内容增长会推走可视内容**：追加 120px → 参考项上移 **−120px**；再长高 60px → 累计 **−180px**（`pixels` 不变） |
| D4 | 元素/State 复用：key + 回调 → 只有新条目新建 State（1）、零错绑；**缺回调 → 6 个可见条目全部重建**；无 key → 6 个 State 被错绑到别的条目 |
| D5 | `reverse` 下 `padding.bottom` 是**前导**（贴底一侧）：末条底边距视口底 = 200、`maxScrollExtent` = 内容+前后 padding−视口 |
| D6a | 生产实现：离底 + 末尾长高 60px → 参考项位移 **0.0px**、`pixels` 300 → **360**（补偿量 = 长高量） |
| D6b | 生产实现：离底 + **追加新条目**（末尾易主）→ **不补偿**（参考项 −120px）——刻意的保守取舍，见 10.4 |
| D6c/D6d | 生产实现：贴底时同两种变化 → `pixels` 恒为 0（「新内容顶上去」语义保留） |
| D7 | 视口**上方**条目长高 60px → 可视内容位移 0.0px、`pixels` 不变（不误补偿） |
| D8 | 手势方向：reverse 下**手指向下**拖动 → `pixels` 0 → 300（揭示更旧内容）；**手指向上** → 0（贴底） |

**离底阅读漂移（真实对话页，`.agents/perf/reading_drift_probe_test.dart`）**

| 场景 | 修复前 | 修复后 |
|---|---|---|
| A：离开底部时流式气泡已长高且被构建（20 段增量） | 参考部件全局 top **−150px+**（持续被推走）、`pixels` 不变 | 参考部件位移 **0.0px**、`pixels` +600（补偿） |
| B：离开底部时气泡还很矮、被移出 cache 区（40 段增量） | 0px（框架冻结布局模型，`maxScrollExtent` 也不增长） | 0px（无需补偿，也不误补偿） |

> ⚠️ 度量口径的坑：**`maxScrollExtent` 的增量不能当作漂移量**——懒加载列表的 extent 是估算值
> （`rendering/sliver_list.dart:299-311`），一个超高子项会把平均高度拉爆：A 场景实测 Δmax =
> **2800px**，而真实增长仅数百 px。补偿量必须来自**条目实高**（10.3）。

**回归核对**：L0-2 流式 8000 字 7.2 → 15.8ms/chunk（2.2x，与 P0-③ 前同量级，无回归）；
L0-3 单气泡 `MarkdownBody`=1、`SelectionArea`=2（不变）；L0-4 滚动 30 帧 2.85ms/帧（基线 2.5–3.1ms）。

### 10.3 新增：离底阅读位置补偿（`lib/widgets/reading_anchor.dart`）
**为什么必须做**：reverse 列表把新内容插在坐标起点，**视口下方**的条目长高会让可视内容整体
上移（`visualY = viewportDimension + pixels − offset`）。贴底时这正是想要的；但用户上翻阅读
历史时就成了「读着读着整段内容自己往上跑」——实测单条气泡长高多少就推走多少
（A 场景 20 段增量推走 150px+、合成宿主里位移与长高量严格相等）。

**做法**
- `ReadingAnchorItem` 包住**每个**条目（纯代理），只有「列表逻辑末尾」那一条（reverse 下
  即视觉底部、流式正文生长处）在**布局阶段**上报自己的实高；
- `ReadingAnchor` 记住「来源身份 + 实高」，`takeGrowth()` 取出**自上次读取以来的增量**并清零；
- `ReadingAnchorScrollPhysics` 在 `adjustPositionForNewDimensions` 里把增量补进滚动偏移。
  该钩子在 `RenderViewport.performLayout` 的布局循环内被调用，修正会**带着新偏移重排一次**
  （`rendering/viewport.dart:1723-1740`），因此**同一帧**生效、不产生漂移帧、不改滚动活动
  （不打断拖拽）；贴底时（`pixels <= min + 0.5`）不补偿；结果夹取在合法范围。
- 读取即清零 ⇒ 布局重试的第二次调用读到 0，不会重复补偿（不会触发 `maxLayoutCycles` 断言）。

### 10.4 已知取舍与不覆盖
1. **末尾条目易主时不补偿**（D6b）：`流式插槽 → 落库气泡`、追加/删除轮次都会换末尾条目，
   此时「不补偿」比「按高度差补」安全（后者遇到「新条目根本没被构建过」会凭空跳一段）。
   代价是**生成结束那一刻**若用户正在阅读历史，可能有一次几十~百 px 的位移；此时本来也会
   亮「有新内容」红点。要彻底消除需按「视口下方所有条目」逐项建模（P1）。
2. **底部留白变化不补偿**：输入面板长高（`_composerHeight`）会推动内容（属 P1-7
   「底部留白不再依赖帧末测量」的范畴）。
3. **视口上方条目长高**不补偿——它本来就不推动可视内容（D7）。
4. 用户**正在拖拽/惯性滚动**时补偿照常进行（补偿只改位置、不改活动，不会打断手势）；
   这比 postFrame 里 `jumpTo` 的方案更安全（后者会 `goIdle()` 掐断拖拽）。

### 10.5 测试
- [test/reading_anchor_test.dart](../../test/reading_anchor_test.dart)（新增 11 例）：`ReadingAnchor` 对基/增量/清零/易主/负增量；
  `ReadingAnchorItem` 只测 active 条目 + 布局透明；`ReadingAnchorScrollPhysics` 离底补偿、
  贴底不补偿、无增长不动、夹取上限、`applyTo` 传递同一 anchor（与平台物理叠加）。
- [test/chat_auto_scroll_test.dart](../../test/chat_auto_scroll_test.dart)（7 例）：首帧即底部且稳定（内容不均/单轮）、
  **贴底连续增量 `pixels` 恒为 0 且不越界**、按住下滑不被拉回、上翻暂停/回落恢复、
  **离底阅读时流式新内容不推走已读内容**（参考部件位移 < 2px 且 `pixels` 补偿）、生成结束仍贴底。
  > 该「不推走」用例已验证**能失败**：临时关掉锚点后位移 225px、用例立刻红。
- [test/floor_jump_test.dart](../../test/floor_jump_test.dart)（20 例全绿，未改断言口径，只改脚手架的手势/判据：
  `chatBottomGap = pixels − minScrollExtent`、「滚到底部」向上拖）；
- [test/narr_chat_scrollbar_test.dart](../../test/narr_chat_scrollbar_test.dart)：新增 reverse 几何 2 例
  （`thumbTop` 镜像、`pointerOffset` 方向镜像）；
- [test/chat_round_version_test.dart](../../test/chat_round_version_test.dart)：夹具前提改为「不在底部 = `pixels > 50`」。

### 10.6 观感 / 行为保持
- 常驻 UI（AI 操作栏、时间线块、输入面板）一律未动；
- 手势语义与用户直觉一致：**向上拖动 = 更新内容（朝底部）、向下拖动 = 更旧内容**（与正向列表相同，D8）；
- 贴底观感不变：新正文把旧内容顶上去，最新一行停在输入面板上方；
- 滚动条：反向列表的拇指位置/拖动方向镜像，外观不变（`app_theme` 未动）。



