# 应用内通知：悬浮渠道 + 驻场岛

> 代码入口：`lib/widgets/app_notice_overlay.dart`（宿主 + `context.notices` 作用域）、
> `lib/services/app_notice_center.dart`（悬浮渠道状态中心）、
> `lib/widgets/floating_notice_host.dart`（悬浮渠道渲染）、
> `lib/widgets/pinned_notice_island.dart`（驻场岛）、
> `lib/models/app_notice.dart`（`NoticeKind` / `AppNotice`）。
>
> 系统通知（`flutter_local_notifications`）不在本文范围：见
> `lib/services/notification_service.dart`。

## 0. 三个渠道

| 渠道 | 承载内容 | 位置 | 生命周期 | 实现 |
| --- | --- | --- | --- | --- |
| **悬浮** | 普通短提示：保存 / 复制 / 校验 / 失败摘要 | 窗口正中、半透明卡片 | 进入 200ms → 驻留 3s → 消失 1000ms | `AppNoticeCenter` + `FloatingNoticeHost` |
| **驻场** | 云同步进度、云同步结果、正在生成 | 顶部居中（标题栏下方 + 8） | 有内容才存在，条目按类型自动撤销 | `PinnedNoticeIsland` |
| **系统** | 生成完成、后台保活、更新失败 | 操作系统通知中心 | 由系统管理 | `GenerationNotificationService` |

三渠道边界：**应用内**的一切提示走悬浮或驻场；**离开应用后**才需要提醒的走系统通知。
对话框（`showDialog`）与页面内联提示（如首页「未开启系统通知」卡）不是通知渠道，保持原样。

## 1. 为什么要统一

| 统一前的形态 | 问题 |
| --- | --- |
| `ScaffoldMessenger` / `SnackBar`（23 个文件 43 处） | 底部弹出、受 Scaffold 生命周期约束；窄屏文案被截断；各调用点自行 `hideCurrentSnackBar` / 设时长，交互不一致 |
| `SyncHud`（同步进度悬浮胶囊） | 与生成横幅争同一位置，靠 `+44px` 互相避让；可自由拖动 |
| `SyncResultBubble`（同步结果气泡） | 数据 + 图片两平面各出一条 → **一次弹两个**；失败条目驻留直到手动关闭 → **偶发异常下一直常驻** |
| `GenerationBanner`（正在生成横幅） | 首页与对话页各内嵌一份，与 HUD 位置冲突 |

统一后的收益：单一锚点（不再互相避让）、单条悬浮（不叠加、窄屏可查阅）、
失败提示有明确上限（15s 无条件撤销，不会永久常驻）。

## 2. 悬浮渠道

### 2.1 数据模型

```dart
enum NoticeKind { info, success, warning, error }   // 图标 / 颜色 / 驻留同源
class AppNotice { int id; String message; NoticeKind kind; Duration dwell; bool copyable; }
```

### 2.2 状态机与时序

```
入队 → queued → visible(进入 200ms) → dwelling(dwell) → exiting(1000ms) → removed → 下一条
```

| 项 | 常量 | 值 |
| --- | --- | --- |
| 进入动画 | `AppNoticeCenter.enterDuration` | 200ms（fade + scale 0.96→1.0） |
| 驻留时长 | `AppNoticeCenter.defaultDwell` | 3s（驻留计时自入队起算，含进入动画；可由 `dwell:` 覆盖） |
| 退出动画 | `AppNoticeCenter.exitDuration` | 1000ms（`animateBack(0)`，无论动画进度如何都走满 1s） |
| 队列上限 | `AppNoticeCenter.maxPending` | 8（超出丢弃最旧待显示条目） |

**计时归中心，动画归宿主**：驻留与兜底定时器在 `AppNoticeCenter`，
宿主（`FloatingNoticeHost`）只播放动画并在退出动画播完后回调
`completeDismissal(id)`。因此宿主未挂载 / 掉帧时提示也会到期，
不会出现「偶发异常下一直常驻」；退出阶段另有 `exitDuration + 400ms`
兜底定时器兜住宿主的异常。

### 2.3 撤销规则

| 触发 | 行为 |
| --- | --- |
| 驻留到点 | 自动进入 1000ms 消失动画 |
| **点击**悬浮通知 | 立即进入消失动画 |
| **按住划过**（触控 / 鼠标按下后拖动） | 立即进入消失动画 |
| **鼠标悬停** | **不触发**（划过不等于点击） |
| 同文案再次入队 | 正在显示 → 重置驻留计时；仍在队列 → 忽略（连点复制不叠加） |
| 队列满 | 丢弃最旧的待显示条目 |

### 2.4 手势与命中

宿主位于 Navigator 之上、自带一层 `Overlay`（提示里的 `Tooltip` 需要 Overlay 祖先）。
`Overlay` / `Align` 自身不参与命中测试，空白区域的指针事件照常落到页面上。

### 2.5 宽度与可读性

| 项 | 规则 |
| --- | --- |
| 宽度 | 宽屏 `min(520, 窗口宽 - 32)`；窄屏（< 600）`窗口宽 - 24` |
| 高度 | ≤ 窗口高 45%，超出内部可滚动 |
| 文案 | 换行显示、不截断；`copyable: true` 时用 `SelectableText` 且恒显「关闭」按钮 |
| 位置 | 窗口正中（水平 + 垂直居中） |

### 2.6 视觉（与驻场岛统一）

通知类**统一黑底 + 白 / 浅色字体**，常量集中在
`lib/widgets/notice_visuals.dart`（唯一来源）：

| 常量 | 值 | 用途 |
| --- | --- | --- |
| `kNoticeSurface` | `0xFF16161A` | 驻场岛底色（不透明近黑，灵动岛式实体感） |
| `kNoticeSurfaceTranslucent` | `0xC70B0B0E`（≈ 78% 黑） | **悬浮通知底色：真正半透明**，可透出下方页面内容 |
| `kNoticeTextPrimary` | `0xFFF7F7F9` | 主文案（白） |
| `kNoticeTextSecondary` | `0xFFA9A9B2` | 次要文案 / 关闭与取消图标（浅灰白） |
| `kNoticeDivider` / `kNoticeBorder` | `0x1FFFFFFF` | 分隔线 / `+N` 徽标背景 / 半透明卡片描边 |
| `kNoticeRadius` | 14 | 悬浮卡片圆角 |

强调色（图标）为**深色底专用**常量、不随应用亮 / 暗主题变化：
成功 `0xFF34D399`、警告 `0xFFFBBF24`、失败 `0xFFF87171`、中性 `kNoticeTextSecondary`；
同步转圈 / 进度条沿用品牌色 `NarrChatTheme.primary`。

深色表面还通过 `noticeThemeOf(context)` 覆盖选区高亮 / 光标 / `IconButton` 前景色，
避免沿用浅色主题的深色前景导致不可读；`Material.surfaceTintColor` 置为透明，
保证黑色半透明不被 M3 表面着色覆盖。

## 3. 驻场岛

### 3.1 形态

- **收起态**：嵌在**页面顶栏的中部**（由统一顶栏 `NarrChatAppBar` 提供槽位，见 §3.6）：
  宽屏居中嵌在工具栏一行内、标题被按需挤压；窄屏（< 760）或宽度预算不足时
  顶栏向下多出一行（[kIslandRowHeight] = 28）居中放岛；
- **展开态**：点击胶囊 → 200ms 从顶栏**脱离**成悬浮卡片（顶栏下缘 +10、居中、
  宽 `min(360, 窗口宽 - 24)`，圆角 999→14、阴影 0→6 一起过渡）；顶栏槽位
  收缩为 [kIslandMarkerSize] 的**小标记**（标题回收空间），点击标记可把岛收回顶栏；
- **出现 / 消失动画（嵌入态，手机厂商岛式）**：**非线性地改变岛的实际宽度**——
  出现时自中心向左右张开，消失时自两侧向中心收窄至宽度归零撤下
  （`ClipRRect(圆角) + Align(widthFactor: _unfoldCurve(presence))`；曲线为
  `Curves.easeOutCubic`，描边随展开度淡入）。裁剪形状恒为**圆角胶囊**
  （半径 999 由 Skia 收敛为高的一半），因此任意中间态都不会出现直角遮罩。
  顶栏槽位会保留到完全收窄为止（附加行再花 200ms 收回），否则消失动画会在中途
  被抽走锚点、退化成悬浮淡出；
- **出现 / 消失动画（无槽位的悬浮态）**：自顶部下移 12px + 淡入 / 反向淡出，
  淡出期间沿用最后一帧内容快照（不会先闪空再淡出）；
- **展开脱离 / 收回**：位置 / 宽度 / 圆角（999→14）/ 阴影（0→6）200ms 一起过渡；
  槽位处的小标记随脱离度淡出，与「岛降回顶栏」连续衔接；
- **锚点缺失时**（对话框 / 未接顶栏的页面 / 图片查看器独立窗口）：退化为页面顶部
  居中悬浮（与嵌入协作启用前一致）；
- **底色**：不透明近黑 `kNoticeSurface` + 白 / 浅色字体（与悬浮渠道同一套常量，见 §2.6）。
- 位置：`安全区 + kToolbarHeight + 8`，水平居中；**不可拖动**（灵动岛式固定锚点）。

### 3.6 与统一顶栏的协作（槽位协议）

全应用顶栏已统一为单一组件 `lib/widgets/narr_chat_app_bar.dart`
（左侧按键 / 标题图标 / 标题 / 右侧按键 + 岛槽位），页面用
`lib/widgets/island_bar.dart` 的 `IslandAwareScaffold` 包裹即可接入：

| 角色 | 职责 |
| --- | --- |
| `IslandBarController` | 顶栏与岛之间的唯一协作点：`slotRect`（岛收起时应处的矩形）、`barRect`（顶栏矩形，用于悬浮位贴住下缘）、`islandActive` / `islandExpanded`（岛的状态）、`extraRowHeight`（顶栏附加行当前高度，逐帧） |
| `NarrChatAppBar` | 按宽度与左右占位算预算并汇报 `twoRow`；渲染不可见槽位 `IslandSlot`（只测量矩形，岛由 overlay 画在同一位置）；把标题约束到「岛左缘 - 间距」 |
| `IslandAwareScaffold` | 只订阅 `extraRowHeight` 逐帧重建脚手架，让顶栏高度平滑拉出 / 收回附加行（`body` 作为 child 不重建） |
| `PinnedNoticeIsland` | 收起态画在槽位里；展开态从槽位脱离到悬浮位并在槽位处留小标记 |

宽度与标题规则（常量见 `island_bar.dart`）：

```
actionsWidth  = 右侧按键实测宽度（首帧用保守估计 160，测量后收敛）
available     = 顶栏宽 - 左侧占位 - actionsWidth - 2×标题保底 - 2×间距
slotBudget    = clamp(available, 0, 顶栏宽 × 0.42)
twoRow        = 顶栏宽 < 760  或  slotBudget < 140
标题可用宽     = 单行 ? (顶栏宽/2 - 槽位宽/2 - 间距 - 左侧占位) : 顶栏宽
```

- 标题保底 [kIslandTitleMinWidth] = 88px（约 8 个汉字，随全局字号缩放）；
- 岛展开后槽位收缩为 24px，标题随之回收空间；
- 预算不足（如右侧按键过宽）时即使窗口够宽也改走附加行，避免把标题挤没；
- **无左侧按键时**标题间距回到 Material 默认的 16px（否则根页面标题会贴到窗口左缘）；
- **自动返回键**交给 `AppBar.automaticallyImplyLeading`（判据是
  `ModalRoute.impliesAppBarDismissal`，挂在路由上、路由栈变化即自动重建）；
  不要自己判 `Navigator.canPop()`——它在「返回动画途中恰好重建」时会把状态判死，
  留下一个永不消失的返回键。

### 3.2 收起态主文案优先级

1. 最新一条同步结果（需要被看到 / 已读 / 计时）；
2. 否则同步进度（数据平面优先，例如 `数据同步 · 上传快照`）；
3. 否则正在生成（`N本书正在生成……`，计数含全部在生成的书，不再按当前书排除）。

未展示的其余活动段以 `+N` 提示。

### 3.3 展开区内容

| 段 | 内容 | 交互 |
| --- | --- | --- |
| 结果段 | 类型图标 + `SelectableText` 文案 | 失败条目行尾「已读」按钮 |
| 同步段 | 平面名 · 阶段 · 计数 + 进度条 | 本平面「取消」按钮（`tooltip: 取消数据同步 / 取消图片同步`） |
| 生成段 | spinner + 书名 | 点击 → `onOpenBook(uuid)` 跳转对应书对话页 |

展开区高度 ≤ 窗口高 30%，超出内部滚动。

### 3.4 自动撤销规则（驻场）

| 条目类型 | 驻留时长 | 其他撤销方式 |
| --- | --- | --- |
| 成功 / 中性结果 | 3s（`NoticeKind.success` / `info`） | — |
| 警告 | 5s（`NoticeKind.warning`） | — |
| 失败结果 | 15s（`NoticeKind.error`） | **「已读」= 提前收起** |
| 同步进度 | 在跑即显示，跑完即消失 | 展开区「取消」→ 该平面协作式停止 |
| 正在生成 | 有书在生成即显示 | — |

> **「已读」语义**：仅表示**提前收起**；15s 到点后无条件消失。
> 不做未读列表、不做角标、不落盘、不参与云同步。

计时归 `_PinnedNoticeIslandState`（`_syncResultTimers`）：**与是否展开无关**，
收起态条目不渲染也照常到点撤销。

### 3.5 与旧组件的对照

| 旧 | 新 |
| --- | --- |
| `SyncHud`（进度胶囊，可拖动 / 折叠 / 分平面取消） | 驻场岛收起态（进度主文案）+ 展开态（分平面取消）；拖动与 `+44px` 避让删除 |
| `SyncResultBubble`（成功 2s / 失败驻留 / 多条目堆叠） | 驻场岛结果段（成功 3s / 失败 15s + 已读） |
| `GenerationBanner`（首页 + 对话页内嵌横幅，排除当前书） | 驻场岛生成段（全局计数，展开后点书名跳转） |

## 4. 数据流

```
调用点（任何有 context 的地方）
    └─ context.notices.{info|success|warning|error}(message, {dwell, copyable})
           └─ AppNoticeCenter（队列 + 计时）→ FloatingNoticeHost（动画 / 手势）

CloudSyncProvider.resultToasts ─┐
CloudSyncProvider 分平面进度 ───┼─→ PinnedNoticeIsland（watch / select）
RoundProvider.activeGenerationBookUuids ─┘
```

- `AppNoticeCenter` 由 `AppNoticeOverlay` 创建（也可经 `center:` 注入，测试用），
  页面与对话框通过 `context.notices` 取用；
- 跨 `await` 时先 `final notices = context.notices;`，之后无需再查 Scaffold / Context 生命周期；
- 驻场岛只读上述 Provider，自身只持有「是否展开」与结果计时器，不新增持久化状态。

## 5. 接线位置

| 位置 | 接线 |
| --- | --- |
| `lib/main.dart` | `MaterialApp.builder` → `MediaQuery.withClampedTextScaling` → `AppNoticeOverlay(onOpenBook: 通知服务.openChatBook)` |
| `lib/widgets/image_viewer_window.dart` | 两个查看器窗口的 `MaterialApp.builder` → `AppNoticeOverlay(pinnedIsland: false)`（子窗口无云同步 / 生成 Provider，也没有顶栏槽位协作） |
| 页面顶栏 | 全部迁移到 `NarrChatAppBar` + `IslandAwareScaffold`（首页 / 对话页 / 设置外壳 / 字体设置 / 图片库 / 数据库结构 / 数据库合并 / 调试 / 更新日志 / 许可） |
| `test/helpers/notice_harness.dart` | `floatingNoticeBuilder()` / `noticeHostBuilder()` / `pumpNoticeApp()` / `flushNotices()` |
| `test/helpers/chat_harness.dart` | `pumpChatScreen` / `pumpHomeScreen` / `pumpNotificationHost` 已默认挂宿主 |

## 6. 系统通知边界（不变）

- 生成完成、Android 后台保活前台服务、启动更新检查失败 → 仍走
  `GenerationNotificationService` / `NotificationBackend`；
- 点击系统通知进入对应书对话页的链路不变（`openChatBook`），
  驻场岛「正在生成的书」跳转复用它。

## 7. 调用点迁移

规则（旧 `SnackBar` → 新渠道）：

| 旧文案类型 | 新调用 | 说明 |
| --- | --- | --- |
| 成功 / 完成（已保存、已复制、已删除、图片已保存…） | `context.notices.success(...)` | 3s |
| 失败 / 异常（保存失败、删除失败、请求失败、…失败：$e） | `context.notices.error(..., copyable: true)` | 3s；长文案可复制并显式关闭 |
| 校验 / 中性提醒（不能为空、尚未选择书籍、未获取到…） | `context.notices.warning(...)` | 5s |
| 其他短提示（已复制预览链接等） | `context.notices.info(...)` | 3s |
| `Duration(seconds: 1 / 2 / 4)` | `dwell: 1s / 2s / 4s` | 保留原有时长语义 |
| `..hideCurrentSnackBar()..showSnackBar(...)` | 直接 `show` | 单槽位渠道天然去重 |

迁移覆盖 `lib/` 下 23 个文件共 43 处（`grep -rn "scaffoldMessenger\|snackBar" lib/` 应为 0）：

| 文件 | 处数 | 文件 | 处数 |
| --- | --- | --- | --- |
| `screens/chat_screen.dart` | 7 | `widgets/edit_text_images_dialog.dart` | 3 |
| `screens/book_settings_screen.dart` | 3 | `widgets/image_preview.dart` | 2 |
| `screens/database_merge_screen.dart` | 2 | `widgets/mod_detail_dialog.dart` | 2 |
| `screens/debug_screen.dart` | 3 | `widgets/mod_management_panel.dart` | 2 |
| `screens/font_settings_screen.dart` | 2 | `widgets/world_book_panel.dart` | 2 |
| `screens/image_gallery_page.dart` | 3 | `widgets/book_actions.dart` | 1 |
| `screens/licenses_screen.dart` | 1 | `widgets/book_mod_panel.dart` | 1 |
| `screens/settings_screen.dart` | 1 | `widgets/cloud_sync_panel.dart` | 1 |
|  |  | `widgets/draggable_role_list.dart` | 1 |
|  |  | `widgets/failed_attempt_bubble.dart` | 1 |
|  |  | `widgets/raw_dialog.dart` | 1 |
|  |  | `widgets/sidebar_panel.dart` | 1 |
|  |  | `widgets/storage_management_panel.dart` | 1 |
|  |  | `widgets/update_available_dialog.dart` | 1 |
|  |  | `widgets/uuid_display.dart` | 1 |

同时删除：`widgets/sync_hud.dart`、`widgets/sync_result_bubble.dart`、
`widgets/generation_banner.dart`、`theme/app_theme.dart` 的 `snackBarTheme`，
以及 `SyncToastKind`（由 `NoticeKind` 取代）。

## 8. 测试

| 文件 | 覆盖 |
| --- | --- |
| `test/app_notice_center_test.dart` | 单槽 FIFO、去重、上限淘汰、驻留到点、点击/划过提前退出、兜底移除、`reset` / `dispose` 无悬挂定时器 |
| `test/floating_notice_test.dart` | 居中 + 半透明、**黑底白字与半透明度（≤ 0.85）**、200ms/3s/1s 时序、点击与按住划过提前消失、悬停不触发、去重、320 宽可换行不溢出、`copyable` |
| `test/pinned_notice_island_test.dart` | 空闲不占位、**出现 / 消失动画（200ms 淡入淡出 + 淡出期间保留快照）**、**黑底白字视觉**、收起态无取消按钮、展开后分平面取消、生成段计数与跳转、结果 3s/15s 自动撤销、「已读」提前收起、主文案优先级、窄屏不溢出 |
| `test/narr_chat_app_bar_test.dart` | 统一顶栏自身：无左键时标题保留 16px 标准左留白且不显示返回键、可返回路由自动出返回键并让位、**返回根路由后返回键不残留**（回归） |
| `test/island_bar_test.dart` | 顶栏 × 岛协作：宽屏嵌入（槽位在工具栏内、水平居中、标题被挤压且不重叠、保底 8 字宽）、窄屏与预算不足改走附加行（**高度 200ms 过渡**、中途值介于两端之间）、**嵌入态非线性调整宽度（0→完整宽，前段更快、左右对称）**、**消失收窄后撤下**、展开脱离（悬浮在顶栏下方 + 槽位收缩为小标记 + 点击收回）、无顶栏页面回退悬浮、岛消失后附加行收回 |
| `test/cloud_sync_provider_test.dart` | 结果队列去重 / 上限淘汰 / 按 id 关闭、成功 3s 与失败 15s 的驻留时长 |

页面级用例通过 `test/helpers/notice_harness.dart` 挂宿主；
只断言文案、不关心时序的用例在结尾调用 `flushNotices(tester)`
清空驻留计时（否则 `testWidgets` 会报「悬挂定时器」）。

## 9. 已知限制

- 应用内通知**不落盘**：进程重启后不保留任何未读 / 历史；
- 计时与会话状态无关：应用在后台时驻留照跑，回到前台可能已经过期；
- 悬浮通知为纯展示（无操作按钮）；需要用户决策的一律走对话框；
- 窄屏（< 760）顶栏会为岛多占一行 28px：出现 / 消失时页面内容被推挤 28px
  （有 200ms 过渡，但确实会发生位移）；
- 岛嵌在顶栏时，标题会被挤压到「岛左缘 - 间距」以内（保底 8 字宽后省略号），
  这是设计取舍：宁可截断标题也不与岛重叠；
- 顶栏附加行只在岛有内容时占用；无内容时顶栏恢复单行（高度动画 200ms）。
