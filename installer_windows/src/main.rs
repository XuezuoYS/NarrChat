//! NarrChat Windows 安装器薄壳。
//!
//! 只负责界面、选项和调用 Inno Setup；真正的安装/卸载逻辑在 Inno 脚本里。
//! Windows 发布构建时把 Inno 产物放到 `payload/narrchat-setup.exe`，壳会内嵌成单文件。

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod app;
mod installer;
mod theme;
mod ui;

use std::path::PathBuf;

use eframe::egui;

fn main() -> eframe::Result {
    let mut setup_arg: Option<PathBuf> = None;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--setup" => setup_arg = args.next().map(PathBuf::from),
            "--version" => {
                println!(
                    "NarrChat installer {} (target {})",
                    env!("CARGO_PKG_VERSION"),
                    installer::app_version()
                );
                return Ok(());
            }
            "--help" | "-h" => {
                print_help();
                return Ok(());
            }
            other => {
                eprintln!("未知参数：{other}");
                print_help();
                return Ok(());
            }
        }
    }

    let icon = eframe::icon_data::from_png_bytes(include_bytes!("../assets/icon.png")).ok();
    let mut viewport = egui::ViewportBuilder::default()
        .with_title("NarrChat 安装程序")
        .with_inner_size([720.0, 640.0])
        .with_minimize_button(false)
        .with_maximize_button(false)
        .with_resizable(false);
    if let Some(icon) = icon {
        viewport = viewport.with_icon(icon);
    }

    let options = eframe::NativeOptions {
        viewport,
        centered: true,
        system_font_fallback: true,
        ..Default::default()
    };

    eframe::run_native(
        "NarrChat 安装程序",
        options,
        Box::new(|cc| Ok(Box::new(app::InstallerApp::new(cc, setup_arg)))),
    )
}

fn print_help() {
    println!(
        "NarrChat 安装程序\n\
         \n\
         用法：\n\
           narrchat-installer [--setup <setup.exe>]\n\
         \n\
         说明：\n\
           --setup  指定 Inno 安装包；不指定时依次找同目录 sidecar、内嵌 payload。\n\
           --version 打印壳版本和目标版本。\n\
           --help   显示本帮助。"
    );
}
