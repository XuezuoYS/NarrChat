# 对话页（ChatScreen）UI 性能优化 — 结论与落地记录（2026-10-11 收官）

> **本轮优化于 2026-10-11 收官**，本文件不再更新。命名约定：**文件名带 `2026-10-11` 即本轮产物**
> （本文件用日期前缀；`.dart` 受 `file_names` lint 约束不能以数字/连字符开头，故探针把日期写在
> `_test` 之前）——`.agents/` 与 `.agents/perf/` 的其余命名空间留给后续 Agent 工作。
>
> **状态**：P0-①~④ 与两处跳转动效/可达性回归修复**全部落地**；`flutter analyze lib test .agents/perf`
> 干净、`flutter test` **1765 passed / 1 skipped**。
> **环境**：Flutter 3.47.5（framework 6a19cca56）/ Dart 3.13.4；目标平台 Windows + Android。
>
> **说明**：一次性证据探针（`reverse_anchor_probe` / `reading_drift_probe` /
> `streaming_block_probe` / `recommended_action_probe` / `markdown_build_probe`）已在本轮清理中删除，
> 数据留在本文件；保留 2 个可复跑探针（同属本轮，见 [perf/](perf)）：
> - [perf/chat_cost_probe_2026_10_11_test.dart](perf/chat_cost_probe_2026_10_11_test.dart)：落底越界 / 流式成本 / 容器计数 / 每帧耗时基线；
> - [perf/floor_jump_frame_probe_2026_10_11_test.dart](perf/floor_jump_frame_probe_2026_10_11_test.dart)：跳转首帧、到达帧、单帧成本。
>
> 复测：`flutter test .agents/perf/<上面两个文件>`（**单独运行**——与其它 `flutter test` 并发会污染比率；
> 绝对值只在 debug/Ahem 环境内可比，跨环境只比倍数 / 帧数 / px）。

## 1. 症状 → 根因 → 现状

| 症状 | 根因 | 现状 |
|---|---|---|
| 打开书到底部「往下多弹一段 + 卡顿」 | 正向列表 `jumpTo(估算 maxScrollExtent)` + 逐帧补滚：估算偏大 → 冲过头 → 回弹 | ✅ 越界帧 **0/80**、最大越界 **0.0px**、到位后**零补滚**（P0-③） |
| 生成时卡顿 | 每个流式增量重建整页；单气泡内多份 `MarkdownBody`/`SelectionArea` | ✅ 按块增量（末批 **7.4x**）+ 单气泡 `MarkdownBody` 6→**1** + 每气泡选中区域 2→**0** |
| 滚动条乱动 | 反向列表下自绘滚动条几何未镜像 | ✅ 拇指位置 / 拖动方向按 `axisDirection` 镜像（P0-③） |
| 分页跳转「先无动画落到窗口底部再滚上去」 | 模型量（条目顶边坐标，视口顶为参照）被当 `pixels`（视口底边）：整体差**一个视口高** | ✅ 均匀书首帧 838px → **−26 / +2px**（§12） |
| 远端 / 过早 / 未加载轮次跳转到不了目标 | ① 一次 `jumpTo` 越界 → 框架单帧逐条构建几百条目（**1043ms/帧**）；② `layoutOffset` 缺前导 padding(183px) + 历史偏移失效 → 模型算出负数；③ `getOffsetToReveal` 差 183px、`animateTo` 目标值失真 | ✅ 冷跳远端 **5/5 到达**、最大单帧 **67ms**、落点 9px（§13） |

## 2. 落地清单

### P0-① 流式正文按块增量渲染
- 改动：[lib/utils/streaming_markdown_blocks.dart](../lib/utils/streaming_markdown_blocks.dart)（新，纯函数无损切分）、
  [lib/widgets/streaming_markdown.dart](../lib/widgets/streaming_markdown.dart)（新，冻结块 widget 复用 + 单一 `SelectionArea`）、
  [chat_screen.dart](../lib/screens/chat_screen.dart)（`_narrativeText` 接线）、[markdown_preview.dart](../lib/widgets/markdown_preview.dart)（抽出 `blockSpacing`）。
- 机制：每帧只解析「已由空行封闭的块」并缓存 widget 实例 → 父级重建时同一实例被同一性短路跳过（该子树不 rebuild / 不重解析 / 不重排），只有尾部残块随增量重建。
- 切分安全边界：只在空行处切，且空行**上一行必须自成一块**；列表项 / 引用 / 表格行 / 前导空白续行之后不切；段内单换行绝不切；围栏代码块与可跨空行原始 HTML 块内不切；链接 / 脚注引用定义之后停止切分。
- 实测（8 字 × 1000 次增量）：空行分段合计 **19.7s → 3.1s（6.3x）**、末批 **36.1 → 4.6–4.9ms（7.4x）**；无空行单段 **1.00x（无回归，刻意不切）**。
  端到端（60 轮底稿 + 8332 字）：已冻结块 **166**、每帧真正重建的尾部残块 **33 字**。
- 测试：`streaming_markdown_blocks_test`（11）、`streaming_markdown_test`（9）、`chat_stream_rebuild_scope_test`（生产接线）。

### P0-② 推荐行动改为一次解析
- 改动：[recommended_action_view.dart](../lib/widgets/recommended_action_view.dart)（选项改 `Text.rich(MarkdownPreview.buildInlineSpans(...))`）；
  [markdown_preview.dart](../lib/widgets/markdown_preview.dart)（公开 `buildInlineSpans`，两处内联渲染收敛为 `_nodesToSpans`）。
- 实测：单气泡 `MarkdownBody` **6 → 1**；「从零构建一个旧气泡（正文 + 5 选项）」**4.11 → 2.18ms（1.88x）**。
- 测试：`recommended_action_view_test`（+4，含「单气泡构树次数 ≤ 2」验收）；交互沿用既有用例。
- 已知微差：选项行内 `` `code` `` 由圆角容器改为内联底色（与 GitHub Alerts 内部一致）。

### P0-③ 底部锚定 `reverse: true`
- 改动：[chat_screen.dart](../lib/screens/chat_screen.dart)（列表反向 + 逻辑序号反转 + 条目身份 Key + `findChildIndexCallback` + 删除补滚链路 + 偏移模型反号 + 接入阅读锚点）、
  [narr_chat_scrollbar.dart](../lib/widgets/narr_chat_scrollbar.dart)（`ScrollThumbGeometry` 增 `axisDirection`，反向镜像拇指与拖动方向）、
  [reading_anchor.dart](../lib/widgets/reading_anchor.dart)（新：离底阅读位置补偿）。
- 实测：越界帧 45/80 → **0/80**；最大越界 390.7 → **0.0px**；收敛 1306ms / 68 帧 → 动画结束即稳定（到达后零变动）；
  离底阅读漂移（参考部件位移）−150px+ → **0.0px**（等价 `pixels` 补偿 +600）；同场景「气泡还很矮且被移出 cache 区」不误补偿。
- 合成宿主语义（原 reverse 探针结论，已归档）：贴底追加条目 `pixels` 恒 0（「新内容顶上去」保留）；离底时追加 / 长高会推走可视内容；视口**上方**长高不推；手势方向与正向列表一致（手指向下 = 揭示更旧内容）。
- 测试：`reading_anchor_test`（11）、`chat_auto_scroll_test`（7，含「离底阅读不推走已读内容」）、`narr_chat_scrollbar_test`（+2 几何）、`chat_round_version_test`（夹具口径）、`floor_jump_test` 全绿。

### P0-④ `SelectionArea` 收敛为「列表外一个」
- 改动：[markdown_preview.dart](../lib/widgets/markdown_preview.dart)（`SelectableTextArea` 作用域感知 + 新增 `SelectableTextScope`）、
  [chat_screen.dart](../lib/screens/chat_screen.dart)（消息列外包作用域；窄屏把抽屉横滑识别器移进列表内部）、
  [failed_attempt_bubble.dart](../lib/widgets/failed_attempt_bubble.dart)（失败原因 `SelectableText` → `PlainTextPreview`，去掉选区硬边界）。
- 实测：每气泡区域 **2 → 0**、整页 **1**；平台文本处理查询 **15 → 1**（滚动/新增气泡不再各付一次）；逐帧成本无变化（2.65 vs 2.85ms/帧）
  → 证明**残余成本来自「屏幕上 N 个文本块」，不是选中容器数量**。
- 顺带修掉设计缺陷：两个 `SelectableRegion` 互为硬边界，此前**无法跨气泡连续选中**，现在可以（且右/长按菜单仍被抑制，气泡自定义菜单不受影响）。
- 测试：`selectable_text_scope_test`（6，含跨子项拖动 A/B）、`chat_selection_scope_test`（4，含跨气泡复制与窄屏横向拖选）、`test/helpers/selection_harness.dart`（新脚手架）。

### §12 定点跳转动效回归修复（P0-③ 引入）
- 根因：`reverse: true` 下 `pixels` 是**视口底边**坐标，而偏移模型量以**视口顶边**为参照 → 粗定位整体偏大一个视口高（实测 844px = 1.0 屏）。
- 改动：新增 `_revealScrollOffset`（减 `viewportDimension`）供粗定位；目标未构建时退回「顶边贴视口底边」落点逐帧推进
  （只做换算修正收敛 **2/5** → 加回退落点 **5/5**）。
- 实测：均匀书首帧 838 → **−26 / −12 / +2px**；混合长书冷跳第 119 轮 839 → **−5px**。
- 测试：`floor_jump_test` +2（首帧落点差 < 0.3 屏；长书不出现「气泡先停窗口底部再滚上去」，旧行为 11 帧）。
- 注：本项的模型 / 落点策略在 §13 中被更彻底的方案取代，保留 `_revealScrollOffset` 换算语义。

### §13 远端 / 过早 / 未加载轮次跳转修复
- 三层根因见 §1 末行。改动（全在 [chat_screen.dart](../lib/screens/chat_screen.dart)）：
  `_liveChatItems`（当帧从渲染树读已构建条目的**绘制**偏移 / 高度）、`_modeledItemOffset`（锚点改用当帧已构建条目）、
  `_stepJumpTowardItem`（方向 = 已构建条目序号区间；步长夹在 `[0.5 视口, 8 × 局部条目高]`）、
  `_alignedOffsetForTarget`（量目标在视口内的 y，`pixels − y`）+ 3 帧复查、`_cancelFloorJump`（用户接管即取消跳转）、
  `_FloorMeasuredItem` 只上报高度；`_kFloorJumpMaxRefine` 10 → 120。
- 实测（混合长书 120 轮冷跳，视口 844px）：

  | 目标轮 | 旧实现 | 新实现（到达帧 / 最大单帧） |
  |---|---|---|
  | 1 / 2 / 5（最远） | 到不了 | **27 / 26 / 26 帧**、67 / 61 / 57ms |
  | 30 / 60 / 90 | **40 帧后仍未构建** | **19 / 12 / 5 帧**、59 / 40 / 50ms |
  | 119 / 120 | 839px + 20 帧爬升 | **1 帧**、1ms |

  冷跳 5 个目标 3/5 → **5/5** 到达；同页连跳 4/5 → **5/5**；最大单帧 **1043ms → 67ms**。
- 测试：`floor_jump_test` +1（冷跳第 30 轮 40 帧内到达，且「目标可见却离视口顶 > 0.3 屏」的帧 ≤ 1）。

## 3. 验收标准对照

| 标准 | 结果 |
|---|---|
| 落底越界帧 = 0、稳定帧 ≤ 5 | ✅ 0/80、最大 0.0px、动画结束后零变动 |
| 流式 8000 字 ≤ 800 字的 1.5 倍 | ⚠️ 部分：空行分段 3.0–3.2x（斜率降到 1/8、末批便宜 7.4x）；单段无空行 1.00x。残余是**平台级遍历成本**（P1） |
| 单气泡 `MarkdownBody` ≤ 2 | ✅ 1 |
| 滚动 30 帧 ≤ 基线（2.5–3.1ms/帧） | ✅ 2.85（P0-③ 后）/ 2.65（P0-④ 后） |
| 选中容器整列 1 个 + 跨气泡可选中 | ✅ 每气泡 0、整页 1；跨气泡复制 / 窄屏横向拖选均有 A/B 用例 |
| `flutter test` 全绿 | ✅ 1765 passed / 1 skipped |

## 4. 回归面（要点）

- **reverse 列表**：自绘滚动条方向、楼层跳转坐标、抽屉横滑、`offset ≈ max` 语义 → `narr_chat_scrollbar_test` / `floor_jump_test` / `chat_auto_scroll_test` / `chat_round_version_test`。
- **离底阅读补偿**：与拖拽 / 惯性冲突、贴底语义被破坏、误补偿 → `reading_anchor_test` + `chat_auto_scroll_test`。
- **流式按块渲染**：未闭合围栏、光标位置、结尾排版 → `markdown_preview_test` + `streaming_markdown*`。
- **选中收敛**：跨气泡、气泡长按 / 右键菜单、拖选自动滚动、抽屉左滑 → `chat_selection_scope_test` / `selectable_text_scope_test` / `chat_bubble_test` / `sidebar_toc_test` / `chat_delete_generation_test`·`chat_raw_entry_test`·`chat_modify_opinion_test`。
- **跳转**：`floor_jump_test`（23 例，含首帧落点、远端到达、拖动不被复查链抢回）。

## 5. 机制备忘（避免重复踩坑）

1. **反向列表坐标**：`pixels` 是视口**底边**坐标；条目顶边偏移 = `pixels + viewportDimension − 视口内 y`；「对齐视口顶」的偏移 = 顶边偏移 − `viewportDimension`。
   `getOffsetToReveal(…, 1.0)` 在该视口要经 growth direction / pinned sliver 多层换算，**实测与真实位置差 183px**（846 vs 663）→ 对齐请直接量目标在视口内的 y。
2. **懒加载 extent 是估算值**（按当前构建窗口外推）：跨区域后坐标会重排，**任何跨帧缓存的绝对偏移都会失效**（实测出现负值）；
   子项 `parentData.layoutOffset` 还是 sliver **内部**坐标，不含 `ListView` 前导 padding（reverse 下 = 输入面板高 + 8，实测 183px）。
3. **一次 `jumpTo` 越出已构建窗口 = 框架在该帧逐条构建途经条目**：远端跳转必须限步分帧（本项目 8 条/帧，单帧 ≤ 67ms）。
4. **`SelectableRegion` 互为硬边界**：每气泡一个区域就无法跨气泡选中；`SelectableText` 是独立的 `EditableText` 选区系统，同样是边界。
5. **度量口径**：绝对值只在 `flutter test`（debug/Ahem）内可比，跨环境只比倍数 / 帧数 / px；`maxScrollExtent` 增量**不能**当内容增长量（估算值，可差数十倍）。

## 6. 已知取舍（刻意保守）

- 流式：无空行单段正文不切块；跨空行自定义块内部不切；链接 / 脚注引用定义之后不切（宁可少冻结也不改观感）。
- 离底阅读补偿：**末尾条目易主**（追加 / 删除轮次、流式落库）时不补偿（避免凭空跳一段），代价是那一刻可能几十~百 px 位移；底部留白变化不补偿；视口上方长高不补偿。
- 跳转：远端是**多帧快速滚动**而非一帧到位（懒加载语义决定，无 API 可绕）；`_kFloorJumpMaxRefine = 120` 是帧数上限，极端长书（>900 条）最远端可能停在沿途位置（不会停在列表底部）；「当前轮」判据要求对齐精确到 <1px，故不做「偏差小就跳过」的优化。
- 常驻 UI 观感一律未动（气泡 / 操作栏 / 时间线 / 输入面板 / 滚动条 / 选中语义）。

## 7. 遗留（未做，供后续取用）

- **P1**：流式通知合帧节流；时间线子块 widget 复用；底部留白不再依赖帧末测量（`_composerHeight`）；楼层跳转模型 O(n·m) → 有序结构 + 测量表 LRU；「屏幕上 N 个文本块」的逐帧残余成本（需换渲染结构）。
- **L0 剩余**：Windows `--profile` 真机 timeline（需 DevTools 或 `integration_test` + `traceAction`，要加 dev 依赖并跑桌面构建）；可选 `--dart-define=NARRCHAT_PERF_LOG` 埋点（itemBuilder / 构树 / `jumpTo` 次数，默认关闭）。
- **待人工复验（桌面）**：跨气泡拖选复制、反向列表观感、气泡右键菜单、失败原因文本与长代码块排版。
- **长期技术债**：`flutter_markdown` 已 discontinued；`_kBlockTags` 无界增长（实测 2 万条累积无耗时上升趋势，仅留数量级哨兵）；自研 Markdown 渲染内核（最彻底，工作量大）。
