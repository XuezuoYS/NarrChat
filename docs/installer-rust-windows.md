# Windows 安装器：Rust + egui 薄壳包 Inno

> 一句话：**壳只做界面和流程，安装/卸载还是 Inno。**
> 壳源码在 [`installer_windows/`](../installer_windows/)，构建与签名步骤见文末。

## 为什么这样做

- 现有 [`tool/build_release.dart`](../tool/build_release.dart) 已经能产出 Inno `setup.exe`，文件复制、快捷方式、卸载注册、升级覆盖都是现成的。
- 壳只补两块：**完全自定义的 UI** 和 **安装前后的编排**。不重写安装引擎，也不碰用户「文档」目录下 `NarrChat` 里的用户数据。
- Rust + egui 是纯 Cargo 依赖，编译进 exe；不需要 WebView2、Electron、GTK 或额外的 UI 运行时。壳本身约 11MB；内嵌 Inno 后的最终 setup 约 29MB。壳带 `requireAdministrator` 清单，启动时统一请求一次 UAC，Inno 继承管理员权限，不再二次提权。

## 结构

```
NarrChatSetup.exe（Rust + egui，签名，requireAdministrator）
  ├─ 预检：是否已安装、NarrChat 是否在运行、安装包是否存在
  ├─ 选项：安装位置、桌面/开始菜单快捷方式
  ├─ 启动 Inno Setup（内嵌 payload 或同目录 sidecar）
  │    /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG=...
  │    /DIR=... /TASKS=...（升级也按上次选择显式传）
  │    TEMP/TMP 指向壳选出的可写工作目录
  ├─ 轮询退出码 + 读日志尾部（Spinner，不伪造百分比）
  └─ 成功：打开 NarrChat / 失败：显示退出码和日志入口
```

## 目录

```
installer_windows/
  Cargo.toml
  build.rs              读 release.yaml 版本；可选内嵌 payload；写 Windows 图标/版本资源
  assets/icon.png       窗口图标（来自主应用图标）
  assets/app_icon.ico   exe 文件图标
  payload/              放 narrchat-setup.exe 时内嵌；*.exe 已被 gitignore
  src/main.rs           入口、窗口、命令行
  src/app.rs            状态机：欢迎 → 选项 → 安装 → 完成/失败
  src/ui.rs             页面布局
  src/theme.rs          明暗配色（品牌色 #4D6BFE）
  src/installer.rs      Inno 参数、进程、日志、注册表、启动应用
  README.md             开发与构建速查
```

## 界面

- 固定窗口 `720×640`，不可缩放，隐藏最小化/最大化按钮；跟随 Windows 明暗主题，右上角可手动切换。
- 五屏：
  1. **欢迎**：版本、数据位置说明、已安装/运行中/安装包缺失提示；
  2. **选项**：安装位置、快捷方式；升级时路径和快捷方式只读；
  3. **安装中**：Spinner + 状态 + 可选日志尾部，关闭窗口会被取消；
  4. **完成**：安装目录、打开 NarrChat 按钮、打开目录/日志；
  5. **失败**：错误、Inno 退出码、日志入口、重试/退出。
- 中文靠 egui 0.37 的 `system_fonts` 系统字体回退，不打包字体；品牌色跟主应用 `lib/theme/app_theme.dart` 的 `#4D6BFE` 对齐。

## 关键行为

### 1. 版本与已安装检测

- 版本：`build.rs` 优先读 `NARRCHAT_APP_VERSION`，否则读仓库根目录 [`release.yaml`](../release.yaml) 的 `version:`；所以壳右上角会显示当前发布版本。
- 已安装检测：读 HKCU 下 Inno 卸载键
  `Software\Microsoft\Windows\CurrentVersion\Uninstall\{8F2E1A3C-5B6D-4E7F-9A8B-0C1D2E3F4A5B}_is1`
  的 `Inno Setup: App Path` 和 `DisplayVersion`，和 Inno 脚本里的 AppId 一致。
- 运行中检测：`tasklist` 查 `narrchat.exe`；运行中不允许开始安装，避免覆盖正在使用的文件。

### 2. 安装包从哪来

按顺序找：

1. 命令行 `--setup <setup.exe>`；
2. 环境变量 `NARRCHAT_INNO_SETUP`；
3. 壳同目录的 `narrchat-setup.exe`、`NarrChatSetup.exe`、`NarrChat_*_windows_x64-setup.exe`（sidecar，推荐）；
4. 编译时内嵌的 `payload/narrchat-setup.exe`（单文件发布用）。

内嵌模式不会直接运行内存里的字节，会在**启动时**释放成 exe：

- 释放到壳选出的可写工作目录（`%LOCALAPPDATA%\NarrChat\setup-work` → `%TEMP%\NarrChatSetup`）；
- **不会在安装包所在目录创建任何文件夹或文件**；
- 安装成功后删除释放出来的临时 exe（日志保留在工作目录）。

如果 AppData 和 `%TEMP%` 都写不进去（安全软件/只读环境），会提示改用 sidecar 或 `--setup`。找不到安装包时欢迎页会显示提示，并给一个「选择 Inno 安装包…」入口。

### 3. Inno 参数

| 场景 | 参数 |
| --- | --- |
| 全部 | `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG=<工作目录>\install.log` |
| 全新安装 | 额外 `/DIR=<安装位置>`、`/TASKS=desktopicon,startmenuicon`（只传勾选的） |
| 升级安装 | 同样传 `/DIR`、`/TASKS`（从注册表还原上次选择），避免管理员上下文变化后装错 |

当前 Inno 脚本 [`tool/build_release.dart`](../tool/build_release.dart) 里：

- `PrivilegesRequired=lowest`：按用户安装；UAC 由壳的 `requireAdministrator` 清单统一请求，Inno 继承管理员令牌，自身不再弹 UAC；
- `UsePreviousAppDir=yes`：升级沿用旧目录；
- `[Run]` 的「立即运行」带 `skipifsilent`：静默安装不会自动拉起应用；壳在完成页提供「打开 NarrChat」按钮，由用户决定何时启动；
- 卸载仍由 Inno 生成的 `Uninstall NarrChat.exe` 负责，壳不重复写卸载项。

### 4. 进度与日志

Inno 静默模式**没有进度回调**，所以壳不显示假百分比：

- 安装中显示 Spinner、已运行秒数和可选日志尾部；
- 壳先找一个可写工作目录（`%LOCALAPPDATA%\NarrChat\setup-work` → `%TEMP%\NarrChatSetup`），日志写在该目录的 `install.log`；**不会在安装包所在目录创建任何文件或文件夹**；
- 内嵌安装包在壳启动、界面出现前释放到该工作目录；不会等点击安装后才在安装包旁边解压；
- **同一个目录会作为 Inno 进程的 `TEMP`/`TMP`**：Inno 初始化时必须在临时目录里创建 `is-*.tmp`，部分环境（权限/安全软件）会拒绝这一步，直接表现为退出码 1 且没有日志。壳自己先探测可写目录，避免这个问题；
- 日志按 UTF-8/UTF-16 读取；失败时显示 Inno 退出码和日志目录。

### 5. 升级和关闭

- 升级时安装路径只读；快捷方式不再显示成“点不动的复选框”，而是显示上次的选择摘要（例如「桌面 无 · 开始菜单 有」）；
- 壳 exe 带 `requireAdministrator` 清单，**启动时统一请求一次 UAC**；Inno 继承管理员权限，不再二次提权，避免连续两次签名/授权提示；
- Inno 仍显式收到 `/DIR` 和 `/TASKS`，不会因为管理员上下文变化而装错位置或丢快捷方式；
- 全新安装才显示「桌面快捷方式 / 开始菜单快捷方式」两个可勾选项；
- 安装进行中关闭窗口会被 `ViewportCommand::CancelClose` 取消；安装完成后才能关闭；
- 安装失败后「重试」回到选项页；安装包缺失时回到欢迎页重新选择。

## 排障

- **退出码 1，日志文件不存在**：Inno 初始化失败，最常见是它在 `TEMP` 下创建 `is-*.tmp` 被拒（错误 5）。先看壳是否把 TEMP/TMP 指到了可写工作目录；再检查安全软件是否拦了临时目录创建。
- **退出码 5，日志里有 `Trying to create file ... unins000.exe ... 拒绝访问`**：安装器启动时已经请求管理员权限；如果仍失败，确认 NarrChat 没在运行、目标目录的旧卸载器没有被安全软件锁定，或换一个可写目录。
- **界面没有滚动/按钮被裁**：窗口固定 720×640，正常情况下错误态也能放下；如果系统缩放特别大，先确认显示缩放，再考虑改窗口尺寸。

## 构建

### 环境

- Rust stable（`rustup default stable-x86_64-pc-windows-msvc`）；
- Visual Studio Build Tools 的「使用 C++ 的桌面开发」和 Windows SDK；
- 构建 Inno 原始安装包用 Inno Setup 6（见 [`README.md`](../README.md) 的「构建」）。

### 一键构建

```powershell
dart run tool/build_release.dart --windows
```

现在 `--windows` 会：

1. `flutter build windows`；
2. 打 ZIP 便携包；
3. Inno 生成原始安装包 `build/release/NarrChatSetupPayload.exe`；
4. 复制到 `installer_windows/payload/narrchat-setup.exe`；
5. `cargo build --release` 把 payload 内嵌进 Rust 壳；
6. 输出最终 `build/release/NarrChat_{version}-{build}_windows_x64-setup.exe`。

细节：

- 未装 Inno Setup：只产出 ZIP；
- 未装 cargo：回退为原始 Inno `setup.exe`，并给出警告；
- `installer_windows/payload/narrchat-setup.exe` 会保留（已被 gitignore），方便调试或做 sidecar；
- 构建脚本不自动签名。发布前至少签最终壳；要让内嵌的 Inno 也带签名，需要在嵌入之前签原始安装包（手动，或后续给构建脚本加签名步骤）。

### 开发预览

先跑一次 Windows 构建拿到原始 payload，然后：

```powershell
cd installer_windows
cargo run --release -- --setup payload\narrchat-setup.exe
```

不点「开始安装」就是纯 UI 预览；`--setup` 只影响壳的预检和后续启动的安装器。
没有 payload 时直接 `cargo run --release` 会显示「未找到安装包」的提示。

### 手动 sidecar

不想内嵌时，壳和原始 Inno 安装包放同一个文件夹即可，壳会优先找 sidecar：

```
NarrChatSetup.exe      # 壳（改名后签名）
narrchat-setup.exe     # Inno 原始安装包（签名）
```

sidecar 不在运行时写 exe，受限环境最稳；代价是分发两个文件。最终壳和 Inno 都建议签名，最好同一张证书。

## 有意不做的事

1. **不重写安装/卸载引擎**：文件复制、快捷方式、卸载注册、升级覆盖全交给 Inno。
2. **不做自定义卸载 UI**：卸载仍走 Inno 的 `Uninstall NarrChat.exe`；给壳加卸载页收益低、坑多。
3. **不做 per-machine 安装**：当前 `PrivilegesRequired=lowest` 的按用户安装最稳；要装到 `Program Files` 得重新设计提权流程。
4. **不做下载式安装**：壳不负责下载 setup；安装包要么内嵌，要么 sidecar。更新仍走应用内更新流程。
5. **不伪造进度**：Inno 静默模式没有进度回调，壳只用 Spinner + 日志，不显示假百分比。
6. **不引入 Electron/WebView2/Tauri**：安装器壳不该依赖另一个运行时；egui 的纯 Rust 编译产物足够。

## 测试清单

- `cd installer_windows && cargo test`：Inno 参数、升级参数、目录校验；
- 干净 Windows 10/11 虚拟机：全新安装、升级安装、取消 UAC、用非管理员账户配合管理员凭据；
- 运行中安装：壳应拦住，退出 NarrChat 后能继续；
- 中文路径、带空格路径、长路径；
- 100%/125%/150%/200% DPI、浅色/深色、高对比度；
- 安装包缺失、安装包损坏、Inno 返回失败：错误提示、退出码、日志入口；
- 杀软/ SmartScreen：壳和安装包都已签名；
- 安装完成后点击「打开 NarrChat」；卸载后用户数据仍在用户「文档」目录下的 `NarrChat`。

## 后续可做

- 单实例互斥，避免同时开两个壳；
- 把壳的签名步骤接进 `tool/build_release.dart`，自动签壳/签内嵌 Inno；
- 需要更细进度时，在 Inno 侧用自定义进度页，或解析 `/LOG`（脆弱，不优先）；
- 如果确实需要完全自由布局/动画，再评估自定义 bootstrapper；当前壳已经覆盖品牌化安装器的需求。

