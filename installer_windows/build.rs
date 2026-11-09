//! 把 `payload/narrchat-setup.exe` 嵌进壳里；没有 payload 时改用 sidecar。
//!
//! 发布构建前把 Inno 产物复制到 `payload/narrchat-setup.exe`，
//! 壳就会变成单文件；开发时可以不放，直接用 `--setup` 或同目录 sidecar。

use std::env;
use std::fs;
use std::path::{Path, PathBuf};

fn main() {
    println!("cargo:rerun-if-changed=payload/narrchat-setup.exe");
    println!("cargo:rerun-if-changed=payload");
    println!("cargo:rerun-if-changed=../release.yaml");
    println!("cargo:rerun-if-changed=assets/app_icon.ico");
    println!("cargo:rerun-if-env-changed=NARRCHAT_APP_VERSION");

    let app_version = env::var("NARRCHAT_APP_VERSION")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .or_else(read_release_version);
    let version = app_version
        .unwrap_or_else(|| env::var("CARGO_PKG_VERSION").unwrap_or_else(|_| "0.0.0".to_owned()));
    println!("cargo:rustc-env=NARRCHAT_APP_VERSION={version}");

    let out_dir = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR 缺失"));
    let payload = Path::new("payload/narrchat-setup.exe");
    let generated = if payload.exists() {
        let absolute = fs::canonicalize(payload).expect("读取 payload 路径失败");
        format!(
            "pub static EMBEDDED_SETUP: Option<&[u8]> = Some(include_bytes!({:?}));\n",
            absolute.to_string_lossy()
        )
    } else {
        "pub static EMBEDDED_SETUP: Option<&[u8]> = None;\n".to_owned()
    };

    fs::write(out_dir.join("embedded_setup.rs"), generated).expect("写入 embedded_setup.rs 失败");

    embed_windows_resources(&version);
}

#[cfg(windows)]
fn embed_windows_resources(version: &str) {
    let fixed = windows_version(version);
    let mut res = winresource::WindowsResource::new();
    res.set_icon("assets/app_icon.ico")
        .set("ProductName", "NarrChat")
        .set("FileDescription", "NarrChat 安装程序")
        .set("CompanyName", "NarrChat")
        .set("FileVersion", &fixed)
        .set("ProductVersion", version)
        .set("OriginalFilename", "NarrChatSetup.exe")
        .set("LegalCopyright", "Copyright © NarrChat")
        .set_version_info(winresource::VersionInfo::FILEVERSION, version_u64(version))
        .set_version_info(
            winresource::VersionInfo::PRODUCTVERSION,
            version_u64(version),
        )
        .set_language(0x0804); // 简体中文
    if let Err(error) = res.compile() {
        panic!("Windows 资源编译失败：{error}");
    }
}

#[cfg(not(windows))]
fn embed_windows_resources(_version: &str) {}

/// `2.5.2` / `2.5.2-rc.1` → `2.5.2.0`，供 VERSIONINFO 的字符串字段。
#[cfg(windows)]
fn windows_version(version: &str) -> String {
    let mut parts = version
        .split('-')
        .next()
        .unwrap_or(version)
        .split('.')
        .map(|part| part.parse::<u16>().unwrap_or(0))
        .collect::<Vec<_>>();
    parts.resize(4, 0);
    parts[..4]
        .iter()
        .map(|value| value.to_string())
        .collect::<Vec<_>>()
        .join(".")
}

/// VERSIONINFO 的固定版本字段是 4 个 16 位整数拼成的 u64。
#[cfg(windows)]
fn version_u64(version: &str) -> u64 {
    let mut parts = version
        .split('-')
        .next()
        .unwrap_or(version)
        .split('.')
        .map(|part| part.parse::<u64>().unwrap_or(0).min(u16::MAX as u64))
        .collect::<Vec<_>>();
    parts.resize(4, 0);
    (parts[0] << 48) | (parts[1] << 32) | (parts[2] << 16) | parts[3]
}

/// 从仓库根目录的 `release.yaml` 读版本号；读不到就交给 Cargo 包版本兜底。
fn read_release_version() -> Option<String> {
    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").ok()?);
    let raw = fs::read_to_string(manifest_dir.parent()?.join("release.yaml")).ok()?;
    raw.lines().find_map(|line| {
        let line = line.trim();
        let value = line.strip_prefix("version:")?;
        let value = value.trim();
        (!value.is_empty()).then(|| value.to_owned())
    })
}
