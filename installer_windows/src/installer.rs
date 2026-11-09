//! Inno Setup 薄壳：找安装包、拼参数、启动/等待安装、读日志、启动应用。
//!
//! 安装本身完全交给 Inno；这里只做壳该做的事，不重写文件复制和卸载逻辑。

use std::ffi::OsString;
use std::fs;
use std::path::{Component, Path, PathBuf};
use std::process::{Child, Command};
use std::time::Instant;

use winreg::enums::HKEY_CURRENT_USER;
use winreg::RegKey;

#[cfg(windows)]
use std::os::windows::process::CommandExt;

mod embedded {
    include!(concat!(env!("OUT_DIR"), "/embedded_setup.rs"));
}

/// 主应用 exe 名。
pub const APP_EXE: &str = "narrchat.exe";

/// Inno 卸载键（与 `tool/build_release.dart` 的 AppId 对应）。
pub const UNINSTALL_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Uninstall\{8F2E1A3C-5B6D-4E7F-9A8B-0C1D2E3F4A5B}_is1";

/// 安装选项；升级时目录和快捷方式沿用旧安装。
#[derive(Debug, Clone)]
pub struct InstallOptions {
    pub install_dir: PathBuf,
    pub desktop_shortcut: bool,
    pub start_menu_shortcut: bool,
    pub upgrade: bool,
}

impl InstallOptions {
    /// Inno `[Tasks]` 里的任务名，逗号分隔。
    pub fn tasks(&self) -> String {
        let mut tasks = Vec::new();
        if self.desktop_shortcut {
            tasks.push("desktopicon");
        }
        if self.start_menu_shortcut {
            tasks.push("startmenuicon");
        }
        tasks.join(",")
    }
}

/// 已安装实例（从 HKCU 卸载键读）。
#[derive(Debug, Clone)]
pub struct InstalledApp {
    pub dir: PathBuf,
    pub version: String,
}

/// 一次已经启动的安装。
pub struct InstallSession {
    child: Child,
    log_path: PathBuf,
    started: Instant,
}

/// 安装进程的结束结果。
#[derive(Debug, Clone, Copy)]
pub struct InstallOutcome {
    pub success: bool,
    pub code: Option<i32>,
}

impl InstallSession {
    /// 非阻塞查询；返回 `None` 表示仍在运行。
    pub fn poll(&mut self) -> Result<Option<InstallOutcome>, String> {
        match self.child.try_wait() {
            Ok(None) => Ok(None),
            Ok(Some(status)) => Ok(Some(InstallOutcome {
                success: status.success(),
                code: status.code(),
            })),
            Err(error) => Err(format!("无法读取安装进程状态：{error}")),
        }
    }

    /// 最近的安装日志（尾部若干行）。
    pub fn log_tail(&self, max_lines: usize) -> String {
        let text = read_log_text(&self.log_path);
        let lines: Vec<&str> = text.lines().collect();
        let start = lines.len().saturating_sub(max_lines);
        lines[start..].join("\n")
    }

    pub fn elapsed_secs(&self) -> u64 {
        self.started.elapsed().as_secs()
    }
}

/// 应用版本：优先用构建时注入的 `NARRCHAT_APP_VERSION`，否则用壳自己的版本。
pub fn app_version() -> &'static str {
    option_env!("NARRCHAT_APP_VERSION")
        .filter(|value| !value.is_empty())
        .unwrap_or(env!("CARGO_PKG_VERSION"))
}

/// 默认安装目录：`%LOCALAPPDATA%\Programs\NarrChat`。
pub fn default_install_dir() -> PathBuf {
    let local = std::env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(r"C:\Users\Public"));
    local.join("Programs").join("NarrChat")
}

/// 读已安装实例；读不到就当全新安装。
pub fn installed_app() -> Option<InstalledApp> {
    let hkcu = RegKey::predef(HKEY_CURRENT_USER);
    let key = hkcu.open_subkey(UNINSTALL_KEY).ok()?;
    let dir: String = key.get_value("Inno Setup: App Path").ok()?;
    if dir.trim().is_empty() {
        return None;
    }
    let version: String = key.get_value("DisplayVersion").unwrap_or_default();
    Some(InstalledApp {
        dir: PathBuf::from(dir),
        version,
    })
}

/// 系统是否偏好深色（读 Windows 个性化设置）。
pub fn system_prefers_dark() -> bool {
    let hkcu = RegKey::predef(HKEY_CURRENT_USER);
    let Ok(key) = hkcu.open_subkey(r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize")
    else {
        return false;
    };
    let light: u32 = key.get_value("AppsUseLightTheme").unwrap_or(1);
    light == 0
}

/// 是否有 NarrChat 正在运行。安装前挡住，避免覆盖运行中的文件。
pub fn is_app_running() -> bool {
    #[cfg(windows)]
    {
        let mut command = Command::new("tasklist");
        command.args(["/FI", "IMAGENAME eq narrchat.exe", "/NH"]);
        command.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
        let Ok(output) = command.output() else {
            return false;
        };
        String::from_utf8_lossy(&output.stdout)
            .to_ascii_lowercase()
            .contains(APP_EXE)
    }
    #[cfg(not(windows))]
    {
        false
    }
}

/// 校验收到的安装目录：绝对路径、非根目录、不含 `..`、不是已有文件。
pub fn validate_install_dir(path: &Path) -> Result<(), String> {
    if path.as_os_str().is_empty() {
        return Err("安装目录不能为空".to_owned());
    }
    if !path.is_absolute() {
        return Err("安装目录必须是绝对路径".to_owned());
    }
    if path
        .components()
        .any(|component| matches!(component, Component::ParentDir))
    {
        return Err("安装目录不能包含 ..".to_owned());
    }
    if path.parent().is_none() {
        return Err("不能直接安装到盘符根目录".to_owned());
    }
    if path.exists() && !path.is_dir() {
        return Err("目标路径已经存在且不是文件夹".to_owned());
    }
    Ok(())
}

/// 找 Inno 安装包：`--setup` → 环境变量 → 同目录 sidecar → 内嵌 payload。
pub fn prepare_setup(explicit: Option<&Path>) -> Result<PathBuf, String> {
    if let Some(path) = explicit {
        return ensure_exe(&absolute(path)?, "命令行 --setup");
    }
    if let Some(path) = std::env::var_os("NARRCHAT_INNO_SETUP") {
        return ensure_exe(&absolute(Path::new(&path))?, "环境变量 NARRCHAT_INNO_SETUP");
    }
    if let Some(path) = find_sidecar() {
        return Ok(path);
    }
    if let Some(bytes) = embedded::EMBEDDED_SETUP {
        return materialize_embedded(bytes);
    }
    Err(
        "未找到 Inno 安装包。请把安装包命名为 narrchat-setup.exe 放到壳的同目录，\
         或用 --setup 指定；发布构建也可以把安装包放到 \
         installer_windows/payload/narrchat-setup.exe 后重新编译。"
            .to_owned(),
    )
}

/// 拼 Inno 命令行。升级时不传 `/DIR` 和 `/TASKS`，让 Inno 沿用上次的选择。
pub fn build_args(options: &InstallOptions, log_path: &Path) -> Vec<OsString> {
    let mut args: Vec<OsString> = vec![
        "/VERYSILENT".into(),
        "/SUPPRESSMSGBOXES".into(),
        "/NORESTART".into(),
    ];
    if !options.upgrade {
        args.push(format!("/DIR={}", options.install_dir.display()).into());
        args.push(format!("/TASKS={}", options.tasks()).into());
    }
    args.push(format!("/LOG={}", log_path.display()).into());
    args
}

/// 启动 Inno；安装日志写到 `%TEMP%\NarrChatSetup\install.log`。
pub fn start_install(
    setup: &Path,
    options: &InstallOptions,
    log_path: &Path,
) -> Result<InstallSession, String> {
    if let Some(parent) = log_path.parent() {
        fs::create_dir_all(parent).map_err(|error| format!("创建日志目录失败：{error}"))?;
        let _ = fs::remove_file(log_path);
    }

    let mut command = Command::new(setup);
    command.args(build_args(options, log_path));
    let child = command
        .spawn()
        .map_err(|error| format!("无法启动 Inno 安装程序：{error}"))?;

    Ok(InstallSession {
        child,
        log_path: log_path.to_path_buf(),
        started: Instant::now(),
    })
}

/// 安装日志路径。`%TEMP%\NarrChatSetup` 建不出来时退回 `%TEMP%` 下的单文件。
pub fn new_log_path() -> PathBuf {
    let dir = std::env::temp_dir().join("NarrChatSetup");
    if fs::create_dir_all(&dir).is_ok() {
        dir.join("install.log")
    } else {
        std::env::temp_dir().join("NarrChat-install.log")
    }
}

/// 启动安装好的应用。
pub fn launch_app(dir: &Path) -> Result<(), String> {
    let exe = dir.join(APP_EXE);
    if !exe.is_file() {
        return Err(format!("找不到 {}，安装可能没有完成。", exe.display()));
    }
    Command::new(&exe)
        .current_dir(dir)
        .spawn()
        .map_err(|error| format!("启动 NarrChat 失败：{error}"))?;
    Ok(())
}

/// 用资源管理器打开目录。
pub fn open_dir(dir: &Path) -> Result<(), String> {
    if !dir.exists() {
        return Err(format!("目录不存在：{}", dir.display()));
    }
    Command::new("explorer")
        .arg(dir)
        .spawn()
        .map_err(|error| format!("打开目录失败：{error}"))?;
    Ok(())
}

/// 用资源管理器打开日志所在目录。
pub fn open_log_dir(log_path: &Path) -> Result<(), String> {
    if let Some(parent) = log_path.parent() {
        open_dir(parent)
    } else {
        Err("日志路径没有父目录".to_owned())
    }
}

fn absolute(path: &Path) -> Result<PathBuf, String> {
    if path.is_absolute() {
        Ok(path.to_path_buf())
    } else {
        std::env::current_dir()
            .map(|dir| dir.join(path))
            .map_err(|error| format!("解析相对路径失败：{error}"))
    }
}

fn ensure_exe(path: &Path, source: &str) -> Result<PathBuf, String> {
    if !path.is_file() {
        return Err(format!("{source} 指向的安装包不存在：{}", path.display()));
    }
    let is_exe = path
        .extension()
        .and_then(|value| value.to_str())
        .is_some_and(|value| value.eq_ignore_ascii_case("exe"));
    if !is_exe {
        return Err(format!("{source} 必须指向 .exe：{}", path.display()));
    }
    Ok(path.to_path_buf())
}

fn find_sidecar() -> Option<PathBuf> {
    let exe_dir = std::env::current_exe().ok()?.parent()?.to_path_buf();
    let mut candidates = vec![
        exe_dir.join("narrchat-setup.exe"),
        exe_dir.join("NarrChatSetup.exe"),
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("payload")
            .join("narrchat-setup.exe"),
    ];

    if let Ok(entries) = fs::read_dir(&exe_dir) {
        for entry in entries.flatten() {
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if name.starts_with("NarrChat_") && name.ends_with("-setup.exe") {
                candidates.push(entry.path());
            }
        }
    }

    candidates.into_iter().find(|path| path.is_file())
}

fn materialize_embedded(bytes: &[u8]) -> Result<PathBuf, String> {
    if bytes.is_empty() {
        return Err("内嵌安装包为空".to_owned());
    }

    // 依次尝试：本地应用数据目录 → %TEMP% → 壳所在目录。
    // 受限环境（安全软件/容器）可能只允许其中一处写 exe。
    let mut candidates = Vec::new();
    if let Some(local) = std::env::var_os("LOCALAPPDATA") {
        candidates.push(PathBuf::from(local).join("NarrChat").join("setup-cache"));
    }
    candidates.push(std::env::temp_dir());
    if let Ok(exe) = std::env::current_exe() {
        if let Some(parent) = exe.parent() {
            candidates.push(parent.join("NarrChat-setup-cache"));
        }
    }

    let mut failures = Vec::new();
    for dir in candidates {
        let dir_ready = fs::create_dir_all(&dir).is_ok();
        if !dir_ready {
            failures.push(format!("{}（无法创建目录）", dir.display()));
            continue;
        }
        let path = dir.join(format!("NarrChatSetup-{}.exe", std::process::id()));
        match fs::write(&path, bytes) {
            Ok(()) => return Ok(path),
            Err(error) => failures.push(format!("{}（{error}）", path.display())),
        }
    }

    Err(format!(
        "写出内嵌安装包失败，已尝试：{}。可以改用同目录 sidecar 或 --setup。",
        failures.join("；")
    ))
}

/// 安装成功后清理内嵌安装包释放出来的临时 exe；sidecar 不会被删。
pub fn cleanup_materialized(setup: &Path) {
    let Some(name) = setup.file_name().and_then(|value| value.to_str()) else {
        return;
    };
    if name.starts_with("NarrChatSetup-") && name.ends_with(".exe") {
        let _ = fs::remove_file(setup);
        if let Some(parent) = setup.parent() {
            let _ = fs::remove_dir(parent);
        }
    }
}

fn read_log_text(path: &Path) -> String {
    let Ok(bytes) = fs::read(path) else {
        return String::new();
    };
    if bytes.starts_with(&[0xFF, 0xFE]) {
        let units: Vec<u16> = bytes[2..]
            .chunks_exact(2)
            .map(|pair| u16::from_le_bytes([pair[0], pair[1]]))
            .collect();
        return String::from_utf16_lossy(&units);
    }
    if bytes.starts_with(&[0xFE, 0xFF]) {
        let units: Vec<u16> = bytes[2..]
            .chunks_exact(2)
            .map(|pair| u16::from_be_bytes([pair[0], pair[1]]))
            .collect();
        return String::from_utf16_lossy(&units);
    }
    if bytes.starts_with(&[0xEF, 0xBB, 0xBF]) {
        return String::from_utf8_lossy(&bytes[3..]).into_owned();
    }
    String::from_utf8_lossy(&bytes).into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn options(upgrade: bool) -> InstallOptions {
        InstallOptions {
            install_dir: PathBuf::from(r"C:\Users\Test\NarrChat"),
            desktop_shortcut: true,
            start_menu_shortcut: false,
            upgrade,
        }
    }

    #[test]
    fn fresh_install_passes_dir_and_tasks() {
        let args: Vec<String> = build_args(&options(false), Path::new(r"C:\Temp\install.log"))
            .into_iter()
            .map(|value| value.to_string_lossy().into_owned())
            .collect();
        assert!(args.contains(&"/VERYSILENT".to_owned()));
        assert!(args.contains(&r"/DIR=C:\Users\Test\NarrChat".to_owned()));
        assert!(args.contains(&"/TASKS=desktopicon".to_owned()));
        assert!(args.contains(&r"/LOG=C:\Temp\install.log".to_owned()));
    }

    #[test]
    fn upgrade_keeps_previous_dir_and_tasks() {
        let args: Vec<String> = build_args(&options(true), Path::new(r"C:\Temp\install.log"))
            .into_iter()
            .map(|value| value.to_string_lossy().into_owned())
            .collect();
        assert!(!args.iter().any(|value| value.starts_with("/DIR=")));
        assert!(!args.iter().any(|value| value.starts_with("/TASKS=")));
        assert!(args.contains(&"/LOG=C:\\Temp\\install.log".to_owned()));
    }

    #[test]
    fn tasks_are_joined_with_comma() {
        let mut value = options(false);
        value.start_menu_shortcut = true;
        assert_eq!(value.tasks(), "desktopicon,startmenuicon");
    }

    #[test]
    fn install_dir_must_be_absolute_and_not_root() {
        assert!(validate_install_dir(Path::new(r"C:\Users\Test\NarrChat")).is_ok());
        assert!(validate_install_dir(Path::new(r"NarrChat")).is_err());
        assert!(validate_install_dir(Path::new(r"C:\")).is_err());
        assert!(validate_install_dir(Path::new(r"C:\Users\..\NarrChat")).is_err());
    }
}
