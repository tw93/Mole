use ratatui::style::{Color, Modifier, Style};

// Theme colors
pub const COLOR_PURPLE: Color = Color::Rgb(198, 120, 221); // #C678DD
pub const COLOR_CYAN: Color = Color::Rgb(86, 182, 194);   // #56B6C2
pub const COLOR_GREEN: Color = Color::Rgb(152, 195, 121); // #98C379
pub const COLOR_GRAY: Color = Color::Rgb(127, 132, 142);  // #7F848E
pub const COLOR_DARK_BG: Color = Color::Rgb(30, 30, 46);   // #1E1E2E

// Theme styles
pub const STYLE_HEADER: Style = Style::new()
    .fg(COLOR_PURPLE)
    .add_modifier(Modifier::BOLD);

pub const STYLE_SELECTED: Style = Style::new()
    .fg(COLOR_CYAN)
    .add_modifier(Modifier::BOLD);

pub const STYLE_SUCCESS: Style = Style::new()
    .fg(COLOR_GREEN);

pub const STYLE_MUTED: Style = Style::new()
    .fg(COLOR_GRAY);
