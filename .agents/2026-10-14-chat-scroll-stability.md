# chat 页滚动稳定性研究：超长用户气泡收起后定位混乱（2026-10-14）

## 问题现象

- 过长的用户气泡展开后再收起，视图定位混乱，直接跳到列表最顶部；
- 此后楼层跳转（悬浮条 / 记忆条目跳转）落点也随之错乱。

## 现状机制（相关代码）

- `lib/widgets/collapsible_content.dart`：`RenderCollapsibleContent` 布局期裁切，
  可预读 `naturalHeight` / `collapsedHeight`。
- `lib/widgets/chat_bubble.dart` `_UserBubbleBodyState._toggleExpanded`：
  「预补偿（setState 同帧 `jumpTo(pixels ± Δ)`）+ 帧末校正（按气泡顶边位置差再修）」
  两步锁定**气泡顶边**视觉位置；只在气泡与视口有交集时锁定。
- `lib/screens/chat_screen.dart` 楼层跳转：`_FloorMeasuredItem` 仅在
  `initState` / `didUpdateWidget` 帧末上报条目高度进 `_itemHeights`；
  `_estimateItemOffset` / `_modeledItemOffset` / `_avgItemHeightFor`
  用该缓存 + 分类型均值估算未构建条目的偏移。
- 列表为 `ListView.builder(reverse: true)`，懒加载、extent 为估算值；
  `ReadingAnchorScrollPhysics` 负责流式增长补偿（只盯逻辑末尾条目，与本问题无关）。

## 根因分析

### 根因 1：收起锁定对「超长气泡」失效（跳到底 / 顶）

`_toggleExpanded` 的锁定语义是「**气泡顶边**不动」，对超长气泡不成立：

- 展开态的「收起」按钮在气泡**底部**。用户点收起时，气泡顶边远在视口上方
  （`top` 为几千 px 的大负数），锁顶边意味着视图要整体移动 Δ（= 自然高 − 收起高，
  可达数千 px）。
- 预补偿 `pixels - Δ`：Δ 超过当前 `pixels` 时被 clamp 到 `minScrollExtent = 0`
  （reverse 列表的底部）→ 视图直接跳到底部。
- 若用户本来就在较高楼层（`pixels` 接近旧 `maxScrollExtent`），收起使总 extent
  骤缩数千 px，框架把 `pixels` clamp 到新 `maxScrollExtent`（= 列表**最顶部**）
  → 「直接上翻到最顶部」。帧末校正拿帧前的陈旧 `top` 算 `top - current`
  且无幅度上限，把错误进一步固化。
- 深层原因：补偿建立在对懒加载列表 extent 的预测上，而 extent 是估算值，
  Δ 越大预测越不可信；「预补偿 + 无界帧末校正」没有任何失败兜底。

### 根因 2：楼层跳转的高度账本被污染（跳转错乱）

展开 / 收起的 `setState` 发生在 `UserBubbleBody` **内部**，itemBuilder 不重跑，
`_FloorMeasuredItem.didUpdateWidget` 不触发 → 高度变化**不上报**：

- 气泡展开后 `_itemHeights[i]` 仍记着收起高度（几百 px 差变几千 px 差）；
  若展开状态下条目被回收重建，又会把展开高度记进缓存并在收起后保留。
- `_avgItemHeightFor` 的均值被超大值拉爆，`_estimateItemOffset` /
  `_modeledItemOffset` 对目标楼层的偏移估算偏差可达数千 px，
  分帧校准在错误模型上收敛不到正确落点 → 楼层跳转混乱。

### 次要风险

- `_scrollPosition` 在 `didChangeDependencies` 缓存一次，列表 Scrollable 重建后
  可能指向失效的 position（补偿作用在错误对象上）。

## 优化方向与实施（方向一，已落地）

### 1. 展开锁顶部、收起锁底部（定稿约定）

- **展开**：以气泡**顶部**为锚点固定不动 —— 补 Δ（= 正文自然高度 − 裁切阈值）让内容
  朝下方铺开，读者从消息开头往下读；顶边是否在视口内都一样锁它。
- **收起**：以气泡**底部**为锚点固定不动 —— 底边锚定本来就是 `reverse` 列表的天然
  行为，**一个偏移都不用补**：控件停在指尖 / 光标下，正文朝下收拢。
  （`suppressAnchorGrowth` 只用于压掉阅读锚定的重复补偿。）

为什么这样分：展开是「我要看全文」，锚在开头最自然；收起是「把它收起来」，手指 /
光标就在底部控件上，锚在底边最稳。而且**收起完全不动偏移**，从结构上就不可能再把
视图甩到任何一端 —— 「收起跳到全页顶部」这类问题不再存在。

- 补偿仍由 `ScrollLockAnchor` + `ReadingAnchorScrollPhysics` 在**同一帧布局阶段**
  落地（新范围已知、修正走视口重排重试循环，无漂移帧）；不在气泡里 `jumpTo`
  （旧范围夹紧会吃掉补偿），也不做帧末再校正（那会在点击之后移动内容、吞掉点击）。

### 1b. 展开 / 收起控件改成「不依赖手势竞技场」的点击识别

线上「展开按钮点一下没反应、点几下才行」的机制已用探针复现：消息列是可滚动列表，
而**鼠标指针的拖动判定阈值只有 1px**（`kPrecisePointerHitSlop`）——按住鼠标时手抖
2~3px 就被判成「拖动滚动」，`InkWell.onTap` 直接被取消。
改为 `Listener` 自己认「按下 → 抬起、位移 ≤ 18px」：位移内即触发切换，超过则交回
列表滚动（不误伤拖动）；`InkWell` 只留水波纹（`onTap` 置空，避免同一次点击触发两次）。

### 2. 高度上报与 itemBuilder 解耦

`_FloorMeasuredItem` 从 StatefulWidget（`initState` / `didUpdateWidget` 上报）
改为 `SingleChildRenderObjectWidget`，在 `performLayout` 里发现自身高度变化即
帧末上报。条目**内部**的状态变化（气泡展开 / 收起、代次控件显隐、流式正文增长）
都能入账，不再需要 itemBuilder 重跑。0 高不入账（避免刚插入的条目拉偏均值）。

### 3. 测试

- `test/reading_anchor_test.dart`：`ScrollLockAnchor` 的补偿在布局阶段生效并清零、
  贴底也补、**用新范围夹取**、零偏移 + 压掉锚定增长时位置完全不动（且只作用于
  这一次布局）、与阅读锚定的增长各自相加、极小请求忽略；`applyTo` 传递锁定锚。
- `test/chat_user_bubble_collapse_test.dart`：
  - **展开锁顶部、收起锁底部**：展开后顶边不动、控件随底边下移 Δ、偏移 +Δ；
    收起后底边与控件不动、偏移一动不动、顶边下移 Δ（一帧即到位 = 无动画）；
  - **顶边已在视口上方时展开**：照样锁顶部（顶边在视口外也不动）；
  - 贴底展开末尾条目（阅读锚定贴底不补）顶部不动、补偿恰好一倍；
  - **超长气泡（Δ 数千 px）**：顶边可见时展开补偿完整；读到尾部再收起时偏移
    一动不动，控件与其它内容原地不动；
  - **鼠标点击带 2~4px 位移也要触发切换**（回归「点一下没反应」），以及位移 60px
    的滚动拖动**不**触发切换。
- `test/floor_jump_test.dart`：超长用户气泡展开成全文后，跳转到它**上方**的轮次
  仍精确对齐视口顶（该估算必须用到展开后的新高度）。

回归有效性均已实测：
- 把「收起也锁顶边」的旧行为临时放回去 → 两条「收起」用例立刻失败
  （偏移 197 → 0 的整屏位移）；
- 用旧的 `InkWell.onTap` 点击路径时，鼠标带 3px 位移的点击不触发切换（探针实测）。

### 方向二（暂缓）：重构 chat 页

正向列表 + 自维护偏移模型 / 分页加载等方案成本高、风险大；
现有 reverse + 阅读锚定 + 分帧楼层跳转体系已经过多轮实战修复
（见 566cce7 / acb36a0 等提交），重构会推翻这些沉淀。
两个根因都属局部机制缺陷，方向一已用较小修改面解决，暂不评估重构。

## 结论

- 锚点约定：**展开锁气泡顶部**（补 +Δ，内容向下铺开）、**收起锁气泡底部**
  （底边锚定是列表天然行为，不补偏移）。收起不动偏移 → 结构上不可能甩屏。
- 补偿由 `ScrollLockAnchor` + `ReadingAnchorScrollPhysics` 在**布局阶段**用**新**范围
  落地；不做帧末再校正；末尾条目（阅读锚定对象）按需压掉重复补偿。
- 楼层跳转混乱：`_FloorMeasuredItem` 改为渲染对象自上报高度。
- 点击没反应：展开 / 收起控件改用 `Listener` 自行判定「按下 → 抬起」（鼠标拖动阈值
  只有 1px，`InkWell.onTap` 会被滚动拖动抢掉）。
- 涉及文件：`lib/widgets/chat_bubble.dart`、`lib/widgets/reading_anchor.dart`、
  `lib/screens/chat_screen.dart`（另加 `flutter/rendering.dart` 的 `RenderProxyBox` 导入）。
- 已知边界：短到无法滚动的对话里偏移夹在 0，气泡按列表天然方向生长，属预期。
