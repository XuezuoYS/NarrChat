//! 安装器壳的配色与控件样式。
//!
//! 颜色跟主应用 `lib/theme/app_theme.dart` 的品牌色保持一致：
//! 主色 `#4D6BFE`，暗色背景 `#17181A`，卡片 `#1F2023`。

use eframe::egui;

/// 一套明/暗配色。
pub struct Palette {
    pub bg: egui::Color32,
    pub card: egui::Color32,
    pub input: egui::Color32,
    pub hover: egui::Color32,
    pub border: egui::Color32,
    pub text: egui::Color32,
    pub muted: egui::Color32,
    pub accent: egui::Color32,
    pub success: egui::Color32,
    pub danger: egui::Color32,
}

/// 按明/暗取颜色。浅色跟主应用一样用暖白，深色用近黑。
pub fn palette(dark: bool) -> Palette {
    if dark {
        Palette {
            bg: egui::Color32::from_rgb(0x17, 0x18, 0x1A),
            card: egui::Color32::from_rgb(0x1F, 0x20, 0x23),
            input: egui::Color32::from_rgb(0x24, 0x25, 0x28),
            hover: egui::Color32::from_rgb(0x2A, 0x2B, 0x2F),
            border: egui::Color32::from_rgb(0x2C, 0x2E, 0x33),
            text: egui::Color32::from_rgb(0xE8, 0xE8, 0xEA),
            muted: egui::Color32::from_rgb(0x9C, 0xA1, 0xA9),
            accent: egui::Color32::from_rgb(0x4D, 0x6B, 0xFE),
            success: egui::Color32::from_rgb(0x66, 0xBB, 0x6A),
            danger: egui::Color32::from_rgb(0xE5, 0x48, 0x4D),
        }
    } else {
        Palette {
            bg: egui::Color32::from_rgb(0xF7, 0xF7, 0xF8),
            card: egui::Color32::from_rgb(0xFF, 0xFF, 0xFF),
            input: egui::Color32::from_rgb(0xF4, 0xF4, 0xF5),
            hover: egui::Color32::from_rgb(0xEC, 0xEC, 0xEE),
            border: egui::Color32::from_rgb(0xE8, 0xE8, 0xEA),
            text: egui::Color32::from_rgb(0x1F, 0x1F, 0x1F),
            muted: egui::Color32::from_rgb(0x5F, 0x63, 0x68),
            accent: egui::Color32::from_rgb(0x4D, 0x6B, 0xFE),
            success: egui::Color32::from_rgb(0x2E, 0x7D, 0x32),
            danger: egui::Color32::from_rgb(0xE5, 0x48, 0x4D),
        }
    }
}

/// 应用整套 egui 视觉与文字尺寸。
pub fn apply(ctx: &egui::Context, dark: bool) {
    let p = palette(dark);
    let mut visuals = if dark {
        egui::Visuals::dark()
    } else {
        egui::Visuals::light()
    };

    visuals.panel_fill = p.bg;
    visuals.window_fill = p.bg;
    visuals.window_stroke = egui::Stroke::new(1.0, p.border);
    visuals.window_corner_radius = egui::CornerRadius::same(14);
    visuals.menu_corner_radius = egui::CornerRadius::same(10);
    visuals.extreme_bg_color = p.input;
    visuals.faint_bg_color = p.card;
    visuals.override_text_color = Some(p.text);
    visuals.hyperlink_color = p.accent;
    visuals.selection.bg_fill = p.accent;
    visuals.selection.stroke = egui::Stroke::new(1.0, egui::Color32::WHITE);

    visuals.widgets.noninteractive.bg_fill = p.card;
    visuals.widgets.noninteractive.weak_bg_fill = p.card;
    visuals.widgets.noninteractive.bg_stroke = egui::Stroke::new(1.0, p.border);
    visuals.widgets.noninteractive.fg_stroke.color = p.text;
    visuals.widgets.noninteractive.corner_radius = egui::CornerRadius::same(8);

    visuals.widgets.inactive.bg_fill = p.input;
    visuals.widgets.inactive.weak_bg_fill = p.input;
    visuals.widgets.inactive.bg_stroke = egui::Stroke::new(1.0, p.border);
    visuals.widgets.inactive.fg_stroke.color = p.text;
    visuals.widgets.inactive.corner_radius = egui::CornerRadius::same(8);

    visuals.widgets.hovered.bg_fill = p.hover;
    visuals.widgets.hovered.weak_bg_fill = p.hover;
    visuals.widgets.hovered.bg_stroke = egui::Stroke::new(1.0, p.accent);
    visuals.widgets.hovered.fg_stroke.color = p.text;
    visuals.widgets.hovered.corner_radius = egui::CornerRadius::same(8);

    visuals.widgets.active.bg_fill = p.accent;
    visuals.widgets.active.weak_bg_fill = p.accent;
    visuals.widgets.active.bg_stroke = egui::Stroke::new(1.0, p.accent);
    visuals.widgets.active.fg_stroke.color = egui::Color32::WHITE;
    visuals.widgets.active.corner_radius = egui::CornerRadius::same(8);

    visuals.widgets.open.bg_fill = p.hover;
    visuals.widgets.open.weak_bg_fill = p.hover;
    visuals.widgets.open.bg_stroke = egui::Stroke::new(1.0, p.border);
    visuals.widgets.open.fg_stroke.color = p.text;
    visuals.widgets.open.corner_radius = egui::CornerRadius::same(8);

    // egui 0.37 的 style 按主题分开；先把当前主题切对，再覆盖视觉。
    ctx.set_theme(if dark {
        egui::ThemePreference::Dark
    } else {
        egui::ThemePreference::Light
    });
    ctx.set_visuals(visuals);

    ctx.all_styles_mut(|style| {
        style.spacing.item_spacing = egui::vec2(10.0, 10.0);
        style.spacing.button_padding = egui::vec2(16.0, 9.0);
        style.spacing.interact_size.y = 38.0;
        style
            .text_styles
            .insert(egui::TextStyle::Heading, egui::FontId::proportional(28.0));
        style
            .text_styles
            .insert(egui::TextStyle::Body, egui::FontId::proportional(15.0));
        style
            .text_styles
            .insert(egui::TextStyle::Button, egui::FontId::proportional(15.0));
        style
            .text_styles
            .insert(egui::TextStyle::Small, egui::FontId::proportional(12.5));
        style
            .text_styles
            .insert(egui::TextStyle::Monospace, egui::FontId::monospace(12.0));
    });
}

/// 主卡片：圆角、细边框、24px 内边距。
pub fn card_frame(p: &Palette) -> egui::Frame {
    egui::Frame::new()
        .fill(p.card)
        .stroke(egui::Stroke::new(1.0, p.border))
        .corner_radius(egui::CornerRadius::same(18))
        .inner_margin(egui::Margin::same(20))
}

/// 内嵌提示块：比卡片更浅，用于说明/警告。
pub fn soft_frame(p: &Palette) -> egui::Frame {
    egui::Frame::new()
        .fill(p.input)
        .corner_radius(egui::CornerRadius::same(12))
        .inner_margin(egui::Margin::same(14))
}

/// 主按钮：品牌色填充、白字。
pub fn primary_button(p: &Palette, label: &str) -> egui::Button<'static> {
    egui::Button::new(
        egui::RichText::new(label.to_owned())
            .color(egui::Color32::WHITE)
            .strong(),
    )
    .fill(p.accent)
    .corner_radius(egui::CornerRadius::same(10))
    .min_size(egui::vec2(132.0, 40.0))
}

/// 次要按钮：透明/浅底，跟主题走。
pub fn secondary_button(label: &str) -> egui::Button<'static> {
    egui::Button::new(egui::RichText::new(label.to_owned()))
        .corner_radius(egui::CornerRadius::same(10))
        .min_size(egui::vec2(96.0, 40.0))
}

/// 主色小圆点，用于列表/状态。
pub fn dot(ui: &mut egui::Ui, color: egui::Color32) {
    let (rect, _) = ui.allocate_exact_size(egui::vec2(8.0, 18.0), egui::Sense::hover());
    ui.painter()
        .circle_filled(egui::pos2(rect.left() + 3.0, rect.center().y), 2.5, color);
}
