# 选中文本自动弹出「复制 / 全选」工具条 — 落地记录（2026-10-17）

> **本轮针对全应用的可选中文本**（对话页消息列 / 气泡正文 / 思考框 / 推荐行动 / 各类预览，
> 以及 **RAW 对话框内容块**、**Token 明细气泡**、各类**对话框详情文本**与**通知文案**）：
> 触屏双击选词、鼠标拖拽选中后**自动**弹出横排工具条，含「复制」。
>
> **状态**：全部落地；`lib/` 内已无裸 `SelectionArea` 与 `SelectableText`（唯一真源），
> 选中 / 输入框两类浮动选项条都由自绘的 `SelectionToolbar` 提供（**各平台一致横排**）。
> 见文末「验证结论」。
> **环境**：Flutter 3.47.5 / Dart 3.13.4；目标平台 Windows + Android。

## 1. 需求与口径（已与用户确认）

| 需求 | 口径 |
|---|---|
| 触屏双击选中后自动弹工具条 | 命中框架的**双击选词**（含双击后拖动按词扩展选区） |
| 鼠标拖拽选中后自动弹工具条 | 鼠标拖拽、鼠标双击选词都弹；触控笔同鼠标 |
| 工具条项 | 「复制」+「全选」（用户选定） |
| 触屏长按 | **不改**：仍归气泡业务菜单（复制正文 / 刷新本轮…） |
| 鼠标右键 | **不改**：仍归业务右键菜单 |
| 原地单击 | 不弹（单击只是收起选区） |
| 工具条形态（用户二次确认） | **恒为横排横条**，即浏览器 / 移动端框选那种：圆角卡片 + 横排文字按钮；位置由选区锚点决定（选区上方，放不下翻到下方并钳在屏内） |
| 横条视觉（用户四次确认） | **白底**（浅色主题下不用灰）、字号 14、上下留白略放大；与气泡右键菜单同一套卡片口径 |
| 输入框菜单同样横排（用户三次确认） | 输入框的右键 / 长按菜单（全选 / 复制 / 粘贴 / 剪切）也用同一横条，不再用框架自带的平台分派工具栏 |
| 弹出后选区必须保留（用户二次确认） | 弹出不得清掉框选区域。首版用应用统一菜单 `showAppMenu`（模态路由）会夺焦点，框架失焦即 `clearSelection()` → 框选当场消失，**已按上一条重做** |

## 2. 改动清单

| 文件 | 改动 |
|---|---|
| [lib/widgets/markdown_preview.dart](../lib/widgets/markdown_preview.dart) | 统一选中容器 `SelectableTextArea` 自建分支由裸 `SelectionArea` 换成 `_SelectionCopyToolbar`：`Listener` 记录设备/位移/双击 + `SelectionArea.onSelectionChanged` 维护选区文本 + 选中结束弹横排工具条；框架自带工具栏照旧抑制 |
| [test/selection_copy_toolbar_test.dart](../test/selection_copy_toolbar_test.dart) | 隔离层 20 例：鼠标拖拽 / 鼠标双击 / 触屏双击 / 触屏双击后拖动弹工具条；**收起后再选仍弹**；**拖选区手柄改完选区抬手补弹**；**弹出后原选区保留**；**横排形态**（含 `Theme.platform = windows` 的桌面条件）；**浮在选区上方**；**白底 / 字号 / 留白**；点「复制」落剪贴板 + 「已复制」提示；「全选」后工具条保持可用；长按、右键、原地单击均不弹；作用域内跨块选中同样弹且能复制跨块文本；点工具条外收起 |
| [test/selectable_text_scope_test.dart](../test/selectable_text_scope_test.dart) | 拖动选中后先收起自动弹出的工具条（同一用例里两段拖动连着做）；「框架工具栏被抑制」用例的语义改为「选中工具条由应用统一弹出」 |
| [test/chat_selection_scope_test.dart](../test/chat_selection_scope_test.dart) | 对话页集成 1 例：跨气泡拖拽选中 → 自动弹工具条 → 点「复制」得到跨气泡文本 |
| [lib/widgets/raw_dialog.dart](../lib/widgets/raw_dialog.dart) | RAW 内容块 `_HighlightText` 的裸 `SelectionArea` 换成 `SelectableTextArea`：框架默认工具栏（长按 / 双击才出现）改由统一容器的「选中即弹」工具条接管；块内分段 `RichText` + `SelectionContainer.maybeOf` 取 registrar 的既有做法不变 |
| [lib/widgets/token_usage_bubble.dart](../lib/widgets/token_usage_bubble.dart) | Token 明细气泡的裸 `SelectionArea` 换成 `SelectableTextArea`（同一套选中 / 复制语义） |
| [test/raw_dialog_test.dart](../test/raw_dialog_test.dart) | 新增 1 例：RAW 块内拖拽选中 → 自动弹工具条 → 点「复制」得到块内文本 |
| [test/token_usage_pill_test.dart](../test/token_usage_pill_test.dart) | 新增 1 例：明细气泡内拖拽选中「模型名」行 → 自动弹工具条 → 点「复制」落剪贴板 |
| [test/helpers/raw_dialog_harness.dart](../test/helpers/raw_dialog_harness.dart) | 文档同步：块内 `SelectionArea` 现由统一选中容器提供 |
| **第六轮：修复触控端两个实测缺陷** | |
| [lib/widgets/markdown_preview.dart](../lib/widgets/markdown_preview.dart) | ①「拖选区手柄后工具条不再弹」：手柄是 Overlay 上的独立 widget，指针事件**不进**本组件 `Listener` 子树 → 新增**全局指针路由**（`GestureBinding.pointerRouter.addGlobalRoute`）收口；按下不在区域内、但本轮手势里选区确实被改过 → 抬手补弹（纯点别处仍不弹）。②「再次双击 / 选中常不弹」三处原因一并修：触发判据从「双击间隔 + 拖拽位移」换成**「本轮手势内选区是否变化过」**（更稳，不受时间戳抖动影响）；滚动收起只在 `dragDetails != null`（用户拖动滚动）时生效，不再被框架「让选区可见」的程序滚动误收；判定整体挪到**微任务**——框架的选区回调可能排在抬手之后（触屏双击的选词要等手势竞技场在抬手时裁决），在抬手处同步判定会读到「选区还没变」 |
| [test/selection_copy_toolbar_test.dart](../test/selection_copy_toolbar_test.dart) | 新增 3 例：收起后再次选中仍会弹出（鼠标拖拽 / 触屏双击各一）、拖选区手柄（指针落在区域外）改完选区后抬手补弹 |
| **第五轮：横条样式微调（用户确认后）** | |
| [lib/widgets/selection_toolbar.dart](../lib/widgets/selection_toolbar.dart) | 底色由 `colorScheme.surfaceContainerHighest`（灰）改为主题 `NarrChatColors.surface`（**浅色即纯白**、深色自动转深灰，与 `popupMenuTheme` 同源）；字号 13 → 14；上下留白放大（按钮高度 30 且**去掉 `visualDensity.compact`**——它会把高度再压掉 8px，与「留白变大」相反；卡片上下各 4）；圆角 / 阴影对齐 `NarrChatTheme.menuRadius` 与菜单口径（12 / 3） |
| [test/selection_copy_toolbar_test.dart](../test/selection_copy_toolbar_test.dart) | 新增 1 例：白底（`NarrChatColors.light.surface`）、字号 14、按钮与卡片的上下留白 |
| **第四轮：把工具条改成恒定横排（自绘）** | |
| [lib/widgets/selection_toolbar.dart](../lib/widgets/selection_toolbar.dart) | 新增：横排浮动选项条 `SelectionToolbar`（`CustomSingleChildLayout` + 框架的 `TextSelectionToolbarLayoutDelegate` 定位，圆角卡片 + 横排 `TextButton`，走应用主题）。**两类调用点共用**，形态从此与平台无关 |
| [lib/widgets/markdown_preview.dart](../lib/widgets/markdown_preview.dart) | 选区工具条改用它（原 `AdaptiveTextSelectionToolbar` 在 Windows 上渲染成竖排列表） |
| [lib/widgets/text_field_context_menu.dart](../lib/widgets/text_field_context_menu.dart) | 输入框右键 / 长按菜单改用它（同样问题、同样修法） |
| [test/chat_paste_test.dart](../test/chat_paste_test.dart) | 新增 1 例：输入框菜单四项**在同一行**（横条而非竖排列表） |
| **第三轮：清掉全部 `SelectableText`（10 处）** | |
| [lib/widgets/uuid_display.dart](../lib/widgets/uuid_display.dart) · [update_available_dialog.dart](../lib/widgets/update_available_dialog.dart) · [raw_dialog.dart](../lib/widgets/raw_dialog.dart)（图片详情行） · [keep_versions_dialog.dart](../lib/widgets/keep_versions_dialog.dart) · [mod_management_panel.dart](../lib/widgets/mod_management_panel.dart) · [licenses_screen.dart](../lib/screens/licenses_screen.dart) · [database_inspect_screen.dart](../lib/screens/database_inspect_screen.dart) · [database_merge_screen.dart](../lib/screens/database_merge_screen.dart) · [floating_notice_host.dart](../lib/widgets/floating_notice_host.dart) · [pinned_notice_island.dart](../lib/widgets/pinned_notice_island.dart) | `SelectableText(x, style: s, [maxLines: n])` → `SelectableTextArea(child: Text(x, style: s, [maxLines: n]))`：这批短文本展示位原先挂着**框架默认工具栏**（长按 / 双击才出现、文案由平台给），并入后与全应用同一套「选中即弹 复制 / 全选」 |
| [test/database_inspect_screen_test.dart](../test/database_inspect_screen_test.dart) · [floating_notice_test.dart](../test/floating_notice_test.dart) · [update_available_dialog_test.dart](../test/update_available_dialog_test.dart) · [raw_dialog_test.dart](../test/raw_dialog_test.dart) | 断言随形态更新：`find.byType(SelectableText)` → 统一容器 / 行为化断言（详情行与下载地址的「可选中」语义不变，只是换了容器） |
| [lib/models/app_notice.dart](../lib/models/app_notice.dart) · [lib/providers/cloud_sync_provider.dart](../lib/providers/cloud_sync_provider.dart) | 文档同步（`copyable` / 同步结果文案现在由统一容器呈现） |

## 3. 设计要点（为什么这样做）

- **为什么不交给框架的选中工具栏**：桌面平台（Windows / macOS / Linux）在拖拽与双击结束后**刻意不显示**工具栏（`widgets/selectable_region.dart` 的 `_handleMouseDragEnd` / `_handleMouseTapUp` 桌面分支直接 break），触屏虽会显示但按钮由平台默认文案给出。故沿用「框架自带工具栏一律抑制」的既有约定（`contextMenuBuilder` 返回空 `SizedBox`，长按 / 右键仍归业务菜单），改由应用在选中结束时**按同一套外观**弹出自己的工具条（`AdaptiveTextSelectionToolbar`）。
- **工具条必须非模态**（第二轮返工的根因）：首版用 `showMenu`，它是模态路由，push 后夺走焦点，而框架的 `SelectableRegionState._handleFocusChanged` 在失焦时会 `clearSelection()`（`widgets/selectable_region.dart:526-543`，且只在 `lifecycleState == resumed` 时执行——真机必然命中）→ 表现就是「工具条一弹出来，刚框选的区域当场消失」。改为 `OverlayEntry` 直接插进 Overlay：不夺焦点、不铺遮罩，选区原样保留，用户还能接着拖手柄微调。
- **为什么自绘横条（而不是框架的 `AdaptiveTextSelectionToolbar`）**：它按平台分派，同一份按钮会长成三种样子——Windows / Linux / macOS 走 `DesktopTextSelectionToolbar`，**内部是 `Column`（竖排列表）**（`desktop_text_selection_toolbar.dart:83`，这正是用户截图里的形态）；Android 走 `TextSelectionToolbar`（横排，但宽度不足会折叠成「⋮」+ 竖排面板）；iOS 走竖排的 Cupertino 版本。要「各平台一致横排」只能自绘：定位仍复用框架的 `TextSelectionToolbarLayoutDelegate`（选区上方 → 放不下翻下方 → 屏幕内钳制），外观走应用主题。
- **触发口径用「手势 + 选区」双重判据，天然不与业务菜单打架**：
  - 触屏只认**双击**（`BubblePointerListener` 的长按业务菜单不受影响）；
  - 鼠标右键显式排除（`_downIsSecondaryMouse`）；
  - **原地单击不弹**：记录本次按下的最大位移，鼠标 / 触控笔超过 4px（`_kPreciseDragSlop`，桌面拖选一两个字符也只有几像素，阈值不能取触屏的 `kTouchSlop`）、触屏靠双击判定。这一条是防回归的关键——否则「上一次的选区还在」会让任意单击都重复弹工具条。
  - 「推荐行动」选项行的双击是业务手势（插入输入框），行内 `DoubleTapGestureRecognizer` 赢下竞技场后框架不选词，选区为空 → 不会弹工具条（既有 `chat_bubble_test` 用例继续通过）。
- **收起时机**：点工具条以外（`TapRegion.onTapOutside`，不吃掉这次点击）、区域内滚轮 / 触控板（`onPointerSignal`）、选区内部滚动（`NotificationListener<ScrollNotification>`）、选区被清空（`onSelectionChanged`）、组件销毁——都会收起。位置只在弹出时按选区锚点算一次，故滚动会直接收起而不是漂移。
- **「全选」后工具条保持可用**：框架的 `selectAll` 内部**先** `clearSelection()`（那一次「选区清空」回调会把工具条收掉），故在新选区落定后按新锚点重新弹回来（同一轮微任务内，用户看不到闪动）。否则用户点完「全选」就没有「复制」入口了。
- **工具条项文案与提示口径**：`ContextMenuButtonItem(label: '复制')` / `label: '全选'`（框架的 `getButtonLabel` 优先用自定义 label，`adaptive_text_selection_toolbar.dart:205-208`），复制后 `context.notices.success('已复制')`，与气泡菜单「复制正文」、输入框菜单「复制」一致；隔离用例等没有通知中心的环境下用可空 Provider 查询静默跳过。
- **统一容器是唯一真源**：RAW 内容块、Token 明细气泡、10 处短文本展示位（UUID / 许可证全文 / 下载地址 / 错误详情 / JSON 分享文本 / 通知文案…）原先各自用裸 `SelectionArea` 或 `SelectableText`（行为是「长按 / 双击才出现框架工具栏」），并入后 `lib/` 内**再无裸 `SelectionArea` 与 `SelectableText`**——选中 / 复制语义全应用一处可改。迁移是**等价替换**：`SelectableText` 的 `style` 同样按 `DefaultTextStyle.merge` 合成（`material/selectable_text.dart:745-751`），故视觉不变；RAW 块的分段 `RichText` + `SelectionContainer.maybeOf` 取 registrar 的既有做法也不受影响。
- **防回退约定**：`SelectableTextArea` 的类文档写明「全应用唯一的可选中文本入口」，新增可选中展示文本一律复用它，不再引入 `SelectableText`（另一套 `EditableText` 选区，与作用域互斥、冷排版更慢）或裸 `SelectionArea`。

## 4. 验证结论

- `flutter analyze`（全项目）：无 issue。
- `flutter test`（全量）：**1876 passed / 1 skipped**（本轮新增 24 例；改造前基线 1852）。第三轮的 10 处 `SelectableText` 迁移为**等价替换**，不新增用例，改用例断言已随形态更新。
- 开发中（含用户实测反馈）发现并修掉六个**真实缺陷**，均由新增用例兜住：
  1. 「已有选区时原地单击」会重复弹出 → 引入按下位移判据；
  2. 触屏选区手柄盖住首版菜单项导致点不中 → 首版改在微任务里先 `hideToolbar()`（工具条化后位置避开手柄，已不再需要收手柄）；
  3. **工具条弹出即清空选区** → 根因是模态路由夺焦点触发框架 `clearSelection()`，改为非模态 `OverlayEntry`；回归用例显式还原真机的 `lifecycleState == resumed` 前置条件；
  4. **工具条 / 输入框菜单在桌面上是竖排** → 根因是框架 `AdaptiveTextSelectionToolbar` 的平台分派，改为自绘横条 `SelectionToolbar`；
  5. **拖选区手柄后工具条不再弹** → 手柄在 Overlay 上、指针事件不进 `Listener` 子树，加全局指针路由收口；
  6. **再次双击 / 选中时常不弹** → 触发判据换成「本轮手势内选区是否变化过」、滚动收起限定为用户拖动滚动、判定挪到微任务（框架选区回调可能排在抬手之后）。
- 迁移等价性的依据：`SelectableText` 的 `style` 走 `DefaultTextStyle.merge`（`material/selectable_text.dart:745-751`），与 `Text` 一致；`maxLines` / 布局参数一一对应，因此这批展示位的排版不变。
- 真机（Windows / Android）手测仍未做：工具条在真机上的视觉位置与手柄的相对关系、剪贴板真实写入、长按业务菜单与选中工具条的手感差异、各展示位迁移后的观感。
- 本轮未做（超出用户口径）：触屏长按拖动选多词后弹工具条（长按已被气泡业务菜单占用，两边会打架，故触屏只认双击入口）；编辑类输入框（`TextField`）仍用各自的右键 / 长按菜单（全选 / 复制 / 粘贴 / 剪切），与只读文本的选中工具条是两套语义。

## 5. 有意不做的事

- 不改动 `release.yaml` / `update_log.md`（按仓库约定需显式许可）。
- 不新增「搜索 / 翻译」等工具条项（用户口径为复制 + 全选）。
- 不做「工具条跟随选区滚动」的逐帧重定位：那需要每帧请求新帧（会让 `pumpAndSettle` 永不收敛），改为滚动即收起，语义更干脆。
