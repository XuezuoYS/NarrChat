# 生成完成通知：默认悬浮 + 铃声，渠道状态探测与首页提示

日期：2026-10-17

## 需求

安卓端「生成完成」系统通知：默认要求系统启用悬浮通知（heads-up）与通知铃声；
探测其启用程度，悬浮或铃声被关闭时在首页用黄色提示条（与「未开启系统通知」
同款）提醒用户去开启。

## 背景坑

Android 通知渠道设置只在首次创建时生效，之后被系统锁定，代码改参数不会更新
已有渠道；因此「是否还开着」必须运行时探测。

## 改动

- `lib/services/notification_service.dart`
  - 新增 `GenerationDoneChannelState{headsUp, sound}`（含 ==/hashCode 与
    `fullyEnabled`）。
  - `NotificationBackend` 接口新增 `generationDoneChannelState()`，服务层同名透传。
  - 真实后端 `init` 显式 `createNotificationChannel`（high + 铃声 + 振动）：
    默认值确定落地、渠道立即可探测；渠道已存在时不覆盖用户改过的设置。
  - `generationDoneChannelState`：`getNotificationChannels` 找 `generation_done`，
    headsUp = importance ≥ high，sound = playSound；非 Android / 渠道未创建返回 null。
- `lib/providers/notification_settings_provider.dart`
  - `refresh()` 同时探测渠道状态（总开关已关时跳过探测并置 null），
    暴露 `generationDoneChannelState`。
- `lib/screens/book_list_screen.dart`
  - 提示卡复用：总开关关闭 → 原文案；总开关开着但渠道悬浮 / 铃声被关 →
    按实际关闭项列出「生成完成通知的悬浮通知、通知铃声已被关闭…」，
    「去开启」仍跳系统通知设置页。
- `test/helpers/fakes.dart`：`FakeNotificationBackend` 新增 `channelState`
  （默认全开）与 `openSettingsCount`。
- `test/book_list_test.dart`：新增 4 个用例（仅悬浮关 / 两者关 / 全开不提示 /
  总开关关时优先总开关提示），抽 `makeSettings` 小助手统一构造。
- `docs/app_notifications.md`：§6.1 记录该行为。

## 验证

`flutter analyze` 无问题；`flutter test` 全绿（1881 通过，1 跳过）。
