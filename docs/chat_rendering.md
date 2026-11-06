# 对话页怎么渲染和滚动

> 这一页是应用里最复杂的界面：几百轮对话、流式生成、图片、可切换版本、分支。
> 本文说明**为什么这么设计**，以及改动时要小心什么。

## 一句话

列表只渲染"窗口"里的轮次；**第 N 轮在哪**由一个几何模型算，不靠问滚动容器；
右侧那条轨道读同一个几何模型，所以拇指、进度、跳转三者永远说的是同一个数。

## 分层

```
数据      RoundProvider.rounds（活动链 + 分组）
  ↓
条目      ChatItem / ChatItemKey        一个气泡 = 一个条目（轮 uuid + 类型）
  ↓
几何      ChatGeometry                   条目高度前缀和（Fenwick）
  ↓
窗口      ChatWindowController           只加载/渲染窗口内的轮次
  ↓
定位      ChatViewportController         跳转 / 速度滚动 / 当前轮 / 进度
  ↓
组件      ChatRail                       右侧轨道 + 面板
```

对应文件：`lib/chat/chat_item.dart`、`chat_geometry.dart`、`chat_window.dart`、
`chat_viewport.dart`、`chat_locator.dart`、`chat_rail.dart`、`chat_rail_motion.dart`、
`chat_height_bucket.dart`。

## 为什么不用 `ScrollController.animateTo` + `maxScrollExtent`

窗口化之后，滚动容器里只有**一窗**内容，它的 `maxScrollExtent` 只反映这一窗，
不是全书。旧实现（真实的"滚动条跳舞"）就是因为拇指读这个值，每次窗口变化拇指都跳。

现在：跳转偏移 = `geometry.offsetOf(index) + heightOf(index)`（目标条目顶边贴视口顶），
进度 = `geometry.progressAt(pixels, 视口高)`。

## 高度从哪来

三层，优先级从低到高：

1. **估算**：`ChatGeometry.defaultEstimates`（user 96 / ai 320 / 分支头 88 / 错误 160），
   带图片的条目再加 `imageExtraHeight`；
2. **持久化**：`chat_heights` 表，主键是 `(book_uuid, item_key, width_bucket, type_scale_bucket)`
   —— **同档才复用**。列宽 8dp 一档、字号 5% 一档（`ChatHeightBucket`）。
   不分档的话换字号或改窗口宽度后高度全错，首屏会跳。
3. **本会话实测**：条目布局后 `_onItemMeasured` 上报，覆盖上面两层。

写回是 800ms 防抖批量 upsert；`dispose` 时补一次 flush。
删书要 `clearHeights` —— 否则 uuid 被复用会读到上一本的高度。

## 窗口

- 首屏最近 30 轮，不足两屏继续往前扩（保底 10 轮）；
- 距窗口顶不到 1.5 视口 → 向前扩 20 轮；
- **只扩不裁**：滚动不重建窗口（重建会让已读内容闪一下，还断跨轮复制）；
- 跳转到远处才在目标附近重建窗口；
- 上限、裁剪、占位条目见 `.agents/2026-11-06_chat_rail_spec.md` §5（该文件是施工期规格，
  `docs/` 里这份是可交付的版本）。

## 轨道的两条反直觉规则

1. **拇指不跟手**。拖动是**速度**输入，不是位置输入：手指位移 → 速度 → 内容真的在滚 →
   拇指跟着真实进度走。做成位置映射的话，手指一动拇指就得跳，而内容还没到 —— 拇指会撒谎。
2. **「底部」≠「最后一轮」**。底部是最大偏移；最后一轮可能只露出半屏。
   同理「第一轮的上一轮」= 顶部，「最后一轮的下一轮」= 底部。

速度模型：`Δ = clamp((originY − pointerY) / 视口高, ±1)`，死区 0.03，`s = sign(Δ)×|Δ|^1.3`，
`v = s × 1.6`（视口/秒）。松手立即停，无惯性。

## 一个反复踩的坑：链首/末位的额外条目

底部留白、顶部留白、分支头卡片都是**额外条目**，它们让"逻辑下标"与"第几轮"不再一一对应。
历史上这一处出过两次 bug：

1. `ReadingAnchorItem(active: 逻辑最后一条)` —— 插了底部留白后，锚点落到了留白上，
   于是"离底阅读时新内容推走已读内容"（补偿完全失效，偏差正好等于流式增长量）；
2. 侧栏跳转与顶部留白 —— 旧的分帧跳转引擎假设"逻辑 0 就是气泡"，插了顶部条目后整体错位。

**结论**：任何链首/链末条目都必须走统一的头/尾计数（`_chatHeadCount`），
并且锚点判据要用"最后一条**非占位**条目"。

## 已知的债（交接时明确留给后人）

- 侧栏「跳转至对应条目」仍走旧的**分帧逼近**引擎（`_jumpToItem` /
  `_stepJumpTowardItem` / `_alignedOffsetForTarget` 等）。原因是它要跳到**从未被布局过**的条目：
  几何那时只有估算值，按几何跳会落在远不够远的位置，目标进不了渲染树，永远测不到真高。
  有了高度持久化之后，"读过的书"可以走几何落点，但**新书首读**仍需这个兜底。
  下一步做法：`geometry.isMeasured(index)` 命中 → 几何跳；否则 → 分帧逼近（混合，而不是二选一）。
- 底部/顶部**占位条目**尚未启用（`ChatItemKind.leadingSpacer` / `trailingSpacer` 与
  `ChatItem.fixedHeight` 已就绪并有测试）。现在仍用 `ListView.padding` 表达输入框留白 ——
  在"窗口恒含末轮"的前提下是对的；一旦启用了窗口裁剪（>200 轮且离得很远），
  那截 padding 会变成列表中间的空白，届时必须换成占位条目。
- `_itemHeights` / `_FloorMeasuredItem` 仍是测量来源，与持久化高度是两件事：
  先读持久化 → 用本会话实测覆盖 → 合并后喂几何。
