use crate::app::{App, CleanStatus};
use crate::theme;
use ratatui::{
    layout::{Constraint, Direction, Layout, Alignment, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, BorderType, Borders, Paragraph, List, ListItem, Gauge},
    Frame,
};

pub fn draw(frame: &mut Frame, app: &App, area: Rect) {
    let purple = theme::COLOR_PURPLE;
    let cyan = theme::COLOR_CYAN;

    // Detect if running with sudo
    let has_sudo_warning = !crate::app::is_root();

    // Dynamically calculate layout constraints depending on privilege status
    let constraints = if has_sudo_warning {
        vec![
            Constraint::Length(4), // Status banner
            Constraint::Length(3), // Sudo warning instructions
            Constraint::Length(3), // Smooth progress bar (Gauge)
            Constraint::Min(5),    // List of tasks
        ]
    } else {
        vec![
            Constraint::Length(4), // Status banner
            Constraint::Length(3), // Smooth progress bar (Gauge)
            Constraint::Min(5),    // List of tasks
        ]
    };

    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints(constraints)
        .split(area);

    // 1. Build the status banner (always in chunks[0])
    let status_line = if app.clean_running {
        let spinner_chars = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
        let spinner_char = spinner_chars[app.spinner_frame % spinner_chars.len()];
        Line::from(vec![
            Span::styled(format!("{} ", spinner_char), theme::STYLE_HEADER),
            Span::styled("CLEANING RUNTIME ", theme::STYLE_SELECTED),
            Span::styled("| executing clean.sh script...", theme::STYLE_MUTED),
        ])
    } else if let Some(ref err) = app.clean_error {
        Line::from(vec![
            Span::styled("✗ CLEAN FAILED ", Style::default().fg(Color::Red).add_modifier(Modifier::BOLD)),
            Span::styled(format!("| Error: {}", err), Style::default().fg(Color::Red)),
        ])
    } else if app.clean_categories.is_empty() {
        Line::from(vec![
            Span::styled("⚡ READY ", theme::STYLE_SUCCESS),
            Span::styled("| Press Enter to start clean.sh execution", theme::STYLE_MUTED),
        ])
    } else {
        Line::from(vec![
            Span::styled("✓ CLEAN SUCCESS ", theme::STYLE_SUCCESS),
            Span::styled("| Cleanup finished successfully", theme::STYLE_MUTED),
        ])
    };

    let banner_block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(Style::default().fg(if app.clean_running {
            cyan
        } else if app.clean_error.is_some() {
            Color::Red
        } else {
            purple
        }))
        .padding(ratatui::widgets::Padding::horizontal(1));

    let banner_widget = Paragraph::new(vec![
        Line::from(Span::styled("Mac Cleanup & Tidy", theme::STYLE_HEADER)),
        status_line,
    ])
    .block(banner_block);
    frame.render_widget(banner_widget, chunks[0]);

    let mut current_idx = 1;

    // 2. Render Sudo Warning Banner if not running with root privileges
    if has_sudo_warning {
        let warning_block = Block::default()
            .borders(Borders::ALL)
            .border_type(BorderType::Rounded)
            .style(Style::default().fg(Color::Yellow).bg(Color::Rgb(30, 30, 10)))
            .title(" Privilege Notice ")
            .title_style(Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD))
            .padding(ratatui::widgets::Padding::horizontal(1));

        let warning_paragraph = Paragraph::new(Line::from(vec![
            Span::styled("⚠️  ", Style::default().fg(Color::Yellow)),
            Span::styled("Running without root. System cache cleanup is skipped. Run with ", Style::default().fg(Color::White)),
            Span::styled("sudo mole", Style::default().fg(cyan).add_modifier(Modifier::BOLD)),
            Span::styled(" to scan all paths.", Style::default().fg(Color::White)),
        ]))
        .block(warning_block);

        frame.render_widget(warning_paragraph, chunks[current_idx]);
        current_idx += 1;
    }

    // 3. Build the smooth progress bar (Gauge)
    let bytes_str = format_bytes_human(app.clean_bytes_displayed);
    let target_bytes_str = format_bytes_human(app.clean_bytes_target);
    let progress_percentage = (app.clean_progress_displayed * 100.0) as u16;

    let gauge_block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(Style::default().fg(cyan))
        .title(" Cleanup Progress ")
        .title_style(theme::STYLE_HEADER);

    let gauge_widget = Gauge::default()
        .block(gauge_block)
        .gauge_style(Style::default().fg(cyan).bg(Color::Rgb(40, 44, 52)))
        .percent(progress_percentage.min(100))
        .label(format!("{} / {} Freed ({}%)", bytes_str, target_bytes_str, progress_percentage));
    
    frame.render_widget(gauge_widget, chunks[current_idx]);
    current_idx += 1;

    // 4. Build the flattened categories/tasks list
    let mut list_items = Vec::new();
    
    if app.clean_categories.is_empty() {
        list_items.push(ListItem::new(Line::from(vec![
            Span::styled("  No cleanup processes run yet. Press Enter to start.", theme::STYLE_MUTED)
        ])));
    } else {
        for cat in &app.clean_categories {
            list_items.push(ListItem::new(Line::from(vec![
                Span::styled("➤ ", theme::STYLE_HEADER),
                Span::styled(cat.name.clone(), theme::STYLE_HEADER),
            ])));

            for task in &cat.tasks {
                let (status_symbol, status_style) = match task.status {
                    CleanStatus::Pending => ("  ○ ", theme::STYLE_MUTED),
                    CleanStatus::InProgress => ("  – ", theme::STYLE_SELECTED),
                    CleanStatus::Success => ("  ✓ ", theme::STYLE_SUCCESS),
                    CleanStatus::Skipped => ("  ◎ ", theme::STYLE_MUTED),
                    CleanStatus::Info => ("  ☞ ", theme::STYLE_MUTED),
                    CleanStatus::Error => ("  ✗ ", Style::default().fg(Color::Red).add_modifier(Modifier::BOLD)),
                };

                let mut spans = vec![
                    Span::styled(status_symbol, status_style),
                    Span::styled(
                        task.name.clone(),
                        if task.status == CleanStatus::InProgress {
                            theme::STYLE_SELECTED
                        } else {
                            Style::default().fg(Color::White)
                        }
                    ),
                ];

                if !task.detail.is_empty() {
                    spans.push(Span::styled(format!("  ·  {}", task.detail), theme::STYLE_MUTED));
                }

                list_items.push(ListItem::new(Line::from(spans)));
            }

            // Spacer line
            list_items.push(ListItem::new(Line::from("")));
        }
    }

    let list_block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(Style::default().fg(purple))
        .title(" Execution Stream ")
        .title_alignment(Alignment::Center)
        .title_style(theme::STYLE_HEADER)
        .padding(ratatui::widgets::Padding::uniform(1));

    let list = List::new(list_items)
        .block(list_block);

    frame.render_widget(list, chunks[current_idx]);
}

fn format_bytes_human(bytes: u64) -> String {
    let kb = bytes as f64 / 1024.0;
    let mb = kb / 1024.0;
    let gb = mb / 1024.0;
    if gb >= 1.0 {
        format!("{:.2} GB", gb)
    } else if mb >= 1.0 {
        format!("{:.1} MB", mb)
    } else if kb >= 1.0 {
        format!("{:.1} KB", kb)
    } else {
        format!("{} B", bytes)
    }
}
