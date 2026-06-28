use crate::app::App;
use crate::theme;
use ratatui::{
    layout::{Constraint, Direction, Layout, Alignment, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, BorderType, Borders, Cell, Row, Table, Clear, Paragraph, List, ListItem},
    Frame,
};

pub fn draw(frame: &mut Frame, app: &App, area: Rect) {
    // Theme colors
    let purple = theme::COLOR_PURPLE;
    let cyan = theme::COLOR_CYAN;
    let gray = theme::COLOR_GRAY;

    // Split the area vertically: Header stats & search input, and Table content
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(4), // Header stats & search input
            Constraint::Min(5),    // Table list of apps
        ])
        .split(area);

    // Compute selection metadata
    let total_count = app.uninstall_items.len();
    let selected_items: Vec<_> = app.uninstall_items.iter().filter(|i| i.selected).collect();
    let selected_count = selected_items.len();
    let selected_size: u64 = selected_items.iter().map(|i| i.size_mb).sum();

    // Stats line
    let stats_text = Line::from(vec![
        Span::styled("App Uninstaller ", theme::STYLE_HEADER),
        Span::styled(
            format!("| Selected: {}/{} ({})", selected_count, total_count, format_size_mb(selected_size)),
            if selected_count > 0 { theme::STYLE_SUCCESS } else { theme::STYLE_MUTED }
        ),
    ]);

    // Search bar block (input box)
    let search_bar = if app.uninstall_searching {
        Line::from(vec![
            Span::styled(" SEARCH ACTIVE ❯ ", Style::default().fg(Color::Black).bg(cyan)),
            Span::raw(" "),
            Span::styled(format!("{}█", app.uninstall_search), Style::default().fg(Color::White)),
        ])
    } else if !app.uninstall_search.is_empty() {
        Line::from(vec![
            Span::styled(" FILTERED ❯ ", Style::default().fg(Color::Black).bg(gray)),
            Span::raw(" "),
            Span::styled(app.uninstall_search.clone(), theme::STYLE_MUTED),
            Span::styled(" (Press / to search, Esc to clear)", Style::default().fg(gray).add_modifier(Modifier::DIM)),
        ])
    } else {
        Line::from(vec![
            Span::styled(" SEARCH ❯ ", Style::default().fg(Color::Black).bg(gray)),
            Span::raw(" "),
            Span::styled("Press / to filter applications...", Style::default().fg(gray).add_modifier(Modifier::DIM)),
        ])
    };

    let header_block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(Style::default().fg(gray))
        .padding(ratatui::widgets::Padding::horizontal(1));

    let header_content = Paragraph::new(vec![stats_text, search_bar])
        .block(header_block);
    frame.render_widget(header_content, chunks[0]);

    // Draw the Table (or Loading Screen)
    if app.uninstall_scanning_status {
        let loading_block = Block::default()
            .borders(Borders::ALL)
            .border_type(BorderType::Rounded)
            .border_style(Style::default().fg(purple))
            .title(" Applications ")
            .title_alignment(Alignment::Center)
            .title_style(theme::STYLE_HEADER)
            .padding(ratatui::widgets::Padding::uniform(2));

        let loading_text = Paragraph::new(vec![
            Line::from(""),
            Line::from(Span::styled("🔍 Scanning /Applications folder...", theme::STYLE_SELECTED.add_modifier(Modifier::BOLD))),
            Line::from(""),
            Line::from(Span::styled("Calculating directory size and sorting applications by footprint.", theme::STYLE_MUTED)),
            Line::from(Span::styled("This will take just a moment...", theme::STYLE_MUTED)),
        ])
        .alignment(Alignment::Center)
        .block(loading_block);

        frame.render_widget(loading_text, chunks[1]);
        return;
    }

    let filtered = app.filtered_uninstall_items();
    let rows: Vec<Row> = filtered
        .iter()
        .enumerate()
        .map(|(i, (_, item))| {
            let indicator = if item.selected { "● " } else { "○ " };
            
            // Smooth Scroll transition check:
            let is_active = i == app.uninstall_index;
            let is_prev = app.uninstall_prev_index == Some(i) && app.uninstall_transition_ticks > 0;
            
            let active_indicator = if is_active {
                "❯ "
            } else if is_prev {
                "› "
            } else {
                "  "
            };

            // Determine cell styles and background highlight
            let mut cell_style = if item.selected {
                Style::default().fg(purple).add_modifier(Modifier::BOLD)
            } else {
                Style::default().fg(Color::White)
            };

            let row_style = if is_active {
                cell_style = cell_style.fg(cyan).add_modifier(Modifier::BOLD);
                cell_style.bg(Color::Rgb(40, 44, 52))
            } else if is_prev {
                cell_style = cell_style.fg(gray); // Faded style
                cell_style.bg(Color::Rgb(33, 37, 43)) // Faded bg
            } else {
                cell_style
            };

            let size_str = format_size_mb(item.size_mb);

            Row::new(vec![
                Cell::from(Line::from(vec![
                    Span::styled(active_indicator, if is_active { theme::STYLE_SELECTED } else { theme::STYLE_MUTED }),
                    Span::styled(indicator, if item.selected { theme::STYLE_HEADER } else { theme::STYLE_MUTED }),
                    Span::raw(item.name.clone()),
                ])),
                Cell::from(Line::from(size_str).alignment(Alignment::Right)),
                Cell::from(Line::from(item.last_used.clone()).alignment(Alignment::Right)),
            ])
            .style(row_style)
        })
        .collect();

    let table_block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(Style::default().fg(purple))
        .title(" Applications ")
        .title_alignment(Alignment::Center)
        .title_style(theme::STYLE_HEADER)
        .padding(ratatui::widgets::Padding::uniform(1));

    let widths = [
        Constraint::Percentage(50),
        Constraint::Percentage(25),
        Constraint::Percentage(25),
    ];

    let header_row = Row::new(vec![
        Cell::from(Line::from("  Application Name").alignment(Alignment::Left)),
        Cell::from(Line::from("Size  ").alignment(Alignment::Right)),
        Cell::from(Line::from("Last Used  ").alignment(Alignment::Right)),
    ])
    .style(Style::default().fg(cyan).add_modifier(Modifier::BOLD));

    let table = Table::new(rows, widths)
        .header(header_row)
        .block(table_block)
        .column_spacing(1);

    frame.render_widget(table, chunks[1]);

    // 3. Render Confirmation Modal (Centered Popup) if open
    if app.uninstall_confirm_open {
        let popup_area = centered_rect(65, 55, frame.area());
        frame.render_widget(Clear, popup_area); // Wipes out background text underneath

        // Block with rounded borders for the modal container
        let modal_block = Block::default()
            .borders(Borders::ALL)
            .border_type(BorderType::Rounded)
            .border_style(Style::default().fg(purple))
            .title(" Confirm Uninstall ")
            .title_alignment(Alignment::Center)
            .title_style(theme::STYLE_HEADER)
            .padding(ratatui::widgets::Padding::uniform(1));

        let inner_popup_area = modal_block.inner(popup_area);
        frame.render_widget(modal_block, popup_area);

        // Split inner popup: List of items to uninstall, and confirmation prompt
        let modal_chunks = Layout::default()
            .direction(Direction::Vertical)
            .constraints([
                Constraint::Min(4),    // Selected apps list
                Constraint::Length(3), // Action prompt
            ])
            .split(inner_popup_area);

        // Populate selected apps to show inside the modal
        let selected_apps_list: Vec<ListItem> = selected_items
            .iter()
            .map(|item| {
                ListItem::new(Line::from(vec![
                    Span::styled(" • ", theme::STYLE_HEADER),
                    Span::raw(format!("{} ", item.name)),
                    Span::styled(format!("({})", format_size_mb(item.size_mb)), theme::STYLE_MUTED),
                ]))
            })
            .collect();

        let list_widget = List::new(selected_apps_list)
            .block(Block::default()
                .borders(Borders::BOTTOM)
                .border_style(theme::STYLE_MUTED)
                .title(" Selected Items ")
                .title_style(theme::STYLE_MUTED)
            );
        frame.render_widget(list_widget, modal_chunks[0]);

        // Prompt text
        let prompt_text = vec![
            Line::from(Span::styled(
                format!("Total Space to Reclaim: {}", format_size_mb(selected_size)),
                theme::STYLE_SUCCESS.add_modifier(Modifier::BOLD)
            )),
            Line::from(vec![
                Span::raw("Are you sure? "),
                Span::styled(" [y] Confirm ", theme::STYLE_SUCCESS.add_modifier(Modifier::BOLD)),
                Span::raw(" / "),
                Span::styled(" [n] Cancel ", Style::default().fg(Color::Red).add_modifier(Modifier::BOLD)),
            ]),
        ];

        let prompt_widget = Paragraph::new(prompt_text)
            .alignment(Alignment::Center);
        frame.render_widget(prompt_widget, modal_chunks[1]);
    }
}

fn format_size_mb(mb: u64) -> String {
    if mb >= 1000 {
        format!("{:.1} GB", mb as f64 / 1000.0)
    } else {
        format!("{} MB", mb)
    }
}

/// Helper function to center a rectangle inside the screen area
fn centered_rect(percent_x: u16, percent_y: u16, r: Rect) -> Rect {
    let popup_layout = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Percentage((100 - percent_y) / 2),
            Constraint::Percentage(percent_y),
            Constraint::Percentage((100 - percent_y) / 2),
        ])
        .split(r);

    Layout::default()
        .direction(Direction::Horizontal)
        .constraints([
            Constraint::Percentage((100 - percent_x) / 2),
            Constraint::Percentage(percent_x),
            Constraint::Percentage((100 - percent_x) / 2),
        ])
        .split(popup_layout[1])[1]
}
