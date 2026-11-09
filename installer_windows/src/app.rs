//! 安装器壳的状态机：欢迎 → 选项 → 安装 → 完成/失败。

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use eframe::egui;

use crate::installer::{self, InstallOptions, InstallSession};
use crate::theme;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Screen {
    Welcome,
    Options,
    Installing,
    Done,
    Failed,
}

pub struct InstallerApp {
    pub(crate) screen: Screen,
    pub(crate) dark: bool,
    pub(crate) setup_path: Option<PathBuf>,
    pub(crate) setup_error: Option<String>,
    pub(crate) installed: Option<installer::InstalledApp>,
    pub(crate) running: bool,
    pub(crate) install_dir: String,
    pub(crate) desktop_shortcut: bool,
    pub(crate) start_menu_shortcut: bool,
    pub(crate) upgrade: bool,
    pub(crate) session: Option<InstallSession>,
    pub(crate) log_tail: String,
    pub(crate) log_path: Option<PathBuf>,
    pub(crate) last_log_poll: Instant,
    pub(crate) error: Option<String>,
    pub(crate) exit_code: Option<i32>,
    pub(crate) launch_error: Option<String>,
    pub(crate) launched: bool,
    pub(crate) show_log: bool,
    pub(crate) close_hint: bool,
}

impl InstallerApp {
    pub fn new(cc: &eframe::CreationContext<'_>, setup_arg: Option<PathBuf>) -> Self {
        let (setup_path, setup_error) = match installer::prepare_setup(setup_arg.as_deref()) {
            Ok(path) => (Some(path), None),
            Err(error) => (None, Some(error)),
        };
        let installed = installer::installed_app();
        let install_dir = installed
            .as_ref()
            .map(|app| app.dir.display().to_string())
            .unwrap_or_else(|| installer::default_install_dir().display().to_string());
        let upgrade = installed.is_some();
        let (desktop_shortcut, start_menu_shortcut) = shortcut_flags(installed.as_ref());
        let dark = installer::system_prefers_dark();
        theme::apply(&cc.egui_ctx, dark);

        Self {
            screen: Screen::Welcome,
            dark,
            setup_path,
            setup_error,
            installed,
            running: installer::is_app_running(),
            install_dir,
            desktop_shortcut,
            start_menu_shortcut,
            upgrade,
            session: None,
            log_tail: String::new(),
            log_path: None,
            last_log_poll: Instant::now(),
            error: None,
            exit_code: None,
            launch_error: None,
            launched: false,
            show_log: false,
            close_hint: false,
        }
    }

    pub(crate) fn toggle_theme(&mut self, ctx: &egui::Context) {
        self.dark = !self.dark;
        theme::apply(ctx, self.dark);
    }

    pub(crate) fn close(&self, ctx: &egui::Context) {
        ctx.send_viewport_cmd(egui::ViewportCommand::Close);
    }

    pub(crate) fn rescan(&mut self) {
        self.running = installer::is_app_running();
        self.installed = installer::installed_app();
        self.upgrade = self.installed.is_some();
        let (desktop_shortcut, start_menu_shortcut) = shortcut_flags(self.installed.as_ref());
        self.desktop_shortcut = desktop_shortcut;
        self.start_menu_shortcut = start_menu_shortcut;
        if let Some(app) = &self.installed {
            self.install_dir = app.dir.display().to_string();
        }
    }

    pub(crate) fn choose_setup(&mut self) {
        let Some(path) = rfd::FileDialog::new()
            .add_filter("Inno Setup", &["exe"])
            .pick_file()
        else {
            return;
        };
        match installer::prepare_setup(Some(&path)) {
            Ok(path) => {
                self.setup_path = Some(path);
                self.setup_error = None;
            }
            Err(error) => self.setup_error = Some(error),
        }
    }

    pub(crate) fn choose_install_dir(&mut self) {
        let start = Path::new(&self.install_dir);
        let mut dialog = rfd::FileDialog::new();
        if start.is_dir() {
            dialog = dialog.set_directory(start);
        }
        if let Some(path) = dialog.pick_folder() {
            self.install_dir = path.display().to_string();
        }
    }

    pub(crate) fn begin_install(&mut self) {
        if self.running {
            self.error = Some("NarrChat 正在运行，请先退出后再安装。".to_owned());
            return;
        }
        let Some(setup) = self.setup_path.clone() else {
            self.error = Some(
                self.setup_error
                    .clone()
                    .unwrap_or_else(|| "未找到 Inno 安装包。".to_owned()),
            );
            self.screen = Screen::Failed;
            return;
        };
        let install_dir = PathBuf::from(&self.install_dir);
        if let Err(error) = installer::validate_install_dir(&install_dir) {
            self.error = Some(error);
            return;
        }

        let options = InstallOptions {
            install_dir,
            desktop_shortcut: self.desktop_shortcut,
            start_menu_shortcut: self.start_menu_shortcut,
        };

        match installer::start_install(&setup, &options) {
            Ok(session) => {
                self.log_path = Some(session.log_path().to_path_buf());
                self.session = Some(session);
                self.log_tail.clear();
                self.last_log_poll = Instant::now();
                self.error = None;
                self.exit_code = None;
                self.launch_error = None;
                self.launched = false;
                self.show_log = false;
                self.screen = Screen::Installing;
            }
            Err(error) => {
                self.error = Some(error);
                self.screen = Screen::Failed;
            }
        }
    }

    pub(crate) fn retry(&mut self) {
        self.screen = Screen::Options;
        self.session = None;
        self.error = None;
        self.exit_code = None;
        self.launch_error = None;
        self.launched = false;
        self.show_log = false;
        self.running = installer::is_app_running();
    }

    pub(crate) fn open_log(&mut self) {
        let Some(path) = self.log_path.as_ref() else {
            return;
        };
        if let Err(error) = installer::open_log_dir(path) {
            self.error = Some(error);
        }
    }

    pub(crate) fn open_install_dir(&mut self) {
        if let Err(error) = installer::open_dir(Path::new(&self.install_dir)) {
            self.error = Some(error);
        }
    }

    fn poll_install(&mut self) {
        let Some(session) = self.session.as_mut() else {
            return;
        };

        let tail = if self.last_log_poll.elapsed() >= Duration::from_millis(250) {
            Some(session.log_tail(40))
        } else {
            None
        };
        let outcome = session.poll();
        if let Some(tail) = tail {
            self.log_tail = tail;
            self.last_log_poll = Instant::now();
        }

        match outcome {
            Ok(None) => {}
            Ok(Some(result)) => {
                let tail = self
                    .session
                    .as_ref()
                    .map(|session| session.log_tail(40))
                    .unwrap_or_default();
                self.log_tail = tail;
                self.session = None;
                self.exit_code = result.code;
                if result.success {
                    self.finish_success();
                } else {
                    self.error = Some(match result.code {
                        Some(code) => format!("Inno 安装程序返回失败，退出码 {code}。"),
                        None => "Inno 安装程序返回失败。".to_owned(),
                    });
                    self.screen = Screen::Failed;
                }
            }
            Err(error) => {
                let tail = self
                    .session
                    .as_ref()
                    .map(|session| session.log_tail(40))
                    .unwrap_or_default();
                self.log_tail = tail;
                self.session = None;
                self.error = Some(error);
                self.screen = Screen::Failed;
            }
        }
    }

    fn finish_success(&mut self) {
        self.screen = Screen::Done;
        self.error = None;
        if let Some(setup) = &self.setup_path {
            installer::cleanup_materialized(setup);
        }
    }

    /// 安装成功页的「打开 NarrChat」；安装期间不再自动拉起应用。
    pub(crate) fn open_app(&mut self) {
        if self.launched {
            return;
        }
        match installer::launch_app(Path::new(&self.install_dir)) {
            Ok(()) => {
                self.launched = true;
                self.launch_error = None;
            }
            Err(error) => self.launch_error = Some(error),
        }
    }
}

fn shortcut_flags(installed: Option<&installer::InstalledApp>) -> (bool, bool) {
    let Some(app) = installed else {
        return (false, true);
    };
    let has = |name: &str| {
        app.selected_tasks
            .split(',')
            .any(|task| task.trim().eq_ignore_ascii_case(name))
    };
    (has("desktopicon"), has("startmenuicon"))
}

impl eframe::App for InstallerApp {
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        let ctx = ui.ctx().clone();
        if self.screen == Screen::Installing && ctx.input(|i| i.viewport().close_requested()) {
            ctx.send_viewport_cmd(egui::ViewportCommand::CancelClose);
            self.close_hint = true;
        }
        if self.screen == Screen::Installing {
            self.poll_install();
            ctx.request_repaint_after(Duration::from_millis(100));
        }
        self.draw(ui);
    }
}
