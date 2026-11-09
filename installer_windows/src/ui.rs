//! 安装器壳的可见界面：三到四屏，尽量少但干净。

use eframe::egui;

use crate::app::{InstallerApp, Screen};
use crate::installer;
use crate::theme::{self, Palette};

impl InstallerApp {
    pub(crate) fn draw(&mut self, root: &mut egui::Ui) {
        let ctx = root.ctx().clone();
        let p = theme::palette(self.dark);
        egui::CentralPanel::default()
            .frame(
                egui::Frame::NONE
                    .fill(p.bg)
                    .inner_margin(egui::Margin::same(20)),
            )
            .show(root, |ui| {
                ui.set_width(ui.available_width());
                self.header(ui, &p, &ctx);
                ui.add_space(16.0);

                theme::card_frame(&p).show(ui, |ui| {
                    ui.set_width(ui.available_width());
                    match self.screen {
                        Screen::Welcome => self.welcome(ui, &p, &ctx),
                        Screen::Options => self.options(ui, &p),
                        Screen::Installing => self.installing(ui, &p),
                        Screen::Done => self.done(ui, &p),
                        Screen::Failed => self.failed(ui, &p),
                    }
                });

                ui.add_space(12.0);
                self.footer(ui, &p);
            });
    }

    fn header(&mut self, ui: &mut egui::Ui, p: &Palette, ctx: &egui::Context) {
        ui.horizontal(|ui| {
            brand_mark(ui, p);
            ui.add_space(10.0);
            ui.vertical(|ui| {
                ui.label(
                    egui::RichText::new("NarrChat")
                        .size(18.0)
                        .strong()
                        .color(p.text),
                );
                ui.label(egui::RichText::new("安装程序").size(12.0).color(p.muted));
            });
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                if ui
                    .add(
                        egui::Button::new(
                            egui::RichText::new(if self.dark { "浅色" } else { "深色" })
                                .size(12.0)
                                .color(p.muted),
                        )
                        .frame(false),
                    )
                    .clicked()
                {
                    self.toggle_theme(ctx);
                }
                ui.label(
                    egui::RichText::new(format!("v{}", installer::app_version()))
                        .size(12.0)
                        .color(p.muted),
                );
            });
        });
    }

    fn footer(&self, ui: &mut egui::Ui, p: &Palette) {
        ui.horizontal(|ui| {
            ui.label(
                egui::RichText::new("Rust + egui 薄壳 · Inno Setup 安装引擎")
                    .size(11.5)
                    .color(p.muted),
            );
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                ui.label(
                    egui::RichText::new(r"用户数据：文档\NarrChat")
                        .size(11.5)
                        .color(p.muted),
                );
            });
        });
    }

    fn welcome(&mut self, ui: &mut egui::Ui, p: &Palette, ctx: &egui::Context) {
        let title = if self.upgrade {
            "升级 NarrChat"
        } else {
            "欢迎安装 NarrChat"
        };
        ui.label(egui::RichText::new(title).size(28.0).strong().color(p.text));
        ui.add_space(2.0);
        ui.add(
            egui::Label::new(
                egui::RichText::new("AI 叙事交互引擎")
                    .size(15.0)
                    .color(p.muted),
            )
            .wrap(),
        );

        ui.add_space(16.0);
        bullet(
            ui,
            p,
            "安装器启动时会请求管理员权限，默认安装到当前用户目录。",
        );
        bullet(
            ui,
            p,
            r"用户数据保存在“文档\NarrChat”，升级和卸载不会删除。",
        );
        bullet(ui, p, "安装由 Inno Setup 完成，壳只负责界面与流程。");

        if let Some(app) = &self.installed {
            ui.add_space(12.0);
            theme::soft_frame(p).show(ui, |ui| {
                let version = if app.version.is_empty() {
                    "未知"
                } else {
                    &app.version
                };
                ui.add(
                    egui::Label::new(
                        egui::RichText::new(format!(
                            "检测到已安装版本 {version}，将执行升级安装。"
                        ))
                        .size(13.0)
                        .color(p.text),
                    )
                    .wrap(),
                );
            });
        }

        if self.running {
            ui.add_space(10.0);
            theme::soft_frame(p).show(ui, |ui| {
                ui.horizontal_wrapped(|ui| {
                    ui.add(
                        egui::Label::new(
                            egui::RichText::new("NarrChat 正在运行，请先退出后再安装。")
                                .size(13.0)
                                .color(p.danger),
                        )
                        .wrap(),
                    );
                    if ui.small_button("重新检测").clicked() {
                        self.rescan();
                    }
                });
            });
        }

        if let Some(error) = &self.setup_error {
            ui.add_space(10.0);
            notice(ui, p, error, p.danger);
            if ui.small_button("选择 Inno 安装包…").clicked() {
                self.choose_setup();
            }
        }

        ui.add_space(20.0);
        ui.separator();
        ui.add_space(12.0);
        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
            let can_start = self.setup_path.is_some() && !self.running;
            if ui
                .add_enabled(can_start, theme::primary_button(p, "开始安装"))
                .clicked()
            {
                self.screen = Screen::Options;
            }
            if ui.add(theme::secondary_button("退出")).clicked() {
                self.close(ctx);
            }
        });
    }

    fn options(&mut self, ui: &mut egui::Ui, p: &Palette) {
        ui.label(
            egui::RichText::new("安装选项")
                .size(24.0)
                .strong()
                .color(p.text),
        );
        ui.add_space(2.0);
        ui.add(
            egui::Label::new(
                egui::RichText::new("确认安装位置和快捷方式，然后开始安装。")
                    .size(13.0)
                    .color(p.muted),
            )
            .wrap(),
        );

        ui.add_space(16.0);
        ui.label(egui::RichText::new("安装位置").size(13.0).color(p.text));
        ui.add_space(4.0);
        if self.upgrade {
            ui.add(
                egui::Label::new(
                    egui::RichText::new(&self.install_dir)
                        .monospace()
                        .size(12.5)
                        .color(p.muted),
                )
                .wrap(),
            );
            ui.label(
                egui::RichText::new("升级会沿用已有安装位置和快捷方式。")
                    .size(12.5)
                    .color(p.muted),
            );
        } else {
            ui.horizontal(|ui| {
                let width = (ui.available_width() - 112.0).max(260.0);
                ui.add(
                    egui::TextEdit::singleline(&mut self.install_dir)
                        .desired_width(width)
                        .hint_text(r"例如 C:\Users\你\AppData\Local\Programs\NarrChat"),
                );
                if ui.add(theme::secondary_button("浏览…")).clicked() {
                    self.choose_install_dir();
                }
            });
        }

        ui.add_space(14.0);
        theme::soft_frame(p).show(ui, |ui| {
            if self.upgrade {
                let tasks = self
                    .installed
                    .as_ref()
                    .map(|app| app.selected_tasks.as_str())
                    .unwrap_or("");
                let has = |name: &str| {
                    tasks
                        .split(',')
                        .any(|task| task.trim().eq_ignore_ascii_case(name))
                };
                ui.label(egui::RichText::new("快捷方式").size(13.0).color(p.text));
                ui.add(
                    egui::Label::new(
                        egui::RichText::new(format!(
                            "升级沿用上次设置：桌面 {} · 开始菜单 {}",
                            if has("desktopicon") { "有" } else { "无" },
                            if has("startmenuicon") { "有" } else { "无" },
                        ))
                        .size(13.0)
                        .color(p.muted),
                    )
                    .wrap(),
                );
            } else {
                checkbox_row(ui, p, &mut self.desktop_shortcut, "创建桌面快捷方式", true);
                checkbox_row(
                    ui,
                    p,
                    &mut self.start_menu_shortcut,
                    "创建开始菜单快捷方式",
                    true,
                );
            }
        });

        if let Some(error) = &self.error {
            ui.add_space(10.0);
            notice(ui, p, error, p.danger);
        }

        ui.add_space(20.0);
        ui.separator();
        ui.add_space(12.0);
        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
            if ui.add(theme::primary_button(p, "开始安装")).clicked() {
                self.begin_install();
            }
            if ui.add(theme::secondary_button("返回")).clicked() {
                self.screen = Screen::Welcome;
            }
        });
    }

    fn installing(&mut self, ui: &mut egui::Ui, p: &Palette) {
        ui.label(
            egui::RichText::new("正在安装 NarrChat")
                .size(24.0)
                .strong()
                .color(p.text),
        );
        ui.add_space(10.0);
        ui.horizontal(|ui| {
            ui.add(egui::Spinner::new().size(22.0));
            ui.add(
                egui::Label::new(
                    egui::RichText::new("Inno Setup 正在后台复制文件，请勿关闭此窗口。")
                        .size(14.0)
                        .color(p.muted),
                )
                .wrap(),
            );
        });

        if self.close_hint {
            ui.add_space(8.0);
            notice(ui, p, "安装进行中，关闭已被取消；完成后再关闭。", p.danger);
        }

        ui.add_space(10.0);
        ui.checkbox(&mut self.show_log, "显示安装日志");
        if self.show_log {
            ui.add_space(6.0);
            egui::ScrollArea::vertical()
                .max_height(170.0)
                .stick_to_bottom(true)
                .show(ui, |ui| {
                    let text = if self.log_tail.is_empty() {
                        "等待安装日志…"
                    } else {
                        &self.log_tail
                    };
                    ui.add(
                        egui::Label::new(
                            egui::RichText::new(text)
                                .monospace()
                                .size(11.0)
                                .color(p.muted),
                        )
                        .wrap(),
                    );
                });
        }

        ui.add_space(8.0);
        let seconds = self
            .session
            .as_ref()
            .map(|session| session.elapsed_secs())
            .unwrap_or(0);
        ui.label(
            egui::RichText::new(format!("已运行 {seconds} 秒"))
                .size(12.0)
                .color(p.muted),
        );
    }

    fn done(&mut self, ui: &mut egui::Ui, p: &Palette) {
        ui.horizontal(|ui| {
            status_dot(ui, p.success);
            ui.label(
                egui::RichText::new("安装完成")
                    .size(28.0)
                    .strong()
                    .color(p.text),
            );
        });
        ui.add_space(8.0);
        ui.add(
            egui::Label::new(
                egui::RichText::new(format!("NarrChat {} 已安装到：", installer::app_version()))
                    .size(14.0)
                    .color(p.text),
            )
            .wrap(),
        );
        ui.add(
            egui::Label::new(
                egui::RichText::new(&self.install_dir)
                    .monospace()
                    .size(12.5)
                    .color(p.muted),
            )
            .wrap(),
        );

        if self.launched {
            ui.add_space(8.0);
            ui.label(
                egui::RichText::new("NarrChat 已启动。")
                    .size(13.0)
                    .color(p.success),
            );
        }
        if let Some(error) = &self.launch_error {
            ui.add_space(8.0);
            notice(ui, p, error, p.danger);
        }

        ui.add_space(20.0);
        ui.separator();
        ui.add_space(12.0);
        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
            if !self.launched && ui.add(theme::primary_button(p, "打开 NarrChat")).clicked() {
                self.open_app();
            }
            if ui.add(theme::secondary_button("完成")).clicked() {
                self.close(ui.ctx());
            }
            if ui.add(theme::secondary_button("打开安装目录")).clicked() {
                self.open_install_dir();
            }
            if self.log_path.is_some() && ui.add(theme::secondary_button("查看日志")).clicked()
            {
                self.open_log();
            }
        });
    }

    fn failed(&mut self, ui: &mut egui::Ui, p: &Palette) {
        ui.horizontal(|ui| {
            status_dot(ui, p.danger);
            ui.label(
                egui::RichText::new("安装未完成")
                    .size(28.0)
                    .strong()
                    .color(p.text),
            );
        });
        ui.add_space(8.0);
        if let Some(error) = &self.error {
            notice(ui, p, error, p.danger);
        }
        if let Some(code) = self.exit_code {
            ui.add_space(6.0);
            ui.label(
                egui::RichText::new(format!("Inno 退出码：{code}"))
                    .size(12.5)
                    .color(p.muted),
            );
        }
        if let Some(path) = &self.log_path {
            ui.add_space(6.0);
            ui.add(
                egui::Label::new(
                    egui::RichText::new(format!("日志：{}", path.display()))
                        .monospace()
                        .size(11.5)
                        .color(p.muted),
                )
                .wrap(),
            );
        }
        if !self.log_tail.is_empty() {
            ui.add_space(8.0);
            egui::ScrollArea::vertical()
                .max_height(130.0)
                .stick_to_bottom(true)
                .show(ui, |ui| {
                    ui.add(
                        egui::Label::new(
                            egui::RichText::new(&self.log_tail)
                                .monospace()
                                .size(11.0)
                                .color(p.muted),
                        )
                        .wrap(),
                    );
                });
        }

        ui.add_space(20.0);
        ui.separator();
        ui.add_space(12.0);
        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
            let retry_label = if self.setup_path.is_some() {
                "重试"
            } else {
                "返回"
            };
            if ui.add(theme::primary_button(p, retry_label)).clicked() {
                if self.setup_path.is_some() {
                    self.retry();
                } else {
                    self.screen = Screen::Welcome;
                }
            }
            if ui.add(theme::secondary_button("退出")).clicked() {
                self.close(ui.ctx());
            }
            if self.log_path.is_some() && ui.add(theme::secondary_button("打开日志")).clicked()
            {
                self.open_log();
            }
        });
    }
}

fn brand_mark(ui: &mut egui::Ui, p: &Palette) {
    let (rect, _) = ui.allocate_exact_size(egui::vec2(38.0, 38.0), egui::Sense::hover());
    ui.painter()
        .rect_filled(rect, egui::CornerRadius::same(12), p.accent);
    ui.painter().text(
        rect.center(),
        egui::Align2::CENTER_CENTER,
        "N",
        egui::FontId::proportional(20.0),
        egui::Color32::WHITE,
    );
}

fn bullet(ui: &mut egui::Ui, p: &Palette, text: &str) {
    ui.horizontal_wrapped(|ui| {
        theme::dot(ui, p.accent);
        ui.add(egui::Label::new(egui::RichText::new(text).size(14.0).color(p.text)).wrap());
    });
}

/// 比 egui 默认复选框更清楚：未选中是“卡片底 + 明显描边”，选中是深色对勾。
fn checkbox_row(
    ui: &mut egui::Ui,
    p: &Palette,
    checked: &mut bool,
    label: &str,
    enabled: bool,
) -> egui::Response {
    ui.scope(|ui| {
        let visuals = &mut ui.style_mut().visuals;
        visuals.widgets.inactive.bg_fill = if enabled { p.card } else { p.input };
        visuals.widgets.inactive.bg_stroke =
            egui::Stroke::new(1.5, if enabled { p.muted } else { p.border });
        visuals.widgets.inactive.fg_stroke.color = if enabled { p.text } else { p.muted };
        visuals.widgets.hovered.bg_fill = p.hover;
        visuals.widgets.hovered.bg_stroke = egui::Stroke::new(1.5, p.accent);
        visuals.widgets.hovered.fg_stroke.color = p.text;
        visuals.widgets.active.bg_fill = p.accent;
        visuals.widgets.active.bg_stroke = egui::Stroke::new(1.5, p.accent);
        visuals.widgets.active.fg_stroke.color = egui::Color32::WHITE;
        ui.spacing_mut().icon_width = 20.0;
        ui.spacing_mut().icon_width_inner = 10.0;
        ui.spacing_mut().icon_spacing = 10.0;
        ui.add_enabled(enabled, egui::Checkbox::new(checked, label))
    })
    .inner
}

fn notice(ui: &mut egui::Ui, p: &Palette, text: &str, color: egui::Color32) {
    theme::soft_frame(p).show(ui, |ui| {
        ui.add(egui::Label::new(egui::RichText::new(text).size(13.0).color(color)).wrap());
    });
}

fn status_dot(ui: &mut egui::Ui, color: egui::Color32) {
    let (rect, _) = ui.allocate_exact_size(egui::vec2(20.0, 28.0), egui::Sense::hover());
    ui.painter().circle_filled(rect.center(), 6.0, color);
}
