# NarrChat Windows 安装器壳

Rust + egui 的薄壳：只做界面、选项和流程编排，真正的安装/卸载仍由 Inno Setup 完成。

完整设计、参数和发布流程见 [`../docs/installer-rust-windows.md`](../docs/installer-rust-windows.md)。

## 开发

```bash
rustup default stable-x86_64-pc-windows-msvc
# 需要 Visual Studio Build Tools 的“使用 C++ 的桌面开发”和 Windows SDK
cargo test
cargo build --release
```

开发时可以先跑一次 `dart run tool/build_release.dart --windows`，它会生成
`installer_windows/payload/narrchat-setup.exe`（Inno 原始安装包）；再预览：

```powershell
cargo run --release -- --setup payload\narrchat-setup.exe
```

`--release` 的壳带管理员清单，运行时会弹 UAC；调试预览用 `cargo run -- --setup payload\narrchat-setup.exe`（debug 不带清单，不弹 UAC）。

也可以把任意 Inno 安装包命名为 `narrchat-setup.exe` 放到壳的同目录；壳会自动找 sidecar。

## 发布

默认走 [`tool/build_release.dart`](../tool/build_release.dart) 的 `--windows`：
它会先清理 Flutter 缓存（`--no-clean` 跳过），再构建 Flutter → 生成 Inno 原始安装包 →
放进 `payload/` → `cargo build --release` 把安装包内嵌进壳 →
输出项目根目录下的 `release/NarrChat_{version}-{build}_windows_x64-setup.exe`。

`payload/narrchat-setup.exe` 会保留（已被 gitignore），方便调试或做 sidecar；最终发布只需要壳。

壳用静态 CRT（[`.cargo/config.toml`](.cargo/config.toml) 的 `+crt-static`），
最终 `setup.exe` 不依赖用户安装 VC++ 运行库；主程序目录的 VC++ 运行库 DLL
由构建脚本自动复制，ZIP 和安装包都会带上。

壳 exe 带 `requireAdministrator` 清单，启动时统一请求一次 UAC；Inno 继承管理员权限，不再二次提权。安装临时目录只使用 `%LOCALAPPDATA%` / `%TEMP%`，不会在安装包所在目录创建文件。

签名顺序：如果只签最终壳，内嵌的 Inno 原始安装包本身仍未签名；要让内嵌安装包也带签名，
需要在构建脚本嵌入之前先签 Inno（当前脚本不自动签名，手动做或后续加签名步骤）。

`payload/*.exe` 已在 `.gitignore` 中忽略，不要提交安装包。

## 目录

```
.cargo/config.toml  静态 CRT（+crt-static）
src/main.rs       入口、窗口、命令行
src/app.rs        状态机（欢迎/选项/安装/完成/失败）
src/ui.rs         页面布局
src/theme.rs      明暗配色与控件样式
src/installer.rs  Inno 参数、进程、日志、注册表
assets/icon.png   窗口图标
assets/app_icon.ico  exe 文件图标
payload/          内嵌安装包（可选）
build.rs          版本注入 + 可选 payload 内嵌 + Windows 资源
```
