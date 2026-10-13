# 记忆条目长按/右键菜单 — 落地记录（2026-10-13）

> **本轮针对 chat 页侧栏「记忆总结」的条目卡片**：长按（触屏）/ 右键（桌面）弹出扩展菜单。
> 命名约定：文件名带 `2026-10-13` 即本轮产物。
>
> **状态**：全部落地。见文末「验证结论」。
> **环境**：Flutter 3.47.5 / Dart 3.13.4；目标平台 Windows + Android。

## 1. 需求与口径（已与用户确认）

| 需求 | 口径 |
|---|---|
| 长按 / 右键条目卡片弹菜单 | 触屏长按 500ms、桌面右键立刻；滑动超阈值取消（复用 `BubblePointerListener`，与气泡同一套手势） |
| 菜单弹出位置 | **跟随指针**：桌面右键在鼠标处、触屏长按在手指处（右键菜单的一贯预期；`showMenu` 自己做屏幕边缘钳制） |
| 菜单三项 | 复制时间 / 复制内容 / 跳转至对应条目 |
| 复制时间 | **原样复制条目时间段的原文**：合并条目的时间本来就是区间文本（`时间1 ~ 时间2`），无需另拼；时间缺失时复制卡片上显示的「（未标注时间）」 |
| 复制内容 | 复制条目概括（第 3 段） |
| 跳转至对应条目 | 滚动**对话区**到该轮用户气泡起点（复用楼层跳转 `_jumpToItem`），侧栏查看的轮次不变 |
| 合并条目跳转 | 落到**合并区间的起始条目**（区间小端，`11~15` → 第 11 轮；降序 `15~11` 同样归一为小端） |
| 目标轮不存在 | 按「向下就近取整」落到其前一轮（与楼层跳转 `_resolveFloorTarget` 同语义）；连前一轮都没有才给悬浮提示，不做无声失败 |
| 窄屏抽屉 | 跳转时顺带收起抽屉（否则跳过去也被抽屉盖住） |

## 2. 改动清单

| 文件 | 改动 |
|---|---|
| [lib/utils/memory_entry_format.dart](../lib/utils/memory_entry_format.dart) | 新增菜单文案常量 `kMemoryEntryCopyTimeLabel` / `kMemoryEntryCopyContentLabel` / `kMemoryEntryJumpLabel` 与 `memoryEntryTimeText()`（复制时间的唯一真源，UI 与测试共用） |
| [lib/widgets/memory_summary_editor.dart](../lib/widgets/memory_summary_editor.dart) | 条目卡片挂 `BubblePointerListener` + `InkWell`（悬停/按压反馈、长按无障碍语义）；新增 `onJumpToRound`；`_showEntryMenu` / `_copy`；`_entryCard` 拆为 `_card`（纯外观）+ `_entryCardShell`（交互）+ `_entryContent`（纯内容） |
| [lib/widgets/sidebar_panel.dart](../lib/widgets/sidebar_panel.dart) | 新增 `onJumpToRound` 字段并透传给 `MemorySummaryEditor` |
| [lib/screens/chat_screen.dart](../lib/screens/chat_screen.dart) | 新增 `_jumpToMemoryEntry(roundIndex, entryTopLeft)`；`_buildSidebar` 接线 |
| [test/memory_entry_menu_test.dart](../test/memory_entry_menu_test.dart) | 隔离层 13 例：长按/右键弹菜单、三项文案、**菜单跟随指针（右键处 / 长按处，换位置跟着走）**、复制时间/内容落剪贴板、空时间、合并条目区间、旧格式条目、跳转回调轮次与指针坐标（含合并取起始轮）、区块滚出视口后仍在指针处、未接线时不挂菜单 |
| [test/chat_memory_entry_jump_test.dart](../test/chat_memory_entry_jump_test.dart) | 对话页集成 4 例：条目跳转真的把对话区滚到该轮起点、先看历史轮次再跳、轮次缺失时向下就近取整、窄屏抽屉跳转并自动收起 |

## 3. 设计要点（为什么这样做）

- **菜单项文案放在 `memory_entry_format.dart`**：那里已是「记忆条目格式的单一真源」，测试直接引用同一常量断言，改文案不会让用例假绿。
- **手势复用 `BubblePointerListener`**：气泡右键/长按已用它，自带「右键立即触发 + 触屏 500ms + 滑动 18px 取消」，条目卡片不必另写一套手势。
- **菜单锚点 = 指针全局坐标**（`BubblePointerListener` 回调直接给的 `event.position`）：桌面右键在鼠标处弹出，触屏在手指处弹出；`showMenu` 自带屏幕边缘钳制，指针贴近屏幕边缘时菜单会自动内收。长按与右键都走这一条路，**不叠加** `InkWell.onLongPress`（它只能拿到控件原点、无法跟随指针，还会与 `BubblePointerListener` 的长按判定重复触发）。
- **交互与内容拆分**：`onJumpToRound == null` 时卡片完全不挂交互层（复制两项也一并隐藏）——没有跳转落点的一方不必伪装可跳转。当前唯一使用方（侧栏）已接线。
- **跳转复用楼层跳转**：`_jumpToItem(2 × 轮次位置)` 自带「分帧推进 + 精确对齐视口顶」，因此跳转后的「当前轮」判定与楼层跳转一致，无需新写滚动逻辑。
- **`entryTopLeft` 参数**：菜单回调契约里带上被操作卡片左上角的全局坐标（菜单也按它定位）。当前定位只用轮次，保留该信息以便后续按「同屏对齐卡片」细化落点。

## 4. 验证结论

- `flutter analyze`（全项目）：无 issue。
- `flutter test`（全量）：**1802 passed / 1 skipped**（本轮新增 17 例：隔离层 13 + 集成 4）。
- 独立验证（task-1，两轮）：
  1. 首轮发现**真实缺陷**——菜单锚点原先取「组件」/「卡片」原点而非指针，侧栏一滚动菜单就被钳到屏幕上沿、且桌面右键不跟随鼠标；已改为**指针坐标**（用户要求「右键菜单展开位置跟随鼠标」），并补用例：菜单在鼠标处弹出、换位置菜单跟着走、长按在手指处、老格式/合并条目不受影响。
  2. 复审结论「通过（可交）」；它指出的 3 处文档不实施（死引用、旧描述、18px/20px 阈值）已修正。
- 真机（Windows / Android）手测仍未做：长按手感、剪贴板真实写入、菜单视觉位置、`InkWell` 悬停反馈。

## 5. 有意不做的事

- 不新增「复制整行原始文本」入口（复制时间 + 复制内容已覆盖；原始文本可在编辑模式取）。
- 不在条目卡片上加常驻菜单按钮（长按/右键已足够，避免侧栏视觉噪音）。
- 不改动 `release.yaml` / `update_log.md`（按仓库约定需显式许可）。
