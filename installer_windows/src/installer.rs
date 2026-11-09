//! Inno Setup 薄壳：找安装包、拼参数、启动/等待安装、读日志、启动应用。
//!
//! 安装本身完全交给 Inno；这里只做壳该做的事，不重写文件复制和卸载逻辑。

use std::ffi::OsString;
use std::fs;
use std::path::{Component, Path, PathBuf};
use std::process::{Child, Command};
use std::time::{Duration, Instant};

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

/// 安装选项；安装目录和快捷方式由调用方先确定。
#[derive(Debug, Clone)]
pub struct InstallOptions {
    pub install_dir: PathBuf,
    pub desktop_shortcut: bool,
    pub start_menu_shortcut: bool,
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
    pub selected_tasks: String,
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

    pub fn log_path(&self) -> &Path {
        &self.log_path
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
    let selected_tasks: String = key
        .get_value("Inno Setup: Selected Tasks")
        .unwrap_or_default();
    Some(InstalledApp {
        dir: PathBuf::from(dir),
        version,
        selected_tasks,
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

/// 清理用户输入的安装目录：去掉首尾空白，避免和 Inno 实际创建的目录只差一个空格。
pub fn normalize_install_dir(input: &str) -> PathBuf {
    PathBuf::from(input.trim())
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

/// 拼 Inno 命令行。升级也显式传 `/DIR` 和 `/TASKS`：
/// 管理员授权后进程可能处于另一个用户上下文，不能只依赖 Inno 自己记住上次选择。
///
/// - `/SP-` 关掉 SetupLdr 的“This will install...”启动确认框；`/VERYSILENT`
///   本身不会关它，干净虚拟机上很容易卡在这里。
/// - 不再传 `/SUPPRESSMSGBOXES`：安装成功仍然全静默，初始化失败时让 Inno
///   把真实错误弹出来，而不是只剩一个退出码 1。
/// - 路径没有空格时保持原样（和已验证可用的命令一致），有空格才加引号。
pub fn build_args(options: &InstallOptions, log_path: &Path) -> Vec<OsString> {
    let mut args: Vec<OsString> = vec!["/SP-".into(), "/VERYSILENT".into(), "/NORESTART".into()];
    args.push(format!("/DIR={}", quote_if_needed(&options.install_dir)).into());
    args.push(format!("/TASKS={}", options.tasks()).into());
    args.push(format!("/LOG={}", quote_if_needed(log_path)).into());
    args
}

fn quote_if_needed(path: &Path) -> String {
    let value = path.display().to_string();
    if value.chars().any(char::is_whitespace) {
        format!("\"{value}\"")
    } else {
        value
    }
}

/// 找一个可写的安装临时目录：本地应用数据 → %TEMP%。
///
/// 只使用用户数据/临时目录，**绝不在安装包所在目录创建文件夹或文件**。
/// 内嵌 payload 和 `install.log` 放在这里；Inno 自己使用系统临时目录。
pub fn prepare_work_dir() -> Result<PathBuf, String> {
    let mut candidates = Vec::new();
    if let Some(local) = std::env::var_os("LOCALAPPDATA") {
        candidates.push(PathBuf::from(local).join("NarrChat").join("setup-work"));
    }
    candidates.push(std::env::temp_dir().join("NarrChatSetup"));

    let mut failures = Vec::new();
    for dir in candidates {
        if let Err(error) = fs::create_dir_all(&dir) {
            failures.push(format!("{}（{error}）", dir.display()));
            continue;
        }
        let probe_dir = dir.join(format!(".probe-{}", std::process::id()));
        let probe_file = probe_dir.join("write-test");
        let result = fs::create_dir_all(&probe_dir)
            .and_then(|()| fs::write(&probe_file, b"ok"))
            .and_then(|()| fs::remove_file(&probe_file))
            .and_then(|()| fs::remove_dir(&probe_dir));
        match result {
            Ok(()) => return Ok(dir),
            Err(error) => failures.push(format!("{}（{error}）", dir.display())),
        }
    }

    Err(format!(
        "找不到可写的安装临时目录，已尝试：{}",
        failures.join("；")
    ))
}

/// 启动 Inno；安装日志和工作目录都在 [prepare_work_dir] 选出的目录里。
///
/// 壳的 exe 清单已经 `requireAdministrator`，启动时只弹一次 UAC；
/// 这里直接 `spawn`，Inno 继承管理员令牌，不会再二次提权。
pub fn start_install(setup: &Path, options: &InstallOptions) -> Result<InstallSession, String> {
    let work_dir = prepare_work_dir()?;
    let log_path = work_dir.join("install.log");
    let _ = fs::remove_file(&log_path);

    let mut command = Command::new(setup);
    command.args(build_args(options, &log_path));
    // 不再强制把 TEMP/TMP 指到用户目录：干净虚拟机/管理员上下文里，自定义
    // 临时目录可能不可写，Inno 会直接退出 1 且没有日志。让 Inno 用系统临时
    // 目录；壳自己的 payload 和日志仍放在 work_dir。
    let child = command
        .spawn()
        .map_err(|error| format!("无法启动 Inno 安装程序：{error}"))?;

    Ok(InstallSession {
        child,
        log_path,
        started: Instant::now(),
    })
}

/// 从 Inno 安装日志里找实际写入 `narrchat.exe` 的目录（取最后一次）。
///
/// 管理员上下文、旧安装记录或杀软干预都可能让实际目录和壳里选的目录不同，
/// 日志里的 `Dest filename` 是 Inno 真正写盘的位置，比任何推测都可靠。
pub fn install_dir_from_log(log_path: &Path) -> Option<PathBuf> {
    let text = read_log_text(log_path);
    let mut found = None;
    for line in text.lines() {
        let Some((_, rest)) = line.split_once("Dest filename:") else {
            continue;
        };
        let path_text = rest.trim().trim_matches('"');
        let path = Path::new(path_text);
        let is_app = path
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name.eq_ignore_ascii_case(APP_EXE));
        if is_app {
            if let Some(parent) = path.parent() {
                found = Some(parent.to_path_buf());
            }
        }
    }
    found
}

/// 等主程序出现；杀软扫描或文件系统延迟时，Inno 退出后文件可能晚一点可见。
pub fn wait_for_app(dir: &Path, timeout: Duration) -> bool {
    let exe = dir.join(APP_EXE);
    let deadline = Instant::now() + timeout;
    loop {
        if exe.is_file() {
            return true;
        }
        if Instant::now() >= deadline {
            return false;
        }
        std::thread::sleep(Duration::from_millis(200));
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
    let exe = std::env::current_exe().ok()?;
    let exe_dir = exe.parent()?;
    let dev_payload = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("payload")
        .join("narrchat-setup.exe");
    find_sidecar_in(exe_dir, &exe, Some(&dev_payload))
}

/// 查找同目录的 Inno 原始安装包。
///
/// 只认明确的 Inno payload 名字；**不能**把 `NarrChat_*_windows_x64-setup.exe`
/// 这类最终壳当成 sidecar，否则壳会启动自己，子进程遇到未知参数直接返回 0，
/// 父进程就会误以为 Inno 安装成功。
fn find_sidecar_in(
    exe_dir: &Path,
    current_exe: &Path,
    dev_payload: Option<&Path>,
) -> Option<PathBuf> {
    let mut candidates = vec![
        exe_dir.join("narrchat-setup.exe"),
        exe_dir.join("NarrChatSetup.exe"),
        exe_dir.join("NarrChatSetupPayload.exe"),
    ];
    if let Some(path) = dev_payload {
        if path.is_file() {
            candidates.push(path.to_path_buf());
        }
    }

    candidates
        .into_iter()
        .find(|path| path.is_file() && !same_file(path, current_exe))
}

/// 判断两个路径是否指向同一个文件（Windows 大小写不敏感）。
fn same_file(a: &Path, b: &Path) -> bool {
    fn canonical(path: &Path) -> Option<String> {
        fs::canonicalize(path)
            .ok()
            .map(|path| path.to_string_lossy().to_lowercase())
    }
    match (canonical(a), canonical(b)) {
        (Some(a), Some(b)) => a == b,
        _ => false,
    }
}

fn materialize_embedded(bytes: &[u8]) -> Result<PathBuf, String> {
    if bytes.is_empty() {
        return Err("内嵌安装包为空".to_owned());
    }

    let work_dir = prepare_work_dir()?;
    let path = work_dir.join(format!("NarrChatSetup-{}.exe", std::process::id()));
    fs::write(&path, bytes)
        .map_err(|error| format!("写出内嵌安装包失败（{}）：{error}", path.display()))?;
    Ok(path)
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

    fn options() -> InstallOptions {
        InstallOptions {
            install_dir: PathBuf::from(r"C:\Users\Test\NarrChat"),
            desktop_shortcut: true,
            start_menu_shortcut: false,
        }
    }

    #[test]
    fn fresh_install_passes_dir_and_tasks() {
        let args: Vec<String> = build_args(&options(), Path::new(r"C:\Temp\install.log"))
            .into_iter()
            .map(|value| value.to_string_lossy().into_owned())
            .collect();
        assert!(args.contains(&"/SP-".to_owned()));
        assert!(args.contains(&"/VERYSILENT".to_owned()));
        assert!(!args.contains(&"/SUPPRESSMSGBOXES".to_owned()));
        assert!(args.contains(&r"/DIR=C:\Users\Test\NarrChat".to_owned()));
        assert!(args.contains(&"/TASKS=desktopicon".to_owned()));
        assert!(args.contains(&r"/LOG=C:\Temp\install.log".to_owned()));
    }

    #[test]
    fn upgrade_passes_known_dir_and_tasks() {
        let args: Vec<String> = build_args(&options(), Path::new(r"C:\Temp\install.log"))
            .into_iter()
            .map(|value| value.to_string_lossy().into_owned())
            .collect();
        assert!(args.contains(&r"/DIR=C:\Users\Test\NarrChat".to_owned()));
        assert!(args.contains(&"/TASKS=desktopicon".to_owned()));
        assert!(args.contains(&r"/LOG=C:\Temp\install.log".to_owned()));
    }

    #[test]
    fn paths_with_spaces_are_quoted() {
        let mut value = options();
        value.install_dir = PathBuf::from(r"C:\Program Files\NarrChat");
        let args: Vec<String> = build_args(&value, Path::new(r"C:\Users\Test User\install.log"))
            .into_iter()
            .map(|arg| arg.to_string_lossy().into_owned())
            .collect();
        assert!(args.contains(&"/DIR=\"C:\\Program Files\\NarrChat\"".to_owned()));
        assert!(args.contains(&"/LOG=\"C:\\Users\\Test User\\install.log\"".to_owned()));
    }

    #[test]
    fn tasks_are_joined_with_comma() {
        let mut value = options();
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

    #[test]
    fn install_dir_input_is_trimmed() {
        assert_eq!(
            normalize_install_dir("  C:\\Users\\Test\\NarrChat  "),
            PathBuf::from(r"C:\Users\Test\NarrChat")
        );
    }

    fn test_dir(name: &str) -> PathBuf {
        let dir = std::env::current_dir()
            .unwrap()
            .join("target")
            .join("test-tmp")
            .join(name);
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn sidecar_skips_current_exe() {
        let dir = test_dir("sidecar-self");
        let current = dir.join("narrchat-setup.exe");
        fs::write(&current, b"shell").unwrap();
        assert_eq!(find_sidecar_in(&dir, &current, None), None);

        let payload = dir.join("NarrChatSetupPayload.exe");
        fs::write(&payload, b"inno").unwrap();
        assert_eq!(find_sidecar_in(&dir, &current, None), Some(payload));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn final_setup_name_is_not_sidecar() {
        let dir = test_dir("sidecar-final");
        let current = dir.join("shell.exe");
        fs::write(&current, b"shell").unwrap();
        let other = dir.join("NarrChat_3.0.0-beta.1-101_windows_x64-setup.exe");
        fs::write(&other, b"other").unwrap();
        assert_eq!(find_sidecar_in(&dir, &current, None), None);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn install_dir_from_log_uses_last_narrchat_dest() {
        let dir = test_dir("install-log");
        let path = dir.join("install.log");
        fs::write(
            &path,
            "Dest filename: C:\\Old\\NarrChat\\narrchat.exe\r\n\
             Dest filename: C:\\Users\\Test\\NarrChat\\narrchat.exe\r\n\
             Dest filename: C:\\Users\\Test\\NarrChat\\data\\app.so\r\n",
        )
        .unwrap();

        assert_eq!(
            install_dir_from_log(&path),
            Some(PathBuf::from(r"C:\Users\Test\NarrChat"))
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn wait_for_app_detects_file_and_timeout() {
        let dir = test_dir("wait-app");
        assert!(!wait_for_app(&dir, Duration::from_millis(0)));
        fs::write(dir.join(APP_EXE), b"fake").unwrap();
        assert!(wait_for_app(&dir, Duration::from_millis(10)));
        let _ = fs::remove_dir_all(&dir);
    }
}
