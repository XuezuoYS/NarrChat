# 对话页怎么渲染和滚动

> 这一页是应用里最复杂的界面：几百轮对话、流式生成、图片、可切换版本、分支。
> 本文说明**为什么这么设计**，以及改动时要小心什么。

## 一句话

列表只渲染"窗口"里的轮次；**第 N 轮在哪**由一个覆盖全书的几何模型算，不靠问滚动容器；
右侧那条轨道读同一个模型，所以拇指、进度、跳转三者永远说的是同一个数。

## 分层

```
数据    RoundProvider.rounds（活动链 + 分组）
  ↓
条目      ChatItem / ChatItemKey        一个气泡 = 一个条目（轮 uuid + 类型）
  ↓
几何      ChatGeometry                   全书条目高度前缀和（Fenwick）
  ↓
窗口      ChatWindowController           只决定"哪些轮参与渲染"
  ↓
定位      ChatViewportController         滚动 / 跟随 / 跳转 / 当前轮 / 进度 / 速度
  ↓
组件      ChatRail                       右侧轨道 + 面板
  ↓
页面      chat_screen                    把窗口切成行、回报实测高度、摆布局
```

对应文件：`lib/chat/chat_item.dart`、`chat_geometry.dart`、`chat_window.dart`、
`chat_viewport.dart`、`chat_locator.dart`、`chat_rail.dart`、`chat_rail_handle.dart`、
`chat_rail_motion.dart`、`chat_row.dart`、`chat_height_bucket.dart`。

## 为什么不用 `ScrollController.maxScrollExtent`

窗口化之后滚动容器里只有**一窗**内容，它的 extent 只反映这一窗，不是全书。
旧实现（真正的"滚动条跳舞"）就是因为拇指读这个值，每次窗口变化拇指都跳。
现在：拇指读几何模型，进度 = `(窗口基准 + pixels) / (全书总高 − 视口高)`。

同理，**不要拿 `maxScrollExtent` 的增量当"内容长了多少"**：它是懒加载估算值，
实测有一次增量为正、真实内容却在缩短（方向都是反的）。

## 坐标口径（改动时先看这一段）

消息列是 `reverse: true`：`pixels = 0` 是**列表最新一端**。设窗口对应几何下标 `[a..b]`：

```
base      = geometry.offsetOf(b)                        // 窗口最新端距书底（全书坐标）
bookOff   = base - leadingInset + pixels                // 视口底边在全书里的位置
progress  = bookOff / max(1, total - viewport)          // 0=贴底 1=顶部
fraction  = viewport / total                            // 轨道拇指长度；≥1 时轨道无意义
currentRound = geometry.roundIndexAtOffset(bookOff + viewport)   // 视口**顶部**那一轮
跳转落点   = geometry.topEdgeOf(index) - base + leadingInset - viewport
```

`leadingInset` 是"贴在最后一行底部的那段避让留白"（下面会讲为什么在那儿）。

**为什么跳转准**：`topEdgeOf` 和 `base` 用的是同一套几何，窗口外条目的估算误差在
相减时**互相抵消**；落点精度只取决于窗口内条目 —— 也就是真正被渲染、被测量的那些行。

## 几何覆盖全书，窗口只管渲染

- 几何按**整条活动链**重建（2000 轮 ≈ 4000 条目，Fenwick O(n) 建树、O(log n) 更新）；
- 窗口变化**不重建几何**，只换渲染行（`_computeWindowItems`）；
- 待定气泡（生成中的用户消息 / 流式插槽）也进几何：它们的高度不记账的话，
  生成期间列表本地坐标和全书坐标会多出一段未知量，跳转落点跟着偏。

## 高度从哪来

三层，优先级从低到高：

1. **估算**：`ChatGeometry.defaultEstimates`（user 96 / ai 320 / 分支头 88 / 错误 160），
   带图片的条目再加 `imageExtraHeight`；
2. **持久化**：`chat_heights` 表，主键是 `(book_uuid, item_key, width_bucket, type_scale_bucket)`
   —— **同档才复用**。列宽 16dp 一档、字号 5% 一档（`ChatHeightBucket`）；
3. **本会话实测**：行布局后由 `ChatRowMeasure`（渲染对象自己）帧末上报，覆盖上面两层。

只有**高度**进账本，**偏移**从不缓存：懒加载列表在范围估算变化后会把已构建子项整体
重排，历史偏移会失效（实测读到过 `-18288` 这种负数）。

写回是 800ms 防抖批量 upsert；`dispose` 时补一次 flush。删书要 `clearHeights`。

## 纵向留白为什么必须挂在"最后一行"上

两段留白，两套做法，都有硬理由：

| 留白 | 放在哪 | 为什么不能放 `ListView.padding` |
| --- | --- | --- |
| 顶部 24dp | `trailingSpacer` **条目**（进几何） | 放 padding 会被算进列表内容高度：跳到第 1 轮时永远差 24px（实测偏差 24 → 0） |
| 底部避开输入面板（面板高 + 8） | **最后一行**的底部内边距 | 放 padding 时它不在任何被测量的条目里，阅读锚点看不见它 —— 面板长高时**任何**滚动位置都整屏上移，位移恰好等于面板增高量（实测 92px） |

挂在最后一行之后：留白在 `ReadingAnchorItem` 的测量子树里，锚点的"贴底不补、离底补"
两条规则原样生效（离底阅读时面板长高不再推动已读内容，贴底时内容照旧被顶上去）。
`ChatRowMeasure` 包在 `Padding` **里面**，所以上报的只有内容高度，几何与持久化缓存
不会把这段留白算进去。

## 轨道的两条反直觉规则

1. **拇指不跟手**。拖动是**速度**输入，不是位置输入：手指位移 → 速度 → 内容真的在滚 →
   拇指跟着真实进度走。做成位置映射的话，手指一动拇指就得跳，而内容还没到 —— 拇指会撒谎。
2. **「底部」≠「最后一轮」**。底部是最大偏移；最后一轮可能只露出半屏。
   同理「第一轮的上一轮」= 顶部，「最后一轮的下一轮」= 底部。

速度模型：`Δ = clamp((originY − pointerY) / 视口高, ±1)`，死区 0.03，`s = sign(Δ)×|Δ|^1.3`，
`v = s × 1.6`（视口/秒）。松手立即停，无惯性。

## 跳转怎么保证准

1. 目标就近向下取整到"实际存在的轮"（轮号有断裂也能跳）；
2. 不在当前窗口 → 让页面围绕目标重建窗口（两侧各 15 轮）；
3. 按上面的公式算落点 `jumpTo`；
4. 帧末复核：每帧重算一次落点，最多 10 帧。**必须给够 4 帧才判稳定** ——
   懒加载列表跳到新位置后才逐帧把附近的行建出来并回填实测高度（估算常差几倍），
   目标下方条目的高度一变，落点就变；"落点被可滚动上限夹住"也算没定稿。
   用户一旦开始滚动就取消复核（`cancelPendingJump`）。

## 一次构建的顺序（`_buildChatArea`）

1. `chainChanged`：书或分支变了 → `_chatWindow.reset()` + 几何重建；
2. `roundsReady`：链不属于当前书（换书异步加载的首帧）→ 一层轮次都不建；
3. 失效判据（轮次引用/长度、警告、代次、生成中气泡、列宽）→ `_rebuildGeometry`；
4. `_syncChatRows()`：把几何切成这一窗的渲染行，并算出 `windowBase`；
5. 列表：`reverse: true` + 稳定 Key（`chat-item-${roundUuid}:${kind}`）+ `findChildIndexCallback`
   → 末尾追加时元素（连同折叠状态、选区）跟着搬家；
6. 每行包 `ChatRowMeasure`（上报高度）→ `ReadingAnchorItem`（阅读位置补偿）；
7. 轨道：只拿到 `ChatLocator`，数字全向它要。

## 踩过的坑（都留了回归用例）

1. **`visibleFraction` 写成反比**（`总高/视口`）：所有超过一屏的书都被 clamp 成 1.0，
   轨道于是**对所有正常书隐藏**，只有"几何空掉"的那本才会显示出来。
2. **窗口倒置**：链变短（换书 / 切分支）时旧实现只把 `lastRoundIndex` 夹回新总数，
   `firstRoundIndex` 不动 → `(91..10)` 这种窗口 → 一层轮次都查不到 → 整页空白。
   现在"装不下就按尾部重建"。
3. **换书首帧拿旧书轮次**：全局 provider 不随页面销毁，新页面首帧读到的可能还是上一本书的
   活动链。`loadRounds` 换书时先清链并通知，页面再用 `loadedBookUuid` 判一次。
4. **条目 Key 用轮号**：切分支后同轮号的元素被复用，会串上一分支的折叠/选中状态。
   现在一律用轮 uuid。
5. **精确边界上的"当前轮"**：视口顶正好落在某条目顶边时，`indexAt` 会给上方那一条；
   `roundIndexAtOffset` 补了这次边界修正。
6. **轨道命中带吃按钮**：轨道贴在聊天区右缘，内容区不居中时最右那枚方形按钮正好压在
   命中带里（触控端整个按钮右半都点不到）。面板按钮行按 `ChatRail.reservedFromRight` 让开。

## 明确没做的（想清楚再动）

- **内容分页**：`RoundRepository.loadChain` 仍一次带回整条活动链，这里的"窗口"是
  **渲染窗口**，不是数据窗口。接口已按规格留好，将来做数据分页时页面零改动。
- **窗口裁剪**：数据层本就全量在内存，裁剪只对未来的分页有价值。`ChatWindowController`
  只增不减（`maxRounds` 只在"新轮把窗口撑爆"时从远端收缩）。
- **分支「上次阅读位置」记忆**：切分支统一回底部。
- **阅读位置补偿的 API 位置**：规格里叫 `correctBy(Δ)`，实际由 `ReadingAnchor` /
  `ScrollLockAnchor`（`lib/widgets/reading_anchor.dart`）承担，已经有 7 条用例守着；
  不再在定位层另造一套。
- **键盘**：靠 `Scaffold` 的 `resizeToAvoidBottomInset` 把整个对话区压短（面板随之整体上移），
  不做额外的视口补偿 —— 规格 §8.8 要的正是"只挤组件"。
